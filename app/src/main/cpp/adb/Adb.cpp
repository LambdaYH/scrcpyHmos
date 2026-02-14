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

Adb::Adb(AdbChannel* channel) : channel_(channel) {
    sendRunning_.store(true);
    sendThread_ = std::thread(&Adb::sendLoop, this);
}

Adb::~Adb() {
    close();
    delete channel_;
}



// 通过channel读取一个ADB消息
static AdbMessage readMessageFromChannel(AdbChannel* channel, int timeoutMs = -1) {
    uint8_t header[AdbProtocol::ADB_HEADER_LENGTH];
    channel->readWithTimeout(header, AdbProtocol::ADB_HEADER_LENGTH, timeoutMs);

    auto readU32LE = [&](int off) -> uint32_t {
        return static_cast<uint32_t>(header[off])
             | (static_cast<uint32_t>(header[off + 1]) << 8)
             | (static_cast<uint32_t>(header[off + 2]) << 16)
             | (static_cast<uint32_t>(header[off + 3]) << 24);
    };

    AdbMessage msg(readU32LE(0), readU32LE(4), readU32LE(8), readU32LE(12));
    if (msg.payloadLength > 0) {
        msg.payload.resize(msg.payloadLength);
        channel->readWithTimeout(msg.payload.data(), msg.payloadLength, timeoutMs);
    }
    return msg;
}

int Adb::connect(AdbKeyPair& keyPair, AuthCallback onWaitAuth) {
    // 发送CONNECT消息
    OH_LOG_INFO(LOG_APP, "ADB: Sending CONNECT message...");
    auto connectMsg = AdbProtocol::generateConnect();
    channel_->write(connectMsg.data(), connectMsg.size());
    OH_LOG_INFO(LOG_APP, "ADB: CONNECT sent, waiting for response (timeout 10s)...");

    AdbMessage message;
    try {
        message = readMessageFromChannel(channel_, 10000);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "ADB: CONNECT response timeout or error: %{public}s", e.what());
        channel_->close();
        return -4; // Connect Timeout/Error
    }

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

        OH_LOG_INFO(LOG_APP, "ADB: AUTH_SIGNATURE sent, waiting for response (timeout 5s)...");
        
        bool authFailedOrTimeout = false;
        try {
            message = readMessageFromChannel(channel_, 5000);
            OH_LOG_INFO(LOG_APP, "ADB: Received response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u payloadLen=%{public}u",
                        message.command, message.arg0, message.arg1, message.payloadLength);
            
            if (message.command == AdbProtocol::CMD_AUTH) {
                authFailedOrTimeout = true;
            }
        } catch (const std::exception& e) {
            OH_LOG_WARN(LOG_APP, "ADB: Wait for AUTH response timeout or error: %{public}s. Proceeding to send Public Key.", e.what());
            authFailedOrTimeout = true;
        }

        if (authFailedOrTimeout) {
            // 需要发送公钥
            OH_LOG_INFO(LOG_APP, "ADB: Still AUTH or Timeout, sending public key, size: %{public}zu",
                         keyPair.getPublicKeyBytes().size());

            authResult = 1; // 需要用户在设备上确认授权

            auto pubKeyMsg = AdbProtocol::generateAuth(AdbProtocol::AUTH_TYPE_RSA_PUBLIC,
                                                        keyPair.getPublicKeyBytes().data(),
                                                        keyPair.getPublicKeyBytes().size());
            channel_->write(pubKeyMsg.data(), pubKeyMsg.size());
            OH_LOG_INFO(LOG_APP, "ADB: Public key sent, waiting for CNXN...");
            
            if (onWaitAuth) {
                OH_LOG_INFO(LOG_APP, "ADB: Invoking onWaitAuth callback");
                onWaitAuth();
            }

            // Wait longer for user confirmation (e.g. 30s)
            // But if user cancels, TcpChannel::close() will unblock read() via shutdown().
            try {
                message = readMessageFromChannel(channel_, 30000); 
            } catch (const std::exception& e) {
                 OH_LOG_ERROR(LOG_APP, "ADB: Wait for CNXN error/timeout: %{public}s", e.what());
                 channel_->close();
                 // Return -5 to indicate timeout/auth wait failure specifically
                 return -5; 
            }
            
            // If we are here, we got a message. Check if it is CNXN.
            if (message.command != AdbProtocol::CMD_CNXN) {
                OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN but got 0x%{public}x", message.command);
                channel_->close();
                return -3;
            }
        }
    } else if (message.command != AdbProtocol::CMD_CNXN) {
         OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN or AUTH but got 0x%{public}x", message.command);
         channel_->close();
         return -1;
    }
    
    // At this point, `message` should be CNXN.
    if (message.command != AdbProtocol::CMD_CNXN) {
        OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN (0x%{public}x) but got 0x%{public}x",
                     AdbProtocol::CMD_CNXN, message.command);
        channel_->close();
        return -1;
    }


    maxData_ = message.arg0;
    OH_LOG_INFO(LOG_APP, "ADB: connected, maxData=%{public}u", maxData_);

    // 启动后台消息处理
    handleInRunning_.store(true);
    handleInThread_ = std::thread(&Adb::handleInLoop, this);

    return 0;
}

void Adb::handleInLoop() {
    try {
        const size_t HEADER_SIZE = 24;
        uint8_t headerBuf[24];
        std::vector<uint8_t> tempPayload;

        while (handleInRunning_.load() && !isClosed_.load()) {
            // 1. Read Header (24 bytes)
            try {
                channel_->readWithTimeout(headerBuf, HEADER_SIZE, -1);
            } catch (...) {
                if (isClosed_.load()) break;
                throw; // Re-throw to exit loop
            }

            if (isClosed_.load() || !handleInRunning_.load()) break;

            // 2. Parse Header
            auto readU32LE = [&](int off) -> uint32_t {
                return static_cast<uint32_t>(headerBuf[off])
                     | (static_cast<uint32_t>(headerBuf[off + 1]) << 8)
                     | (static_cast<uint32_t>(headerBuf[off + 2]) << 16)
                     | (static_cast<uint32_t>(headerBuf[off + 3]) << 24);
            };
            
            uint32_t cmd = readU32LE(0);
            uint32_t arg0 = readU32LE(4);
            uint32_t arg1 = readU32LE(8);
            uint32_t payloadLen = readU32LE(12);
            // checksum (16) and magic (20) ignored for now

            // OH_LOG_INFO(LOG_APP, "[ADB] Recv Header: cmd=0x%{public}x len=%{public}u", cmd, payloadLen);

            // 3. Handle Payload
            AdbStream* stream = nullptr;
            bool isNeedNotify = false; // Moved here
            {
                std::lock_guard<std::mutex> lock(streamsMutex_);
                auto it = connectionStreams_.find(static_cast<int32_t>(arg1));
                if (it != connectionStreams_.end()) {
                    stream = it->second;
                } else {
                    isNeedNotify = true;
                    OH_LOG_DEBUG(LOG_APP, "[ADB] New connection: localId=%{public}u, remoteId=%{public}u",
                                 arg1, arg0);
                    stream = createNewStream(static_cast<int32_t>(arg1),
                                             static_cast<int32_t>(arg0),
                                             static_cast<int32_t>(arg1) > 0);
                }
            }

            if (cmd == AdbProtocol::CMD_WRTE && stream && payloadLen > 0) {
                // *** ZERO-COPY PATH ***
                // Read directly into Stream's RingBuffer
                size_t remaining = payloadLen;
                while (remaining > 0) {
                    auto writeInfo = stream->readBuffer.getWritePtr();
                    if (writeInfo.second == 0) {
                        // Buffer full!
                        // Strategy: Drop? Block?
                        // For video, blocking might cause lag but dropping causes artifacts.
                        // Since we are in a read loop, blocking here STOPS reading other streams (Control/Audio).
                        // Ideally RingBuffer should be large enough (4MB is plenty).
                        OH_LOG_WARN(LOG_APP, "[ADB] Stream %{public}d buffer FULL! Dropping %{public}zu bytes", arg1, remaining);
                        
                        // Drain socket to temp buffer to keep sync
                        size_t toDrop = std::min(remaining, (size_t)4096);
                        if (tempPayload.size() < toDrop) tempPayload.resize(toDrop);
                        channel_->readWithTimeout(tempPayload.data(), toDrop, -1);
                        remaining -= toDrop;
                        continue;
                    }

                    size_t toRead = std::min(remaining, writeInfo.second);
                    channel_->readWithTimeout(writeInfo.first, toRead, -1);
                    stream->readBuffer.commitWrite(toRead);
                    remaining -= toRead;
                }

                // Send OKAY
                auto okayMsg = AdbProtocol::generateOkay(static_cast<int32_t>(arg1), static_cast<int32_t>(arg0));
                writeToChannel(okayMsg);

            } else {
                // *** NORMAL PATH ***
                // Read payload to temp buffer (if any)
                if (payloadLen > 0) {
                     if (tempPayload.size() < payloadLen) tempPayload.resize(payloadLen);
                     channel_->readWithTimeout(tempPayload.data(), payloadLen, -1);
                }
                
                // Process non-WRTE or new-stream messages
                if (!stream && cmd == AdbProtocol::CMD_WRTE) {
                     // Maybe new stream (OPEN? No, Device never sends OPEN usually, it sends WRTE to localId)
                     // If stream not found, we ignore data (already read to temp)
                     // Respond with CLSE?
                     // Verify if it is a new connection request?
                     // Device initiates connection via OPEN?
                     if (arg0 == 0) { // Should check command, but OPEN is 0x4e45504f
                        // Logic for new stream...
                     }
                }

                // Handle other commands
                if (cmd == AdbProtocol::CMD_OKAY) {
                    if (stream) {
                         // stream->canWrite = true; // RingBuffer doesn't use this? 
                         // For Write (Outbound) flow control.
                         // Yes, this is for US sending TO device.
                         stream->canWrite = true; 
                         // We need to notify logic that waits for write?
                         // RingBuffer is for READ.
                         // We need a separate cond var for Write? 
                         // Old AdbStream had `canWrite` bool.
                         // `handleInLoop` notifies `readCv` in old code.
                         // But `readCv` is now in RingBuffer.
                         // RingBuffer CV is for READ availability.
                         // We need `writeCv` for outbound?
                         // Reuse RingBuffer CV? No.
                         // Let's add `writeCv` to AdbStream if needed.
                         // Wait, `streamWrite` does blocking write?
                         // `streamWriteRaw` writes directly to channel. It doesn't wait for OKAY.
                         // Scrcpy protocol ignores OKAY for performance usually?
                         // Actually `Adb.cpp` `streamWrite` does NOT wait for `canWrite`.
                         // So we can ignore OKAY logic or just log it.
                    }
                } else if (cmd == AdbProtocol::CMD_CLSE) {
                    OH_LOG_DEBUG(LOG_APP, "[ADB] Connection closed: localId=%{public}u", arg1);
                    if (stream) {
                        stream->closed = true;
                        stream->readBuffer.close();
                    }
                    // isNeedNotify = true;
                    notifyAll();
                } else if (cmd == AdbProtocol::CMD_WRTE && !stream) {
                     // New connection logic?
                     // In Scrcpy, we connect TO device. Device sends WRTE to OUR id.
                     // If stream not found, maybe it was closed locally.
                     // Send CLSE back?
                }
                
                // Handle New Connection (OPEN from device - rare for Scrcpy but possible for reverse tunnel?)
                // Original code:
                /*
                } else {
                    isNeedNotify = true;
                    stream = createNewStream(...);
                }
                */
               // We need to restore that logic if we want to support reverse connections.
               // Check if arg1 is not in connectionStreams_
               if (!stream && cmd == AdbProtocol::CMD_OPEN) { // 0x4e45504f
                    // ... create stream logic
               }
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
    OH_LOG_INFO(LOG_APP, "[ADB] OPEN sent: localId=%{public}d dest=%{public}s", localId, destination.c_str());

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

    // Check if the stream was closed immediately (Connection Refused)
    {
        // std::lock_guard<std::mutex> lock(stream->readMutex); // usage removed
        if (stream->closed) {
            OH_LOG_ERROR(LOG_APP, "[ADB] Stream opened but subsequently CLOSED (refused?): localId=%{public}d", localId);
            // Cleanup
            {
                std::lock_guard<std::mutex> slock(streamsMutex_);
                auto it = connectionStreams_.find(localId);
                if (it != connectionStreams_.end()) {
                    connectionStreams_.erase(it);
                }
            }
            delete stream;
            throw std::runtime_error("Stream connection refused");
        }
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

std::vector<uint8_t> Adb::streamRead(int32_t streamId, size_t size, int32_t timeoutMs, bool exact) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) stream = it->second;
    }
    if (!stream) throw std::runtime_error("Stream not found");

    std::vector<uint8_t> result(size);
    size_t totalRead = 0;
    
    // RingBuffer handles waiting and copying
    // My RingBuffer implementation: waitForData, copyTo
    
    auto startTime = std::chrono::steady_clock::now();

    while (totalRead < size) {
        size_t needed = size - totalRead;
        
        // Wait for data
        // If timeoutMs < 0, wait indefinitely.
        // If timeoutMs == 0, check immediately (non-blocking).
        // If timeoutMs > 0, wait for given duration.
        bool hasData = stream->readBuffer.waitForData(1, timeoutMs);
        
        if (!hasData) {
             if (stream->readBuffer.isClosed()) {
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream closed");
             }
             if (timeoutMs == 0) { // Non-blocking read returned nothing
                  if (!exact && totalRead > 0) break;
                  // If explicit non-blocking read and no data, we could just return partial/empty result
                  // usually expected to return whatever is available.
                  // But streamRead(..., exact) logic implies we throw if not satisfied?
                  // ArkTS adbStreamRead usually expects partial/empty if not blocking.
                  // Legacy behavior: 
                  /*
                    if (timeoutMs == 0) {
                         if (!exact) break;
                         throw std::runtime_error("Stream read timeout");
                    }
                  */
                  if (!exact) break;
                  throw std::runtime_error("Stream read timeout (no data)");
             }
             if (timeoutMs > 0) { // Specific timeout occurred
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream read timeout");
             }
        }
        
        // Copy available
        size_t n = stream->readBuffer.copyTo(result.data() + totalRead, needed);
        if (n == 0) {
            if (stream->readBuffer.isClosed()) {
                 if (!exact && totalRead > 0) break;
                 throw std::runtime_error("Stream closed");
            }
        }
        
        totalRead += n;
        
        if (!exact && n > 0) break; // Return what we have if not exact
        
        // Timeout check for next iteration
        if (timeoutMs > 0 && totalRead < size) {
            auto now = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - startTime).count();
            if (elapsed >= timeoutMs) {
                 if (!exact) break;
                 throw std::runtime_error("Stream read timeout");
            }
            timeoutMs -= static_cast<int32_t>(elapsed); // rough update
        }
    }

    result.resize(totalRead);
    return result;
}

size_t Adb::streamReadToBuffer(int32_t streamId, uint8_t* dest, size_t destSize, int32_t timeoutMs, bool exact) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) stream = it->second;
    }
    if (!stream) throw std::runtime_error("Stream not found");

    size_t totalRead = 0;
    auto startTime = std::chrono::steady_clock::now();

    while (totalRead < destSize) {
        size_t needed = destSize - totalRead;
        
        bool hasData = stream->readBuffer.waitForData(1, timeoutMs);
        
        if (!hasData) {
             if (stream->readBuffer.isClosed()) {
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream closed");
             }
             if (timeoutMs == 0) {
                  if (!exact) break;
                  throw std::runtime_error("Stream read timeout (no data)");
             }
             if (timeoutMs > 0) {
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream read timeout");
             }
        }
        
        size_t n = stream->readBuffer.copyTo(dest + totalRead, needed);
        if (n == 0) {
            if (stream->readBuffer.isClosed()) {
                 if (!exact && totalRead > 0) break;
                 throw std::runtime_error("Stream closed");
            }
        }
        
        totalRead += n;
        
        if (!exact && n > 0) break; // Return what we have if not exact
        
        if (timeoutMs > 0 && totalRead < destSize) {
            auto now = std::chrono::steady_clock::now();
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - startTime).count();
            if (elapsed >= timeoutMs) {
                 if (!exact) break;
                 throw std::runtime_error("Stream read timeout");
            }
            timeoutMs -= static_cast<int32_t>(elapsed);
        }
    }
    return totalRead;
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

        stream->closed = true;
        stream->readBuffer.close();
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

    std::vector<uint8_t> result(stream->readBuffer.size()); // Approximate size
    size_t actual = stream->readBuffer.copyTo(result.data(), result.size());
    result.resize(actual);
    return result;
}

void Adb::close() {
    bool expected = false;
    if (!isClosed_.compare_exchange_strong(expected, true)) return;

    handleInRunning_.store(false);

    sendRunning_.store(false);
    sendCv_.notify_all();
    if (sendThread_.joinable()) {
        if (std::this_thread::get_id() != sendThread_.get_id()) {
            sendThread_.join();
        } else {
             sendThread_.detach();
        }
    }

    if (channel_) {
        channel_->close();
    }

    notifyAll();

    if (handleInThread_.joinable()) {
        if (std::this_thread::get_id() != handleInThread_.get_id()) {
            handleInThread_.join();
        } else {
             OH_LOG_INFO(LOG_APP, "Adb::close called from handleInLoop, detaching thread");
             handleInThread_.detach();
        }
    }

    // 清理流
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        
        // internal cleanup: notify all streams of closure (already done above, but good for safety)
        
        // openStreams_ contains ALL streams (both active and closed-but-not-deleted)
        // connectionStreams_ is a subset of openStreams_
        // So we only need to iterate openStreams_ to delete everything.
        
        for (auto& pair : openStreams_) {
            delete pair.second;
        }
        openStreams_.clear();
        connectionStreams_.clear();
    }
}

void Adb::writeToChannel(const std::vector<uint8_t>& data) {
    if (isClosed_.load()) return;

    {
        std::lock_guard<std::mutex> lock(sendMutex_);
        if (sendQueue_.size() * data.size() > MAX_SEND_QUEUE_SIZE) { // Rough estimation
             // Or better: sum of sizes. For now, just size check or count check.
             // If we assume avg packet is small, count check is fast.
             // But data payloads can be large.
             // Let's protect against count for now to avoid O(N) size calc.
             if (sendQueue_.size() > 5000) {
                 OH_LOG_WARN(LOG_APP, "[ADB] Send queue full (%{public}zu), dropping packet", sendQueue_.size());
                 return;
             }
        }
        sendQueue_.push(data);
    }
    sendCv_.notify_one();
}

void Adb::sendLoop() {
    OH_LOG_INFO(LOG_APP, "[ADB] Send thread started");
    while (sendRunning_.load()) {
        std::vector<uint8_t> data;
        {
            std::unique_lock<std::mutex> lock(sendMutex_);
            sendCv_.wait(lock, [this] {
                return !sendQueue_.empty() || !sendRunning_.load();
            });

            if (!sendRunning_.load() && sendQueue_.empty()) break;
            
            if (!sendQueue_.empty()) {
                data = std::move(sendQueue_.front());
                sendQueue_.pop();
            }
        }

        if (!data.empty()) {
            try {
                // Blocking Write
                channel_->write(data.data(), data.size());
            } catch (const std::exception& e) {
                OH_LOG_ERROR(LOG_APP, "[ADB] Send error: %{public}s", e.what());
                close();
                break;
            }
        }
    }
    OH_LOG_INFO(LOG_APP, "[ADB] Send thread exited");
}

Adb* Adb::create(int fd) {
    try {
        AdbChannel* channel = new TcpChannel(fd);
        return new Adb(channel);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "Adb::create(fd) failed: %{public}s", e.what());
        return nullptr;
    }
}

Adb* Adb::create(const std::string& ip, int port) {
    try {
        AdbChannel* channel = new TcpChannel(ip, port);
        return new Adb(channel);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "Adb::create(ip, port) failed: %{public}s", e.what());
        return nullptr;
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
    // Only used for legacy or non-optimized writes (e.g. if we read into tempPayload first)
    // We can assume we have the data pointer.
    size_t remaining = len;
    size_t offset = 0;
    while (remaining > 0) {
        auto writeInfo = stream->readBuffer.getWritePtr();
        if (writeInfo.second == 0) {
             // Buffer full. In fallback mode, we might just drop or block?
             // Since this is called from handleInLoop, block = bad.
             // Drop.
             OH_LOG_WARN(LOG_APP, "[ADB] pushToStream dropped %{public}zu bytes (Buffer Full)", remaining);
             break;
        }
        size_t toWrite = std::min(remaining, writeInfo.second);
        std::memcpy(writeInfo.first, data + offset, toWrite);
        stream->readBuffer.commitWrite(toWrite);
        remaining -= toWrite;
        offset += toWrite;
    }
}

void Adb::waitForNotify() {
    std::unique_lock<std::mutex> lock(waitMutex_);
    waitCv_.wait_for(lock, std::chrono::milliseconds(100));
}

void Adb::notifyAll() {
    waitCv_.notify_all();
}
