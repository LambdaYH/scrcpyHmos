#include "adb/channel/TlsAdbChannel.h"

#include <cstring>
#include <stdexcept>
#include <string_view>
#include <sys/socket.h>
#include <unistd.h>

TlsAdbChannel::TlsAdbChannel(std::unique_ptr<scrcpy::pairing::TlsConnection> tlsConnection, int fd)
    : tlsConnection_(std::move(tlsConnection)), fd_(fd) {
    if (!tlsConnection_ || fd_ < 0) {
        throw std::invalid_argument("Invalid TLS ADB channel");
    }
}

TlsAdbChannel::~TlsAdbChannel() {
    if (!closed_.load()) {
        close();
    }
    tlsConnection_.reset();
}

void TlsAdbChannel::write(const uint8_t* data, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TlsAdbChannel: write on closed channel");
    }
    if (!tlsConnection_->WriteFully(std::string_view(reinterpret_cast<const char*>(data), len))) {
        throw std::runtime_error("TlsAdbChannel: write failed");
    }
}

void TlsAdbChannel::read(uint8_t* buf, size_t len) {
    readWithTimeout(buf, len, -1);
}

void TlsAdbChannel::readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) {
    (void)timeoutMs;
    if (closed_.load()) {
        throw std::runtime_error("TlsAdbChannel: read on closed channel");
    }
    std::vector<uint8_t> data = tlsConnection_->ReadFully(len);
    if (data.size() != len) {
        throw std::runtime_error("TlsAdbChannel: read failed");
    }
    std::memcpy(buf, data.data(), len);
}

void TlsAdbChannel::close() {
    if (closed_.exchange(true)) {
        return;
    }
    if (fd_ >= 0) {
        ::shutdown(fd_, SHUT_RDWR);
        ::close(fd_);
        fd_ = -1;
    }
}

bool TlsAdbChannel::isClosed() const {
    return closed_.load();
}
