// ScrcpyStreamManager - C++ 层流管理器实现
// 解析线程只消费本地 tunnel，ADB 只负责后台字节转发
#include "ScrcpyStreamManager.h"

#include "adb/LocalSocketChannel.h"

#include <arpa/inet.h>
#include <chrono>
#include <cerrno>
#include <hilog/log.h>
#include <netinet/in.h>
#include <sstream>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

namespace {
constexpr size_t PROXY_CHUNK_SIZE = 64 * 1024;
constexpr size_t CONTROL_MSG_QUEUE_MAX = 64;
constexpr uint8_t CONTROL_MSG_TYPE_TOUCH_EVENT = 2;
constexpr uint8_t CONTROL_TOUCH_ACTION_MOVE = 2;

void writeAllFd(int fd, const uint8_t* data, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = ::send(fd, data + offset, len - offset, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            throw std::runtime_error("Local tunnel write failed");
        }
        offset += static_cast<size_t>(n);
    }
}

void joinThread(std::thread& thread) {
    if (!thread.joinable()) {
        return;
    }
    if (thread.get_id() == std::this_thread::get_id()) {
        thread.detach();
        return;
    }
    thread.join();
}
}

// ===================== 辅助函数 =====================

int32_t ScrcpyStreamManager::readInt32BE(const uint8_t* data) {
    return (static_cast<int32_t>(data[0]) << 24) |
           (static_cast<int32_t>(data[1]) << 16) |
           (static_cast<int32_t>(data[2]) << 8) |
           (static_cast<int32_t>(data[3]));
}

int64_t ScrcpyStreamManager::readInt64BE(const uint8_t* data) {
    return (static_cast<int64_t>(data[0]) << 56) |
           (static_cast<int64_t>(data[1]) << 48) |
           (static_cast<int64_t>(data[2]) << 40) |
           (static_cast<int64_t>(data[3]) << 32) |
           (static_cast<int64_t>(data[4]) << 24) |
           (static_cast<int64_t>(data[5]) << 16) |
           (static_cast<int64_t>(data[6]) << 8) |
           (static_cast<int64_t>(data[7]));
}

std::vector<uint8_t> ScrcpyStreamManager::readExact(AdbChannel* channel, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !channel) {
        throw std::runtime_error("Stream manager not running");
    }
    std::vector<uint8_t> data(size);
    readExactToBuffer(channel, data.data(), size, timeoutMs);
    return data;
}

void ScrcpyStreamManager::readExactToBuffer(AdbChannel* channel, uint8_t* dest, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !channel || !dest) {
        throw std::runtime_error("Stream manager not running");
    }
    channel->readWithTimeout(dest, size, timeoutMs);
}

std::vector<uint8_t> ScrcpyStreamManager::readExact(AdbStream* stream, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !adb_ || !stream) {
        throw std::runtime_error("Stream manager not running");
    }
    std::vector<uint8_t> data(size);
    readExactToBuffer(stream, data.data(), size, timeoutMs);
    return data;
}

void ScrcpyStreamManager::readExactToBuffer(AdbStream* stream, uint8_t* dest, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !adb_ || !stream || !dest) {
        throw std::runtime_error("Stream manager not running");
    }
    size_t readSize = adb_->streamReadToBuffer(stream, dest, size, timeoutMs, true);
    if (readSize < size) {
        throw std::runtime_error("Stream closed or read incomplete");
    }
}

int32_t ScrcpyStreamManager::createLocalTunnel(AdbChannel*& channel, int& proxyFd) {
    int fds[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] socketpair failed errno=%{public}d", errno);
        return -1;
    }

    try {
        channel = new LocalSocketChannel(fds[0]);
    } catch (...) {
        ::close(fds[0]);
        ::close(fds[1]);
        throw;
    }

    proxyFd = fds[1];
    return 0;
}

void ScrcpyStreamManager::closeFd(int& fd) {
    if (fd < 0) {
        return;
    }
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
    fd = -1;
}

namespace {
void closeLockedFd(int& fd, std::mutex& mutex) {
    std::lock_guard<std::mutex> lock(mutex);
    if (fd < 0) {
        return;
    }
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
    fd = -1;
}

int getLockedFd(int& fd, std::mutex& mutex) {
    std::lock_guard<std::mutex> lock(mutex);
    return fd;
}

bool isDroppableControlPacket(const uint8_t* data, size_t len) {
    return len >= 2 &&
           data[0] == CONTROL_MSG_TYPE_TOUCH_EVENT &&
           data[1] == CONTROL_TOUCH_ACTION_MOVE;
}

bool isDroppableControlPacket(const std::vector<uint8_t>& packet) {
    return isDroppableControlPacket(packet.data(), packet.size());
}

bool dropQueuedMovePacket(std::deque<std::vector<uint8_t>>& queue) {
    for (auto it = queue.end(); it != queue.begin();) {
        --it;
        if (isDroppableControlPacket(*it)) {
            queue.erase(it);
            return true;
        }
    }
    return false;
}
}

void ScrcpyStreamManager::closeLocalTunnels() {
    if (videoChannel_) {
        videoChannel_->close();
    }
    if (audioChannel_) {
        audioChannel_->close();
    }
    if (controlChannel_) {
        controlChannel_->close();
    }

    closeFd(videoProxyFd_);
    closeFd(audioProxyFd_);
    closeLockedFd(controlProxyFd_, controlProxyFdMutex_);
}

void ScrcpyStreamManager::releaseLocalTunnels() {
    if (videoChannel_) {
        delete videoChannel_;
        videoChannel_ = nullptr;
    }
    if (audioChannel_) {
        delete audioChannel_;
        audioChannel_ = nullptr;
    }
    if (controlChannel_) {
        delete controlChannel_;
        controlChannel_ = nullptr;
    }
}

void ScrcpyStreamManager::closeListener() {
    closeFd(listenFd_);
}

void ScrcpyStreamManager::emitEvent(const std::string& type, const std::string& data) {
    std::lock_guard<std::mutex> lock(eventMutex_);
    if (eventCallback_) {
        eventCallback_(type, data);
    }
}

// ===================== 构造/析构 =====================

ScrcpyStreamManager::ScrcpyStreamManager() {}

ScrcpyStreamManager::~ScrcpyStreamManager() {
    stop();
}

// ===================== start =====================

int32_t ScrcpyStreamManager::start(Adb* adb, const Config& config, StreamEventCallback callback) {
    if (running_.load()) {
        OH_LOG_WARN(LOG_APP, "[StreamManager] Already running, stop first");
        stop();
    }

    adb_ = adb;
    config_ = config;
    eventCallback_ = callback;
    videoStream_ = (config_.videoStreamId >= 0 && adb_) ? adb_->getStreamHandle(config_.videoStreamId) : nullptr;
    audioStream_ = (config_.audioStreamId >= 0 && adb_) ? adb_->getStreamHandle(config_.audioStreamId) : nullptr;
    controlStream_ = (config_.controlStreamId >= 0 && adb_) ? adb_->getStreamHandle(config_.controlStreamId) : nullptr;

    if (config_.videoStreamId >= 0 && !videoStream_) return -3;
    if (config_.audioStreamId >= 0 && !audioStream_) return -4;
    if (config_.controlStreamId >= 0 && !controlStream_) return -5;

    try {
        if (videoStream_ && createLocalTunnel(videoChannel_, videoProxyFd_) != 0) {
            closeLocalTunnels();
            releaseLocalTunnels();
            return -6;
        }
        if (audioStream_ && createLocalTunnel(audioChannel_, audioProxyFd_) != 0) {
            closeLocalTunnels();
            releaseLocalTunnels();
            return -7;
        }
        if (controlStream_ && createLocalTunnel(controlChannel_, controlProxyFd_) != 0) {
            closeLocalTunnels();
            releaseLocalTunnels();
            return -8;
        }
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] Create tunnel failed: %{public}s", e.what());
        closeLocalTunnels();
        releaseLocalTunnels();
        videoStream_ = nullptr;
        audioStream_ = nullptr;
        controlStream_ = nullptr;
        adb_ = nullptr;
        return -9;
    }

    running_.store(true);
    {
        std::lock_guard<std::mutex> lock(controlSendQueueMutex_);
        controlSendQueue_.clear();
    }

    OH_LOG_INFO(LOG_APP,
                "[StreamManager] Starting with video=%{public}d, audio=%{public}d, control=%{public}d",
                config_.videoStreamId, config_.audioStreamId, config_.controlStreamId);

    if (videoStream_) {
        videoProxyThread_ = std::thread(&ScrcpyStreamManager::videoProxyThreadFunc, this);
        videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
    }

    if (audioStream_) {
        audioProxyThread_ = std::thread(&ScrcpyStreamManager::audioProxyThreadFunc, this);
        audioThread_ = std::thread(&ScrcpyStreamManager::audioThreadFunc, this);
    }

    if (controlStream_) {
        controlProxyToAdbThread_ = std::thread(&ScrcpyStreamManager::controlProxyToAdbThreadFunc, this);
        controlAdbToProxyThread_ = std::thread(&ScrcpyStreamManager::controlAdbToProxyThreadFunc, this);
        controlThread_ = std::thread(&ScrcpyStreamManager::controlThreadFunc, this);
        controlSendThread_ = std::thread(&ScrcpyStreamManager::controlSendThreadFunc, this);
    }

    return 0;
}

int32_t ScrcpyStreamManager::createTcpListener(uint16_t& port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] create listener socket failed errno=%{public}d", errno);
        return -1;
    }

    int reuseAddr = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));

    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);

    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] bind listener failed errno=%{public}d", errno);
        ::close(fd);
        return -2;
    }

    if (listen(fd, 4) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] listen failed errno=%{public}d", errno);
        ::close(fd);
        return -3;
    }

    sockaddr_in localAddr {};
    socklen_t localAddrLen = sizeof(localAddr);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&localAddr), &localAddrLen) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] getsockname failed errno=%{public}d", errno);
        ::close(fd);
        return -4;
    }

    listenFd_ = fd;
    port = ntohs(localAddr.sin_port);
    return 0;
}

int32_t ScrcpyStreamManager::startReverse(Adb* adb, const Config& config, StreamEventCallback callback) {
    if (running_.load()) {
        OH_LOG_WARN(LOG_APP, "[StreamManager] Already running, stop first");
        stop();
    }

    adb_ = adb;
    config_ = config;
    eventCallback_ = callback;
    videoStream_ = nullptr;
    audioStream_ = nullptr;
    controlStream_ = nullptr;

    uint16_t port = 0;
    int32_t listenerRet = createTcpListener(port);
    if (listenerRet != 0) {
        closeLocalTunnels();
        closeListener();
        adb_ = nullptr;
        return listenerRet;
    }

    running_.store(true);
    {
        std::lock_guard<std::mutex> lock(controlSendQueueMutex_);
        controlSendQueue_.clear();
    }
    acceptThread_ = std::thread(&ScrcpyStreamManager::acceptThreadFunc, this);

    OH_LOG_INFO(LOG_APP,
                "[StreamManager] Reverse listener started on port=%{public}u, video=%{public}d, audio=%{public}d, control=%{public}d",
                port, config_.expectVideo, config_.expectAudio, config_.expectControl);
    return static_cast<int32_t>(port);
}

// ===================== stop =====================

void ScrcpyStreamManager::stop() {
    bool wasRunning = running_.exchange(false);
    if (!wasRunning && !videoThread_.joinable() && !audioThread_.joinable() &&
        !controlThread_.joinable() && !controlSendThread_.joinable() &&
        !controlProxyToAdbThread_.joinable() && !controlAdbToProxyThread_.joinable() &&
        !videoProxyThread_.joinable() && !audioProxyThread_.joinable() && !acceptThread_.joinable()) {
        return;
    }

    OH_LOG_INFO(LOG_APP, "[StreamManager] Stopping...");

    controlSendQueueCv_.notify_all();

    closeLocalTunnels();
    closeListener();

    if (adb_) {
        if (config_.videoStreamId >= 0) {
            adb_->streamClose(config_.videoStreamId);
        }
        if (config_.audioStreamId >= 0) {
            adb_->streamClose(config_.audioStreamId);
        }
        if (config_.controlStreamId >= 0) {
            adb_->streamClose(config_.controlStreamId);
        }
    }

    joinThread(videoThread_);
    joinThread(audioThread_);
    joinThread(controlThread_);
    joinThread(controlSendThread_);
    joinThread(controlProxyToAdbThread_);
    joinThread(controlAdbToProxyThread_);
    joinThread(videoProxyThread_);
    joinThread(audioProxyThread_);
    joinThread(acceptThread_);
    {
        std::lock_guard<std::mutex> lock(controlSendQueueMutex_);
        controlSendQueue_.clear();
    }
    releaseLocalTunnels();

    if (videoDecoder_) {
        videoDecoder_->Release();
        delete videoDecoder_;
        videoDecoder_ = nullptr;
    }
    if (audioDecoder_) {
        audioDecoder_->Release();
        delete audioDecoder_;
        audioDecoder_ = nullptr;
    }

    videoStream_ = nullptr;
    audioStream_ = nullptr;
    controlStream_ = nullptr;
    adb_ = nullptr;
    OH_LOG_INFO(LOG_APP, "[StreamManager] Stopped");
}

// ===================== sendControl =====================

void ScrcpyStreamManager::sendControl(const uint8_t* data, size_t len) {
    if (!running_.load() || len == 0) {
        return;
    }

    const bool droppable = isDroppableControlPacket(data, len);
    std::vector<uint8_t> packet(data, data + len);

    std::unique_lock<std::mutex> lock(controlSendQueueMutex_);
    while (running_.load() && controlSendQueue_.size() >= CONTROL_MSG_QUEUE_MAX) {
        if (droppable) {
            OH_LOG_WARN(LOG_APP, "[StreamManager] Control queue full, dropping move packet");
            return;
        }

        if (dropQueuedMovePacket(controlSendQueue_)) {
            break;
        }

        controlSendQueueCv_.wait_for(lock, std::chrono::milliseconds(20), [this]() {
            return !running_.load() || controlSendQueue_.size() < CONTROL_MSG_QUEUE_MAX;
        });
    }

    if (!running_.load()) {
        return;
    }

    controlSendQueue_.push_back(std::move(packet));
    lock.unlock();
    controlSendQueueCv_.notify_one();
}

void ScrcpyStreamManager::controlSendThreadFunc() {
    while (true) {
        std::vector<uint8_t> packet;
        {
            std::unique_lock<std::mutex> lock(controlSendQueueMutex_);
            controlSendQueueCv_.wait(lock, [this]() {
                return !controlSendQueue_.empty() || !running_.load();
            });
            if (controlSendQueue_.empty()) {
                if (!running_.load()) {
                    break;
                }
                continue;
            }
            packet = std::move(controlSendQueue_.front());
            controlSendQueue_.pop_front();
        }
        controlSendQueueCv_.notify_all();

        try {
            if (controlChannel_) {
                controlChannel_->write(packet.data(), packet.size());
            } else if (!running_.load()) {
                break;
            }
        } catch (const std::exception& e) {
            if (running_.load()) {
                OH_LOG_ERROR(LOG_APP, "[StreamManager] control send error: %{public}s", e.what());
            }
        }
    }
}

void ScrcpyStreamManager::acceptThreadFunc() {
    try {
        auto acceptChannel = [this]() -> AdbChannel* {
            int fd = ::accept(listenFd_, nullptr, nullptr);
            if (fd < 0) {
                throw std::runtime_error("accept failed");
            }
            return new LocalSocketChannel(fd);
        };

        if (config_.expectVideo) {
            videoChannel_ = acceptChannel();
            videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
        }
        if (config_.expectAudio) {
            audioChannel_ = acceptChannel();
            audioThread_ = std::thread(&ScrcpyStreamManager::audioThreadFunc, this);
        }
        if (config_.expectControl) {
            controlChannel_ = acceptChannel();
            controlThread_ = std::thread(&ScrcpyStreamManager::controlThreadFunc, this);
            controlSendThread_ = std::thread(&ScrcpyStreamManager::controlSendThreadFunc, this);
        }
        emitEvent("reverse_ready", "");
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[StreamManager] Reverse accept failed: %{public}s", e.what());
            emitEvent("error", std::string("Reverse accept failed: ") + e.what());
        }
    }
}

// ===================== Proxy Threads =====================

void ScrcpyStreamManager::videoProxyThreadFunc() {
    std::vector<uint8_t> buffer(PROXY_CHUNK_SIZE);

    try {
        while (running_.load() && adb_ && videoStream_ && videoProxyFd_ >= 0) {
            size_t n = adb_->streamReadToBuffer(videoStream_, buffer.data(), buffer.size(), -1, false);
            if (n == 0) {
                continue;
            }
            writeAllFd(videoProxyFd_, buffer.data(), n);
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_WARN(LOG_APP, "[VideoProxy] Exit with error: %{public}s", e.what());
        }
    }

    closeFd(videoProxyFd_);
}

void ScrcpyStreamManager::audioProxyThreadFunc() {
    std::vector<uint8_t> buffer(PROXY_CHUNK_SIZE);

    try {
        while (running_.load() && adb_ && audioStream_ && audioProxyFd_ >= 0) {
            size_t n = adb_->streamReadToBuffer(audioStream_, buffer.data(), buffer.size(), -1, false);
            if (n == 0) {
                continue;
            }
            writeAllFd(audioProxyFd_, buffer.data(), n);
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_WARN(LOG_APP, "[AudioProxy] Exit with error: %{public}s", e.what());
        }
    }

    closeFd(audioProxyFd_);
}

void ScrcpyStreamManager::controlProxyToAdbThreadFunc() {
    std::vector<uint8_t> buffer(PROXY_CHUNK_SIZE);

    try {
        while (running_.load() && adb_ && controlStream_) {
            int proxyFd = getLockedFd(controlProxyFd_, controlProxyFdMutex_);
            if (proxyFd < 0) {
                break;
            }

            ssize_t n = ::recv(proxyFd, buffer.data(), buffer.size(), 0);
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                break;
            }

            adb_->streamWrite(controlStream_, buffer.data(), static_cast<size_t>(n));
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_WARN(LOG_APP, "[ControlProxy->ADB] Exit with error: %{public}s", e.what());
        }
    }
}

void ScrcpyStreamManager::controlAdbToProxyThreadFunc() {
    std::vector<uint8_t> buffer(PROXY_CHUNK_SIZE);

    try {
        while (running_.load() && adb_ && controlStream_) {
            int proxyFd = getLockedFd(controlProxyFd_, controlProxyFdMutex_);
            if (proxyFd < 0) {
                break;
            }

            size_t n = adb_->streamReadToBuffer(controlStream_, buffer.data(), buffer.size(), -1, false);
            if (n == 0) {
                continue;
            }
            writeAllFd(proxyFd, buffer.data(), n);
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_WARN(LOG_APP, "[ControlADB->Proxy] Exit with error: %{public}s", e.what());
        }
    }

    closeLockedFd(controlProxyFd_, controlProxyFdMutex_);
}

// ===================== Video Thread =====================

void ScrcpyStreamManager::videoThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[VideoThread] Started");

    try {
        AdbChannel* channel = videoChannel_;
        if (!channel) throw std::runtime_error("video channel not found");

        if (config_.sendDummyByte) {
            auto dummy = readExact(channel, 1, 2000);
            (void) dummy;
            OH_LOG_DEBUG(LOG_APP, "[VideoThread] Dummy byte read");
        }

        auto deviceNameData = readExact(channel, 64, 2000);
        std::string deviceName(reinterpret_cast<char*>(deviceNameData.data()), 64);
        deviceName = deviceName.c_str();
        OH_LOG_INFO(LOG_APP, "[VideoThread] Device: %{public}s", deviceName.c_str());

        auto codecMeta = readExact(channel, 12, 2000);
        int32_t codecId = readInt32BE(codecMeta.data());
        int32_t width = readInt32BE(codecMeta.data() + 4);
        int32_t height = readInt32BE(codecMeta.data() + 8);

        OH_LOG_INFO(LOG_APP, "[VideoThread] Codec=%{public}d, Size=%{public}dx%{public}d",
                    codecId, width, height);

        std::string codecType = "h264";
        if (codecId == 1 || codecId == 1748121141) codecType = "h265";
        if (codecId == 2 || codecId == 1635135537) codecType = "av1";

        {
            std::ostringstream oss;
            oss << "{\"codecId\":" << codecId
                << ",\"width\":" << width
                << ",\"height\":" << height
                << ",\"codecType\":\"" << codecType << "\""
                << ",\"deviceName\":\"" << deviceName << "\"}";
            emitEvent("video_config", oss.str());
        }

        videoDecoder_ = new VideoDecoderNative();
        videoDecoder_->SetSizeChangeCallback([this, codecId, codecType, deviceName](int32_t w, int32_t h) {
            std::ostringstream oss;
            oss << "{\"codecId\":" << codecId
                << ",\"width\":" << w
                << ",\"height\":" << h
                << ",\"codecType\":\"" << codecType << "\""
                << ",\"deviceName\":\"" << deviceName << "\"}";
            this->emitEvent("video_size_changed", oss.str());
        });

        int32_t initRet = videoDecoder_->Init(codecType.c_str(), config_.surfaceId.c_str(), width, height);
        if (initRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Decoder init failed: %{public}d", initRet);
            emitEvent("error", "Video decoder init failed");
            return;
        }

        int32_t startRet = videoDecoder_->Start();
        if (startRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Decoder start failed: %{public}d", startRet);
            emitEvent("error", "Video decoder start failed");
            return;
        }

        OH_LOG_INFO(LOG_APP, "[VideoThread] Decoder started, entering frame loop");

        uint32_t frameCount = 0;
        bool firstFrameNotified = false;
        uint8_t headerBuf[8];
        std::vector<uint8_t> dropBuffer;

        while (running_.load()) {
            readExactToBuffer(channel, headerBuf, 8);
            int64_t ptsRaw = readInt64BE(headerBuf);

            const int64_t PACKET_FLAG_CONFIG = 1LL << 63;
            bool isConfig = (ptsRaw & PACKET_FLAG_CONFIG) != 0;
            int64_t cleanPts = ptsRaw & ~PACKET_FLAG_CONFIG;

            uint32_t flags = 0;
            if (isConfig) {
                OH_LOG_INFO(LOG_APP, "[VideoThread] Config packet (SPS/PPS)");
                flags = 8;
            }

            readExactToBuffer(channel, headerBuf, 4);
            int32_t frameSize = readInt32BE(headerBuf);

            if (frameSize <= 0 || frameSize > 20 * 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;

            int32_t getBufRet = -1;
            while (running_.load()) {
                getBufRet = videoDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0) break;
                if (getBufRet != -2) {
                    OH_LOG_ERROR(LOG_APP, "[VideoThread] GetInputBuffer failed: %{public}d", getBufRet);
                    break;
                }
            }

            if (getBufRet != 0) break;

            if (bufCapacity < frameSize) {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Buffer too small: %{public}d < %{public}d", bufCapacity, frameSize);
                if (dropBuffer.size() < static_cast<size_t>(frameSize)) {
                    dropBuffer.resize(static_cast<size_t>(frameSize));
                }
                readExactToBuffer(channel, dropBuffer.data(), frameSize);
                videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                continue;
            }

            try {
                readExactToBuffer(channel, bufData, frameSize);
            } catch (...) {
                videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                throw;
            }

            int32_t submitRet = videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, cleanPts, frameSize, flags);
            if (submitRet == 0) {
                frameCount++;
                if (!firstFrameNotified) {
                    firstFrameNotified = true;
                    OH_LOG_INFO(LOG_APP, "[VideoThread] First frame decoded");
                    emitEvent("first_frame", "");
                }
            } else {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Submit failed: %{public}d", submitRet);
            }
        }

        OH_LOG_INFO(LOG_APP, "[VideoThread] Exiting, total frames: %{public}u", frameCount);
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Video thread error: ") + e.what());
        } else {
            OH_LOG_INFO(LOG_APP, "[VideoThread] Exiting (stopped)");
        }
    }

    if (running_.load()) {
        emitEvent("disconnected", "video");
    }
}

// ===================== Audio Thread =====================

void ScrcpyStreamManager::audioThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[AudioThread] Started");

    try {
        AdbChannel* channel = audioChannel_;
        if (!channel) throw std::runtime_error("audio channel not found");

        uint8_t codecBytes[4];
        readExactToBuffer(channel, codecBytes, 4, 2000);
        int32_t codecId = readInt32BE(codecBytes);

        OH_LOG_INFO(LOG_APP, "[AudioThread] Audio codec ID: 0x%{public}x", codecId);

        if (codecId == 0) {
            OH_LOG_INFO(LOG_APP, "[AudioThread] Audio disabled by server");
            emitEvent("audio_disabled", "");
            return;
        }
        if (codecId == 1) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Audio config error from server");
            return;
        }

        std::string codecName;
        switch (codecId) {
            case 0x6F707573: codecName = "opus"; break;
            case 0x00616163: codecName = "aac"; break;
            case 0x666C6163: codecName = "flac"; break;
            case 0x00726177: codecName = "raw"; break;
            default:
                OH_LOG_WARN(LOG_APP, "[AudioThread] Unknown codec 0x%{public}x, fallback to opus", codecId);
                codecName = "opus";
                break;
        }

        OH_LOG_INFO(LOG_APP, "[AudioThread] Using codec: %{public}s", codecName.c_str());

        audioDecoder_ = new AudioDecoderNative();
        int32_t initRet = audioDecoder_->Init(codecName.c_str(), config_.audioSampleRate, config_.audioChannelCount);
        if (initRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Decoder init failed: %{public}d", initRet);
            emitEvent("error", "Audio decoder init failed");
            return;
        }

        int32_t startRet = audioDecoder_->Start();
        if (startRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Decoder start failed: %{public}d", startRet);
            emitEvent("error", "Audio decoder start failed");
            return;
        }

        OH_LOG_INFO(LOG_APP, "[AudioThread] Decoder started, entering frame loop");

        const int64_t PACKET_FLAG_CONFIG = 1LL << 63;
        const int64_t PACKET_FLAG_KEY_FRAME = 1LL << 62;
        const int64_t PTS_MASK = PACKET_FLAG_KEY_FRAME - 1;

        uint8_t ptsData[8];
        uint8_t sizeData[4];
        std::vector<uint8_t> dropBuffer;
        while (running_.load()) {
            readExactToBuffer(channel, ptsData, 8);
            int64_t ptsRaw = readInt64BE(ptsData);

            bool isConfig = (ptsRaw & PACKET_FLAG_CONFIG) != 0;
            int64_t cleanPts = ptsRaw & PTS_MASK;

            readExactToBuffer(channel, sizeData, 4);
            int32_t frameSize = readInt32BE(sizeData);

            if (frameSize <= 0 || frameSize > 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[AudioThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;

            int32_t getBufRet = -1;
            while (running_.load()) {
                getBufRet = audioDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0) break;
                if (getBufRet == -2) {
                    continue;
                }
                OH_LOG_ERROR(LOG_APP, "[AudioThread] GetInputBuffer failed: %{public}d", getBufRet);
                break;
            }

            if (getBufRet != 0) break;

            if (bufCapacity < frameSize) {
                OH_LOG_ERROR(LOG_APP, "[AudioThread] Buffer too small: %{public}d < %{public}d", bufCapacity, frameSize);
                if (dropBuffer.size() < static_cast<size_t>(frameSize)) {
                    dropBuffer.resize(static_cast<size_t>(frameSize));
                }
                readExactToBuffer(channel, dropBuffer.data(), frameSize);
                audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                continue;
            }

            try {
                readExactToBuffer(channel, bufData, frameSize);
            } catch (...) {
                audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                throw;
            }

            if (isConfig) {
                OH_LOG_INFO(LOG_APP, "[AudioThread] Config packet: %{public}d bytes", frameSize);
            }

            int32_t submitRet = audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, cleanPts, frameSize, 0);
            if (submitRet != 0) {
                OH_LOG_WARN(LOG_APP, "[AudioThread] Submit failed: %{public}d", submitRet);
            }
        }

        OH_LOG_INFO(LOG_APP, "[AudioThread] Exiting");
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Audio thread error: ") + e.what());
        } else {
            OH_LOG_INFO(LOG_APP, "[AudioThread] Exiting (stopped)");
        }
    }
}

// ===================== Control Thread =====================

void ScrcpyStreamManager::controlThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[ControlThread] Started");

    try {
        AdbStream* stream = controlStream_;
        AdbChannel* channel = controlChannel_;
        if (!stream && !channel) throw std::runtime_error("control stream not found");

        uint8_t typeByte[1];
        uint8_t lenData[4];
        uint8_t ackData[8];
        uint8_t uhidHeader[4];
        while (running_.load()) {
            size_t n = 0;
            if (channel) {
                readExactToBuffer(channel, typeByte, 1);
                n = 1;
            } else {
                n = adb_->streamReadToBuffer(stream, typeByte, 1, -1, true);
                if (n < 1) {
                    break;
                }
            }
            uint8_t eventType = typeByte[0];

            if (!running_.load()) break;

            switch (eventType) {
                case 0: {
                    if (channel) {
                        readExactToBuffer(channel, lenData, 4);
                    } else {
                        readExactToBuffer(stream, lenData, 4);
                    }
                    int32_t clipLen = readInt32BE(lenData);
                    if (clipLen > 0 && clipLen <= 100000) {
                        auto clipTextData = channel ? readExact(channel, clipLen) : readExact(stream, clipLen);
                        std::string text(reinterpret_cast<char*>(clipTextData.data()), clipTextData.size());
                        OH_LOG_DEBUG(LOG_APP, "[ControlThread] Clipboard received: %{public}zu bytes", text.size());
                        emitEvent("clipboard", text);
                    }
                    break;
                }
                case 1: {
                    if (channel) {
                        readExactToBuffer(channel, ackData, sizeof(ackData));
                    } else {
                        readExactToBuffer(stream, ackData, sizeof(ackData));
                    }
                    break;
                }
                case 2: {
                    if (channel) {
                        readExactToBuffer(channel, uhidHeader, sizeof(uhidHeader));
                    } else {
                        readExactToBuffer(stream, uhidHeader, sizeof(uhidHeader));
                    }
                    int32_t size = (static_cast<int32_t>(uhidHeader[2]) << 8) |
                                   static_cast<int32_t>(uhidHeader[3]);
                    if (size > 0) {
                        if (channel) {
                            readExact(channel, size);
                        } else {
                            readExact(stream, size);
                        }
                    }
                    break;
                }
                default:
                    OH_LOG_DEBUG(LOG_APP, "[ControlThread] Unknown event type: %{public}d", eventType);
                    break;
            }
        }

        OH_LOG_INFO(LOG_APP, "[ControlThread] Exiting");
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[ControlThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Control thread error: ") + e.what());
        } else {
            OH_LOG_INFO(LOG_APP, "[ControlThread] Exiting (stopped)");
        }
    }
}
