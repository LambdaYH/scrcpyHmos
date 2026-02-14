// AdbProtocol - ADB协议实现
// 参考 AdbProtocol.ets 实现
#include "AdbProtocol.h"
#include <cstring>
#include <stdexcept>
#include <unistd.h>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "AdbProtocol"

// 辅助：从fd精确读取指定字节数
static void readExact(int fd, uint8_t* buf, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = ::read(fd, buf + offset, len - offset);
        if (n <= 0) {
            throw std::runtime_error("AdbProtocol: read failed or connection closed");
        }
        offset += static_cast<size_t>(n);
    }
}

AdbMessage AdbMessage::parse(int fd) {
    uint8_t header[AdbProtocol::ADB_HEADER_LENGTH];
    readExact(fd, header, AdbProtocol::ADB_HEADER_LENGTH);

    auto readU32LE = [&](int off) -> uint32_t {
        return static_cast<uint32_t>(header[off])
             | (static_cast<uint32_t>(header[off + 1]) << 8)
             | (static_cast<uint32_t>(header[off + 2]) << 16)
             | (static_cast<uint32_t>(header[off + 3]) << 24);
    };

    uint32_t command = readU32LE(0);
    uint32_t arg0 = readU32LE(4);
    uint32_t arg1 = readU32LE(8);
    uint32_t payloadLength = readU32LE(12);
    // checksum at offset 16 - not verified like Java version
    // magic at offset 20 - not verified like Java version

    AdbMessage msg(command, arg0, arg1, payloadLength);

    if (payloadLength > 0) {
        msg.payload.resize(payloadLength);
        readExact(fd, msg.payload.data(), payloadLength);
    }

    return msg;
}

// CONNECT_PAYLOAD: "host::\0"
static const uint8_t CONNECT_PAYLOAD[] = { 0x68, 0x6f, 0x73, 0x74, 0x3a, 0x3a, 0x00 };

std::vector<uint8_t> AdbProtocol::generateConnect() {
    return generateMessage(CMD_CNXN, CONNECT_VERSION, CONNECT_MAXDATA,
                           CONNECT_PAYLOAD, sizeof(CONNECT_PAYLOAD));
}

std::vector<uint8_t> AdbProtocol::generateAuth(uint32_t type, const uint8_t* data, size_t len) {
    return generateMessage(CMD_AUTH, type, 0, data, len);
}

std::vector<uint8_t> AdbProtocol::generateOpen(int32_t localId, const std::string& dest) {
    // 追加 '\0' 结尾
    std::vector<uint8_t> destBytes(dest.begin(), dest.end());
    destBytes.push_back(0);
    return generateMessage(CMD_OPEN, static_cast<uint32_t>(localId), 0,
                           destBytes.data(), destBytes.size());
}

std::vector<uint8_t> AdbProtocol::generateWrite(int32_t localId, int32_t remoteId,
                                                  const uint8_t* data, size_t len) {
    return generateMessage(CMD_WRTE, static_cast<uint32_t>(localId),
                           static_cast<uint32_t>(remoteId), data, len);
}

std::vector<uint8_t> AdbProtocol::generateClose(int32_t localId, int32_t remoteId) {
    return generateMessage(CMD_CLSE, static_cast<uint32_t>(localId),
                           static_cast<uint32_t>(remoteId), nullptr, 0);
}

std::vector<uint8_t> AdbProtocol::generateOkay(int32_t localId, int32_t remoteId) {
    return generateMessage(CMD_OKAY, static_cast<uint32_t>(localId),
                           static_cast<uint32_t>(remoteId), nullptr, 0);
}

std::vector<uint8_t> AdbProtocol::generateSyncHeader(const char id[4], int32_t arg) {
    std::vector<uint8_t> result(8);
    // 写入 4 字节 ID (ASCII)
    result[0] = static_cast<uint8_t>(id[0]);
    result[1] = static_cast<uint8_t>(id[1]);
    result[2] = static_cast<uint8_t>(id[2]);
    result[3] = static_cast<uint8_t>(id[3]);
    // 写入 4 字节小端整数 arg
    uint32_t uarg = static_cast<uint32_t>(arg);
    result[4] = static_cast<uint8_t>(uarg & 0xFF);
    result[5] = static_cast<uint8_t>((uarg >> 8) & 0xFF);
    result[6] = static_cast<uint8_t>((uarg >> 16) & 0xFF);
    result[7] = static_cast<uint8_t>((uarg >> 24) & 0xFF);
    return result;
}

std::vector<uint8_t> AdbProtocol::generateMessage(uint32_t cmd, uint32_t arg0, uint32_t arg1,
                                                    const uint8_t* payload, size_t payloadLen) {
    size_t size = ADB_HEADER_LENGTH + payloadLen;
    std::vector<uint8_t> result(size, 0);

    auto writeU32LE = [&](size_t off, uint32_t val) {
        result[off]     = static_cast<uint8_t>(val & 0xFF);
        result[off + 1] = static_cast<uint8_t>((val >> 8) & 0xFF);
        result[off + 2] = static_cast<uint8_t>((val >> 16) & 0xFF);
        result[off + 3] = static_cast<uint8_t>((val >> 24) & 0xFF);
    };

    writeU32LE(0, cmd);
    writeU32LE(4, arg0);
    writeU32LE(8, arg1);

    if (payload == nullptr || payloadLen == 0) {
        writeU32LE(12, 0);
        writeU32LE(16, 0);
    } else {
        writeU32LE(12, static_cast<uint32_t>(payloadLen));
        writeU32LE(16, payloadChecksum(payload, payloadLen));
    }

    // magic = ~cmd
    writeU32LE(20, ~cmd);

    if (payload != nullptr && payloadLen > 0) {
        std::memcpy(result.data() + ADB_HEADER_LENGTH, payload, payloadLen);
    }

    return result;
}

uint32_t AdbProtocol::payloadChecksum(const uint8_t* payload, size_t len) {
    uint32_t checksum = 0;
    for (size_t i = 0; i < len; i++) {
        checksum += payload[i];
    }
    return checksum;
}
