#include "adb/pairing/AdbPair.h"

#include "adb/pairing/PairingAuth.h"
#include "adb/pairing/TlsConnection.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>

#include <hilog/log.h>

#ifndef LOG_TAG
#define LOG_TAG "AdbPair"
#endif

namespace scrcpy::pairing {
namespace {

constexpr uint8_t kPacketTypeSpake2Msg = 0;
constexpr uint8_t kPacketTypePeerInfo = 1;
constexpr uint8_t kCurrentKeyHeaderVersion = 1;
constexpr uint32_t kMaxPeerInfoSize = 8192;
constexpr uint32_t kMaxPayloadSize = kMaxPeerInfoSize * 2;
constexpr int kConnectTimeoutSeconds = 10;
constexpr size_t kExportedKeySize = 64;

enum PeerInfoType : uint8_t {
    ADB_RSA_PUB_KEY = 0,
    ADB_DEVICE_GUID = 1,
};

struct PeerInfo {
    uint8_t type;
    uint8_t data[kMaxPeerInfoSize - 1];
} __attribute__((packed));

struct PairingPacketHeader {
    uint8_t version;
    uint8_t type;
    uint32_t payload;
} __attribute__((packed));

class UniqueFd {
public:
    explicit UniqueFd(int fd = -1) : fd_(fd) {}
    ~UniqueFd() {
        reset();
    }

    UniqueFd(const UniqueFd&) = delete;
    UniqueFd& operator=(const UniqueFd&) = delete;

    UniqueFd(UniqueFd&& other) noexcept : fd_(other.fd_) {
        other.fd_ = -1;
    }

    UniqueFd& operator=(UniqueFd&& other) noexcept {
        if (this != &other) {
            reset();
            fd_ = other.fd_;
            other.fd_ = -1;
        }
        return *this;
    }

    int get() const {
        return fd_;
    }

    int release() {
        int fd = fd_;
        fd_ = -1;
        return fd;
    }

    void reset(int fd = -1) {
        if (fd_ >= 0) {
            ::close(fd_);
        }
        fd_ = fd;
    }

private:
    int fd_;
};

struct PairingAuthDeleter {
    void operator()(PairingAuthCtx* ctx) const {
        pairing_auth_destroy(ctx);
    }
};

using PairingAuthPtr = std::unique_ptr<PairingAuthCtx, PairingAuthDeleter>;
constexpr int kCertLifetimeSeconds = 10 * 365 * 24 * 60 * 60;
const char kBasicConstraints[] = "critical,CA:TRUE";
const char kKeyUsage[] = "critical,keyCertSign,cRLSign,digitalSignature";
const char kSubjectKeyIdentifier[] = "hash";

std::string ReadFileToString(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        throw std::runtime_error("Unable to open file: " + path);
    }
    return std::string((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

std::string ReadPublicKeyString(const std::string& path) {
    std::string raw = ReadFileToString(path);
    const size_t zeroPos = raw.find('\0');
    if (zeroPos != std::string::npos) {
        raw.resize(zeroPos);
    }
    while (!raw.empty() && (raw.back() == '\n' || raw.back() == '\r')) {
        raw.pop_back();
    }
    return raw;
}

bssl::UniquePtr<EVP_PKEY> LoadPrivateKey(std::string_view pem) {
    bssl::UniquePtr<BIO> bio(BIO_new_mem_buf(pem.data(), static_cast<int>(pem.size())));
    if (!bio) {
        return nullptr;
    }
    return bssl::UniquePtr<EVP_PKEY>(PEM_read_bio_PrivateKey(bio.get(), nullptr, nullptr, nullptr));
}

bool AddExtension(X509* cert, int nid, const char* value) {
    size_t len = std::strlen(value) + 1;
    std::vector<char> mutableValue(value, value + len);
    X509V3_CTX context;

    X509V3_set_ctx_nodb(&context);
    X509V3_set_ctx(&context, cert, cert, nullptr, nullptr, 0);
    X509_EXTENSION* ext = X509V3_EXT_nconf_nid(nullptr, &context, nid, mutableValue.data());
    if (!ext) {
        return false;
    }

    X509_add_ext(cert, ext, -1);
    X509_EXTENSION_free(ext);
    return true;
}

std::string PrivateKeyToPem(EVP_PKEY* pkey) {
    bssl::UniquePtr<BIO> bio(BIO_new(BIO_s_mem()));
    if (!bio) {
        throw std::runtime_error("Failed to allocate PEM BIO");
    }
    if (PEM_write_bio_PKCS8PrivateKey(bio.get(), pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        throw std::runtime_error("PEM_write_bio_PKCS8PrivateKey failed");
    }

    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio.get(), &mem);
    if (!mem || !mem->data || mem->length == 0) {
        throw std::runtime_error("BIO_get_mem_ptr failed");
    }
    return std::string(mem->data, mem->length);
}

std::string GenerateCertificatePem(EVP_PKEY* pkey) {
    bssl::UniquePtr<X509> x509(X509_new());
    if (!x509) {
        throw std::runtime_error("Unable to allocate X509");
    }

    X509_set_version(x509.get(), 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x509.get()), 1);
    X509_gmtime_adj(X509_get_notBefore(x509.get()), 0);
    X509_gmtime_adj(X509_get_notAfter(x509.get()), kCertLifetimeSeconds);

    if (!X509_set_pubkey(x509.get(), pkey)) {
        throw std::runtime_error("Unable to set X509 public key");
    }

    X509_NAME* name = X509_get_subject_name(x509.get());
    if (!name) {
        throw std::runtime_error("Unable to get X509 subject name");
    }

    X509_NAME_add_entry_by_txt(name, "C", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("US"), -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("Android"), -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("Adb"), -1, -1, 0);

    if (!X509_set_issuer_name(x509.get(), name)) {
        throw std::runtime_error("Unable to set X509 issuer name");
    }

    if (!AddExtension(x509.get(), NID_basic_constraints, kBasicConstraints) ||
        !AddExtension(x509.get(), NID_key_usage, kKeyUsage) ||
        !AddExtension(x509.get(), NID_subject_key_identifier, kSubjectKeyIdentifier)) {
        throw std::runtime_error("Unable to create X509 extensions");
    }

    if (X509_sign(x509.get(), pkey, EVP_sha256()) <= 0) {
        throw std::runtime_error("Unable to sign X509 certificate");
    }

    bssl::UniquePtr<BIO> bio(BIO_new(BIO_s_mem()));
    if (!bio) {
        throw std::runtime_error("Failed to allocate X509 PEM BIO");
    }
    if (PEM_write_bio_X509(bio.get(), x509.get()) != 1) {
        throw std::runtime_error("PEM_write_bio_X509 failed");
    }

    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio.get(), &mem);
    if (!mem || !mem->data || mem->length == 0) {
        throw std::runtime_error("BIO_get_mem_ptr failed");
    }
    return std::string(mem->data, mem->length);
}

void ParseHostPort(const std::string& hostPort, std::string& host, std::string& port) {
    if (hostPort.empty()) {
        throw std::runtime_error("Pairing address is empty");
    }

    if (hostPort.front() == '[') {
        const size_t close = hostPort.find(']');
        if (close == std::string::npos || close + 2 > hostPort.size() || hostPort[close + 1] != ':') {
            throw std::runtime_error("Invalid IPv6 pairing address");
        }
        host = hostPort.substr(1, close - 1);
        port = hostPort.substr(close + 2);
        return;
    }

    const size_t colon = hostPort.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= hostPort.size()) {
        throw std::runtime_error("Pairing address must be host:port");
    }

    host = hostPort.substr(0, colon);
    port = hostPort.substr(colon + 1);
}

UniqueFd ConnectTcp(const std::string& host, const std::string& port) {
    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    addrinfo* result = nullptr;
    const int gai = getaddrinfo(host.c_str(), port.c_str(), &hints, &result);
    if (gai != 0) {
        throw std::runtime_error("Failed to resolve pairing address");
    }

    std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> addrResult(result, freeaddrinfo);
    std::string lastError = "connect failed";

    for (addrinfo* ai = addrResult.get(); ai != nullptr; ai = ai->ai_next) {
        UniqueFd fd(::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol));
        if (fd.get() < 0) {
            continue;
        }

        const int flags = fcntl(fd.get(), F_GETFL, 0);
        if (flags >= 0) {
            fcntl(fd.get(), F_SETFL, flags | O_NONBLOCK);
        }

        int rc = ::connect(fd.get(), ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) {
            if (flags >= 0) {
                fcntl(fd.get(), F_SETFL, flags);
            }
            int off = 1;
            setsockopt(fd.get(), IPPROTO_TCP, TCP_NODELAY, &off, sizeof(off));
            return fd;
        }

        if (errno != EINPROGRESS) {
            lastError = std::strerror(errno);
            continue;
        }

        fd_set writeSet;
        FD_ZERO(&writeSet);
        FD_SET(fd.get(), &writeSet);
        timeval timeout {};
        timeout.tv_sec = kConnectTimeoutSeconds;
        timeout.tv_usec = 0;
        rc = select(fd.get() + 1, nullptr, &writeSet, nullptr, &timeout);
        if (rc <= 0) {
            lastError = rc == 0 ? "connect timeout" : std::strerror(errno);
            continue;
        }

        int soError = 0;
        socklen_t soErrorLen = sizeof(soError);
        if (getsockopt(fd.get(), SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) != 0 || soError != 0) {
            lastError = std::strerror(soError == 0 ? errno : soError);
            continue;
        }

        if (flags >= 0) {
            fcntl(fd.get(), F_SETFL, flags);
        }
        int off = 1;
        setsockopt(fd.get(), IPPROTO_TCP, TCP_NODELAY, &off, sizeof(off));
        return fd;
    }

    throw std::runtime_error("Failed to connect pairing socket: " + lastError);
}

PairingAuthPtr CreatePairingAuth(const std::vector<uint8_t>& password) {
    PairingAuthPtr auth(pairing_auth_client_new(password.data(), password.size()));
    if (!auth) {
        throw std::runtime_error("Unable to create pairing auth context");
    }
    return auth;
}

void WriteHeader(TlsConnection& tls, uint8_t type, std::string_view payload) {
    PairingPacketHeader header {kCurrentKeyHeaderVersion, type, static_cast<uint32_t>(payload.size())};
    PairingPacketHeader networkHeader = header;
    networkHeader.payload = htonl(networkHeader.payload);
    if (!tls.WriteFully(std::string_view(reinterpret_cast<const char*>(&networkHeader), sizeof(networkHeader))) ||
        !tls.WriteFully(payload)) {
        throw std::runtime_error("Failed to write pairing packet");
    }
}

PairingPacketHeader ReadHeader(TlsConnection& tls) {
    std::vector<uint8_t> data = tls.ReadFully(sizeof(PairingPacketHeader));
    if (data.size() != sizeof(PairingPacketHeader)) {
        throw std::runtime_error("Failed to read pairing packet header");
    }

    PairingPacketHeader header {};
    const uint8_t* p = data.data();
    header.version = p[0];
    header.type = p[1];
    uint32_t payload = 0;
    std::memcpy(&payload, p + 2, sizeof(payload));
    header.payload = ntohl(payload);

    if (header.version != kCurrentKeyHeaderVersion) {
        throw std::runtime_error("Unsupported pairing packet version");
    }
    if (header.type != kPacketTypeSpake2Msg && header.type != kPacketTypePeerInfo) {
        throw std::runtime_error("Unsupported pairing packet type");
    }
    if (header.payload == 0 || header.payload > kMaxPayloadSize) {
        throw std::runtime_error("Invalid pairing packet payload");
    }
    return header;
}

std::string PeerInfoToString(const PeerInfo& info) {
    const size_t len = strnlen(reinterpret_cast<const char*>(info.data), sizeof(info.data));
    return std::string(reinterpret_cast<const char*>(info.data), len);
}

}  // namespace

std::string AdbPair(const std::string& hostPort, const std::string& pairingCode, const std::string& publicKeyPath,
                    const std::string& privateKeyPath) {
    if (pairingCode.empty()) {
        throw std::runtime_error("Pairing code is empty");
    }

    std::string host;
    std::string port;
    ParseHostPort(hostPort, host, port);

    const std::string pubKey = ReadPublicKeyString(publicKeyPath);
    if (pubKey.empty()) {
        throw std::runtime_error("ADB public key is empty");
    }

    const std::string privateKeyPem = ReadFileToString(privateKeyPath);
    bssl::UniquePtr<EVP_PKEY> privateKey = LoadPrivateKey(privateKeyPem);
    if (!privateKey) {
        throw std::runtime_error("Failed to load ADB private key");
    }

    const std::string certPem = GenerateCertificatePem(privateKey.get());
    const std::string normalizedPrivateKeyPem = PrivateKeyToPem(privateKey.get());

    PeerInfo myInfo {};
    myInfo.type = ADB_RSA_PUB_KEY;
    if (pubKey.size() > sizeof(myInfo.data) - 1) {
        throw std::runtime_error("ADB public key is too large for pairing peer info");
    }
    std::memcpy(myInfo.data, pubKey.data(), pubKey.size());

    UniqueFd fd = ConnectTcp(host, port);
    std::unique_ptr<TlsConnection> tls = TlsConnection::Create(TlsConnection::Role::Client, certPem,
                                                               normalizedPrivateKeyPem, fd.get());
    if (!tls) {
        throw std::runtime_error("Failed to create pairing TLS connection");
    }

    tls->SetCertVerifyCallback([](X509_STORE_CTX*) { return 1; });
    if (tls->DoHandshake() != TlsConnection::TlsError::Success) {
        throw std::runtime_error("TLS handshake failed during pairing");
    }

    std::vector<uint8_t> exported = tls->ExportKeyingMaterial(kExportedKeySize);
    if (exported.empty()) {
        throw std::runtime_error("Failed to export TLS key material");
    }

    std::vector<uint8_t> password(pairingCode.begin(), pairingCode.end());
    password.insert(password.end(), exported.begin(), exported.end());
    PairingAuthPtr auth = CreatePairingAuth(password);

    const uint32_t msgSize = static_cast<uint32_t>(pairing_auth_msg_size(auth.get()));
    std::vector<uint8_t> myMsg(msgSize);
    pairing_auth_get_spake2_msg(auth.get(), myMsg.data());
    WriteHeader(*tls, kPacketTypeSpake2Msg,
                std::string_view(reinterpret_cast<const char*>(myMsg.data()), myMsg.size()));

    PairingPacketHeader header = ReadHeader(*tls);
    if (header.type != kPacketTypeSpake2Msg) {
        throw std::runtime_error("Unexpected pairing packet type while waiting for SPAKE2 message");
    }

    std::vector<uint8_t> peerMsg = tls->ReadFully(header.payload);
    if (peerMsg.empty() || !pairing_auth_init_cipher(auth.get(), peerMsg.data(), peerMsg.size())) {
        throw std::runtime_error("Failed to initialize pairing cipher");
    }

    std::vector<uint8_t> peerInfoBytes(reinterpret_cast<const uint8_t*>(&myInfo),
                                       reinterpret_cast<const uint8_t*>(&myInfo) + sizeof(myInfo));
    std::vector<uint8_t> encrypted(pairing_auth_safe_encrypted_size(auth.get(), peerInfoBytes.size()));
    size_t encryptedSize = 0;
    if (!pairing_auth_encrypt(auth.get(), peerInfoBytes.data(), peerInfoBytes.size(), encrypted.data(), &encryptedSize)) {
        throw std::runtime_error("Failed to encrypt pairing peer info");
    }
    encrypted.resize(encryptedSize);
    WriteHeader(*tls, kPacketTypePeerInfo,
                std::string_view(reinterpret_cast<const char*>(encrypted.data()), encrypted.size()));

    header = ReadHeader(*tls);
    if (header.type != kPacketTypePeerInfo) {
        throw std::runtime_error("Unexpected pairing packet type while waiting for peer info");
    }

    std::vector<uint8_t> encryptedPeerInfo = tls->ReadFully(header.payload);
    if (encryptedPeerInfo.empty()) {
        throw std::runtime_error("Failed to read encrypted peer info");
    }

    std::vector<uint8_t> decrypted(pairing_auth_safe_decrypted_size(auth.get(), encryptedPeerInfo.data(),
                                                                    encryptedPeerInfo.size()));
    size_t decryptedSize = 0;
    if (decrypted.empty() ||
        !pairing_auth_decrypt(auth.get(), encryptedPeerInfo.data(), encryptedPeerInfo.size(), decrypted.data(),
                              &decryptedSize)) {
        throw std::runtime_error("Failed to decrypt peer info");
    }
    decrypted.resize(decryptedSize);

    if (decrypted.size() != sizeof(PeerInfo)) {
        throw std::runtime_error("Unexpected peer info size");
    }

    PeerInfo theirInfo {};
    std::memcpy(&theirInfo, decrypted.data(), sizeof(theirInfo));
    if (theirInfo.type != ADB_DEVICE_GUID) {
        throw std::runtime_error("Pairing succeeded but peer did not return a device guid");
    }

    const std::string guid = PeerInfoToString(theirInfo);
    if (guid.empty()) {
        throw std::runtime_error("Pairing succeeded but device guid is empty");
    }

    return guid;
}

}  // namespace scrcpy::pairing
