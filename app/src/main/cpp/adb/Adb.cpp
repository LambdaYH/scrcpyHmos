// Adb - 完整的ADB实现
// 参考 Adb.ets 实现
#include "Adb.h"
#include "TcpChannel.h"
#include <cstring>
#include <stdexcept>
#include <algorithm>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "Adb"

Adb::Adb(AdbChannel* channel) : channel_(channel) {}

Adb::~Adb() {
    close();
    delete channel_;
}

Adb* Adb::create(int fd) {
    AdbChannel* channel = new TcpChannel(fd);
    return new Adb(channel);
}

// 通过channel读取一个ADB消息
static AdbMessage readMessageFromChannel(AdbChannel* channel) {
    uint8_t header[AdbProtocol::ADB_HEADER_LENGTH];
    channel->read(header, AdbProtocol::ADB_HEADER_LENGTH);

    auto readU32LE = [&](int off) -> uint32_t {
        return static_cast<uint32_t>(header[off])
             | (static_cast<uint32_t>(header[off + 1]) << 8)
             | (static_cast<uint32_t>(header[off + 2]) << 16)
             | (static_cast<uint32_t>(header[off + 3]) << 24);
    };

    AdbMessage msg(readU32LE(0), readU32LE(4), readU32LE(8), readU32LE(12));
    if (msg.payloadLength > 0) {
        msg.payload.resize(msg.payloadLength);
        channel->read(msg.payload.data(), msg.payloadLength);
    }
    return msg;
}

int Adb::connect(AdbKeyPair& keyPair) {
    // 发送CONNECT消息
    OH_LOG_INFO(LOG_APP, "ADB: Sending CONNECT message...");
    auto connectMsg = AdbProtocol::generateConnect();
    channel_->write(connectMsg.data(), connectMsg.size());
    OH_LOG_INFO(LOG_APP, "ADB: CONNECT sent, waiting for response...");

    AdbMessage message = readMessageFromChannel(channel_);
    OH_LOG_INFO(LOG_APP, "ADB: Received response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u payloadLen=%{public}u",
                message.command, message.arg0, message.arg1, message.payloadLength);
    int authResult = 0; // 0=已授权/无需授权, 1=需要用户确认, -1=失败

    if (message.command == AdbProtocol::CMD_AUTH) {
        OH_LOG_INFO(LOG_APP, "ADB: Got AUTH challenge, signing payload...");
        // 发送签名
        auto signature = keyPair.signPayload(message.payload.data(), message.payload.size());
        OH_LOG_INFO(LOG_APP, "ADB: Signature generated, size=%{public}zu, sending AUTH_SIGNATURE...", signature.size());
        auto authMsg = AdbProtocol::generateAuth(AdbProtocol::AUTH_TYPE_SIGNATURE,
                                                  signature.data(), signature.size());
        channel_->write(authMsg.data(), authMsg.size());

        OH_LOG_INFO(LOG_APP, "ADB: AUTH_SIGNATURE sent, waiting for response...");
        message = readMessageFromChannel(channel_);
        OH_LOG_INFO(LOG_APP, "ADB: Received response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u payloadLen=%{public}u",
                    message.command, message.arg0, message.arg1, message.payloadLength);

        if (message.command == AdbProtocol::CMD_AUTH) {
            // 需要发送公钥
            OH_LOG_INFO(LOG_APP, "ADB: Still AUTH, sending public key, size: %{public}zu",
                         keyPair.getPublicKeyBytes().size());

            authResult = 1; // 需要用户在设备上确认授权

            auto pubKeyMsg = AdbProtocol::generateAuth(AdbProtocol::AUTH_TYPE_RSA_PUBLIC,
                                                        keyPair.getPublicKeyBytes().data(),
                                                        keyPair.getPublicKeyBytes().size());
            channel_->write(pubKeyMsg.data(), pubKeyMsg.size());
            OH_LOG_INFO(LOG_APP, "ADB: Public key sent, waiting for CNXN...");
            message = readMessageFromChannel(channel_);
            OH_LOG_INFO(LOG_APP, "ADB: Received response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u",
                        message.command, message.arg0, message.arg1);
        }
    }

    if (message.command != AdbProtocol::CMD_CNXN) {
        OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN (0x%{public}x) but got 0x%{public}x, auth FAILED",
                     AdbProtocol::CMD_CNXN, message.command);
        channel_->close();
        return -1;
    }

    maxData_ = message.arg0;
    OH_LOG_INFO(LOG_APP, "ADB: connected, maxData=%{public}u", maxData_);

    // 启动后台消息处理
    handleInRunning_.store(true);
    handleInThread_ = std::thread(&Adb::handleInLoop, this);

    return authResult;
}

void Adb::handleInLoop() {
    try {
        while (handleInRunning_.load() && !isClosed_.load()) {
            AdbMessage message;
            try {
                message = readMessageFromChannel(channel_);
            } catch (...) {
                if (isClosed_.load()) break;
                throw;
            }

            if (isClosed_.load() || !handleInRunning_.load()) break;

            // 查找对应的流
            AdbStream* stream = nullptr;
            bool isNeedNotify = false;

            {
                std::lock_guard<std::mutex> lock(streamsMutex_);
                auto it = connectionStreams_.find(static_cast<int32_t>(message.arg1));
                if (it != connectionStreams_.end()) {
                    stream = it->second;
                } else {
                    isNeedNotify = true;
                    OH_LOG_DEBUG(LOG_APP, "[ADB] New connection: localId=%{public}u, remoteId=%{public}u",
                                 message.arg1, message.arg0);
                    stream = createNewStream(static_cast<int32_t>(message.arg1),
                                             static_cast<int32_t>(message.arg0),
                                             static_cast<int32_t>(message.arg1) > 0);
                }
            }

            if (!stream) continue;

            switch (message.command) {
                case AdbProtocol::CMD_OKAY: {
                    std::lock_guard<std::mutex> lock(stream->readMutex);
                    stream->canWrite = true;
                    stream->readCv.notify_all();
                    break;
                }
                case AdbProtocol::CMD_WRTE: {
                    if (isClosed_.load()) break;
                    pushToStream(stream, message.payload.data(), message.payload.size());
                    auto okayMsg = AdbProtocol::generateOkay(
                        static_cast<int32_t>(message.arg1), static_cast<int32_t>(message.arg0));
                    writeToChannel(okayMsg);
                    break;
                }
                case AdbProtocol::CMD_CLSE: {
                    OH_LOG_DEBUG(LOG_APP, "[ADB] Connection closed: localId=%{public}u", message.arg1);
                    {
                        std::lock_guard<std::mutex> lock(stream->readMutex);
                        stream->closed = true;
                        stream->readCv.notify_all();
                    }
                    isNeedNotify = true;
                    break;
                }
            }

            if (isNeedNotify) {
                notifyAll();
            }
        }
        OH_LOG_INFO(LOG_APP, "[ADB] handleIn loop exited normally");
    } catch (const std::exception& e) {
        if (!isClosed_.load()) {
            OH_LOG_ERROR(LOG_APP, "ADB handleIn error: %{public}s", e.what());
        } else {
            OH_LOG_INFO(LOG_APP, "[ADB] handleIn exited due to close");
        }
        close();
    }
}

int32_t Adb::open(const std::string& destination, bool canMultipleSend) {
    int32_t localId = localIdPool_++;
    if (!canMultipleSend) localId = -localId;

    auto openMsg = AdbProtocol::generateOpen(localId, destination);
    writeToChannel(openMsg);

    // 等待流建立
    AdbStream* stream = nullptr;
    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isClosed_.load()) {
            {
                std::lock_guard<std::mutex> slock(streamsMutex_);
                auto it = openStreams_.find(localId);
                if (it != openStreams_.end()) {
                    stream = it->second;
                    openStreams_.erase(it);
                    break;
                }
            }
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    if (!stream) {
        throw std::runtime_error("Failed to open stream");
    }

    return localId;
}

std::string Adb::restartOnTcpip(int port) {
    int32_t streamId = open("tcpip:" + std::to_string(port), false);

    // 等待流关闭
    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isStreamClosed(streamId) && !isClosed_.load()) {
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    auto data = streamReadAllBeforeClose(streamId);
    return std::string(data.begin(), data.end());
}

void Adb::pushFile(const uint8_t* fileData, size_t fileLen,
                   const std::string& remotePath, ProcessCallback callback) {
    int32_t streamId = open("sync:", true);
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) stream = it->second;
    }
    if (!stream) throw std::runtime_error("Failed to open sync stream");

    // 发送信令，建立push通道
    std::string sendString = remotePath + ",33206";

    auto sendHeader = AdbProtocol::generateSyncHeader("SEND", static_cast<int32_t>(sendString.size()));
    streamWriteRaw(stream, sendHeader.data(), sendHeader.size());
    streamWriteRaw(stream, reinterpret_cast<const uint8_t*>(sendString.data()), sendString.size());

    // 发送文件
    const size_t chunkSize = 10240 - 8;
    size_t hasSendLen = 0;
    int lastProcess = 0;

    size_t offset = 0;
    while (offset < fileLen) {
        size_t len = std::min(chunkSize, fileLen - offset);

        auto dataHeader = AdbProtocol::generateSyncHeader("DATA", static_cast<int32_t>(len));
        streamWriteRaw(stream, dataHeader.data(), dataHeader.size());
        streamWriteRaw(stream, fileData + offset, len);

        hasSendLen += len;
        int newProcess = static_cast<int>((hasSendLen * 100) / fileLen);
        if (newProcess != lastProcess) {
            lastProcess = newProcess;
            if (callback) callback(lastProcess);
        }
        offset += len;
    }

    // 传输完成
    auto doneHeader = AdbProtocol::generateSyncHeader("DONE", 1704038400);
    streamWriteRaw(stream, doneHeader.data(), doneHeader.size());

    auto quitHeader = AdbProtocol::generateSyncHeader("QUIT", 0);
    streamWriteRaw(stream, quitHeader.data(), quitHeader.size());

    // 等待流关闭
    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isStreamClosed(streamId) && !isClosed_.load()) {
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }
}

std::string Adb::runAdbCmd(const std::string& cmd) {
    int32_t streamId = open("shell:" + cmd, true);

    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isStreamClosed(streamId) && !isClosed_.load()) {
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    auto data = streamReadAllBeforeClose(streamId);
    return std::string(data.begin(), data.end());
}

int32_t Adb::getShell() {
    return open("shell:", true);
}

int32_t Adb::tcpForward(int port) {
    int32_t streamId = open("tcp:" + std::to_string(port), true);
    if (isStreamClosed(streamId)) {
        throw std::runtime_error("error forward");
    }
    return streamId;
}

int32_t Adb::localSocketForward(const std::string& socketName) {
    int32_t streamId = open("localabstract:" + socketName, true);
    if (isStreamClosed(streamId)) {
        throw std::runtime_error("error forward");
    }
    return streamId;
}

std::vector<uint8_t> Adb::streamRead(int32_t streamId, size_t size) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) stream = it->second;
    }
    if (!stream) throw std::runtime_error("Stream not found");

    std::vector<uint8_t> result;
    std::unique_lock<std::mutex> lock(stream->readMutex);

    while (result.size() < size && !stream->closed) {
        if (stream->readBuffer.size() >= size - result.size()) {
            size_t need = size - result.size();
            result.insert(result.end(), stream->readBuffer.begin(),
                          stream->readBuffer.begin() + need);
            stream->readBuffer.erase(stream->readBuffer.begin(),
                                     stream->readBuffer.begin() + need);
            break;
        }

        if (!stream->readBuffer.empty()) {
            result.insert(result.end(), stream->readBuffer.begin(), stream->readBuffer.end());
            stream->readBuffer.clear();
        }

        stream->readCv.wait_for(lock, std::chrono::milliseconds(100));
    }

    return result;
}

void Adb::streamWrite(int32_t streamId, const uint8_t* data, size_t len) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) stream = it->second;
    }
    if (!stream) throw std::runtime_error("Stream not found");

    streamWriteRaw(stream, data, len);
}

void Adb::streamWriteRaw(AdbStream* stream, const uint8_t* data, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        size_t chunkSize = std::min(static_cast<size_t>(maxData_ - 128), len - offset);
        auto writeMsg = AdbProtocol::generateWrite(stream->localId, stream->remoteId,
                                                    data + offset, chunkSize);
        writeToChannel(writeMsg);
        offset += chunkSize;
    }
}

void Adb::streamClose(int32_t streamId) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) {
            stream = it->second;
            connectionStreams_.erase(it);
        }
    }
    if (stream) {
        auto closeMsg = AdbProtocol::generateClose(stream->localId, stream->remoteId);
        writeToChannel(closeMsg);

        std::lock_guard<std::mutex> lock(stream->readMutex);
        stream->closed = true;
        stream->readCv.notify_all();
    }
}

bool Adb::isStreamClosed(int32_t streamId) {
    std::lock_guard<std::mutex> lock(streamsMutex_);
    auto it = connectionStreams_.find(streamId);
    if (it == connectionStreams_.end()) return true;
    return it->second->closed;
}

std::vector<uint8_t> Adb::streamReadAllBeforeClose(int32_t streamId) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) stream = it->second;
    }
    if (!stream) return {};

    std::lock_guard<std::mutex> lock(stream->readMutex);
    std::vector<uint8_t> result;
    result.insert(result.end(), stream->closedData.begin(), stream->closedData.end());
    result.insert(result.end(), stream->readBuffer.begin(), stream->readBuffer.end());
    return result;
}

void Adb::close() {
    bool expected = false;
    if (!isClosed_.compare_exchange_strong(expected, true)) return;

    handleInRunning_.store(false);

    // 关闭所有流
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        for (auto& pair : connectionStreams_) {
            std::lock_guard<std::mutex> slock(pair.second->readMutex);
            pair.second->closed = true;
            pair.second->readCv.notify_all();
        }
    }

    if (channel_) {
        channel_->close();
    }

    notifyAll();

    if (handleInThread_.joinable()) {
        handleInThread_.join();
    }

    // 清理流
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        for (auto& pair : connectionStreams_) {
            delete pair.second;
        }
        connectionStreams_.clear();
        for (auto& pair : openStreams_) {
            // 只删除不在connectionStreams中的
            if (connectionStreams_.find(pair.first) == connectionStreams_.end()) {
                delete pair.second;
            }
        }
        openStreams_.clear();
    }
}

void Adb::writeToChannel(const std::vector<uint8_t>& data) {
    try {
        std::lock_guard<std::mutex> lock(channelWriteMutex_);
        channel_->write(data.data(), data.size());
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "ADB writeToChannel error: %{public}s", e.what());
        close();
    }
}

AdbStream* Adb::createNewStream(int32_t localId, int32_t remoteId, bool canMultipleSend) {
    auto* stream = new AdbStream();
    stream->localId = localId;
    stream->remoteId = remoteId;
    stream->canMultipleSend = canMultipleSend;

    connectionStreams_[localId] = stream;
    openStreams_[localId] = stream;

    return stream;
}

void Adb::pushToStream(AdbStream* stream, const uint8_t* data, size_t len) {
    std::lock_guard<std::mutex> lock(stream->readMutex);
    stream->readBuffer.insert(stream->readBuffer.end(), data, data + len);
    if (stream->closed) {
        stream->closedData.insert(stream->closedData.end(), data, data + len);
    }
    stream->readCv.notify_all();
}

void Adb::waitForNotify() {
    std::unique_lock<std::mutex> lock(waitMutex_);
    waitCv_.wait_for(lock, std::chrono::milliseconds(100));
}

void Adb::notifyAll() {
    waitCv_.notify_all();
}
