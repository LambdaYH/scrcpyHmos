// ScrcpyStreamManager - C++ 层流管理器实现
// 媒体流拆分为“收流线程 + 解码线程”，降低 socket 抖动对解码节奏的直接影响
#include "ScrcpyStreamManager.h"

#include "adb/LocalSocketChannel.h"

#include <arpa/inet.h>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstring>
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
constexpr size_t CONTROL_MSG_QUEUE_MAX = 128;
constexpr size_t VIDEO_PACKET_POOL_SIZE = 6;
constexpr size_t AUDIO_PACKET_POOL_SIZE = 32;
constexpr uint32_t PACKET_FLAG_CONFIG = 1u << 3;
constexpr int64_t SCRCPY_PACKET_FLAG_CONFIG = 1LL << 63;
constexpr int64_t SCRCPY_PACKET_FLAG_KEY_FRAME = 1LL << 62;
constexpr int64_t SCRCPY_PACKET_PTS_MASK = SCRCPY_PACKET_FLAG_KEY_FRAME - 1;

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

void ScrcpyStreamManager::closeFd(int& fd) {
    if (fd < 0) {
        return;
    }
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
    fd = -1;
}

namespace {
void drainReliableQueue(moodycamel::BlockingConcurrentQueue<std::vector<uint8_t>>& queue) {
    std::vector<uint8_t> packet;
    while (queue.try_dequeue(packet)) {
    }
}

}

void ScrcpyStreamManager::initPacketPools() {
    resetPacketPools();

    videoPacketStorage_.reserve(VIDEO_PACKET_POOL_SIZE);
    for (size_t i = 0; i < VIDEO_PACKET_POOL_SIZE; ++i) {
        auto packet = std::make_unique<EncodedVideoPacket>();
        freeVideoPackets_.push_back(packet.get());
        videoPacketStorage_.push_back(std::move(packet));
    }

    audioPacketStorage_.reserve(AUDIO_PACKET_POOL_SIZE);
    for (size_t i = 0; i < AUDIO_PACKET_POOL_SIZE; ++i) {
        auto packet = std::make_unique<EncodedAudioPacket>();
        freeAudioPackets_.push_back(packet.get());
        audioPacketStorage_.push_back(std::move(packet));
    }
}

void ScrcpyStreamManager::resetPacketPools() {
    {
        std::lock_guard<std::mutex> lock(videoPacketMutex_);
        videoPacketQueue_.clear();
        freeVideoPackets_.clear();
        videoPacketStorage_.clear();
        latestVideoConfig_.clear();
        latestVideoConfigFlags_ = 0;
        latestVideoConfigSerial_ = 0;
        droppedVideoPackets_ = 0;
    }
    {
        std::lock_guard<std::mutex> lock(audioPacketMutex_);
        audioPacketQueue_.clear();
        freeAudioPackets_.clear();
        audioPacketStorage_.clear();
        latestAudioConfig_.clear();
        latestAudioConfigFlags_ = 0;
        latestAudioConfigSerial_ = 0;
        droppedAudioPackets_ = 0;
    }
    videoPacketCv_.notify_all();
    audioPacketCv_.notify_all();
}

EncodedVideoPacket* ScrcpyStreamManager::acquireVideoPacket() {
    std::lock_guard<std::mutex> lock(videoPacketMutex_);
    if (!freeVideoPackets_.empty()) {
        EncodedVideoPacket* packet = freeVideoPackets_.front();
        freeVideoPackets_.pop_front();
        return packet;
    }

    auto dropIt = std::find_if(videoPacketQueue_.begin(), videoPacketQueue_.end(),
                               [](const EncodedVideoPacket* packet) { return !packet->isKeyFrame; });
    if (dropIt == videoPacketQueue_.end() && !videoPacketQueue_.empty()) {
        dropIt = videoPacketQueue_.begin();
    }

    if (dropIt != videoPacketQueue_.end()) {
        EncodedVideoPacket* packet = *dropIt;
        videoPacketQueue_.erase(dropIt);
        ++droppedVideoPackets_;
        return packet;
    }

    return nullptr;
}

void ScrcpyStreamManager::enqueueVideoPacket(EncodedVideoPacket* packet) {
    if (!packet) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(videoPacketMutex_);
        videoPacketQueue_.push_back(packet);
    }
    videoPacketCv_.notify_one();
}

bool ScrcpyStreamManager::waitDequeueVideoPacket(EncodedVideoPacket*& packet) {
    std::unique_lock<std::mutex> lock(videoPacketMutex_);
    videoPacketCv_.wait(lock, [this]() {
        return !videoPacketQueue_.empty() || !running_.load() || videoReaderDone_.load();
    });
    if (videoPacketQueue_.empty()) {
        return false;
    }
    packet = videoPacketQueue_.front();
    videoPacketQueue_.pop_front();
    return true;
}

void ScrcpyStreamManager::recycleVideoPacket(EncodedVideoPacket* packet) {
    if (!packet) {
        return;
    }
    packet->pts = 0;
    packet->submitFlags = 0;
    packet->isKeyFrame = false;
    {
        std::lock_guard<std::mutex> lock(videoPacketMutex_);
        freeVideoPackets_.push_back(packet);
    }
}

void ScrcpyStreamManager::cacheVideoConfig(const uint8_t* data, size_t len, uint32_t flags) {
    std::lock_guard<std::mutex> lock(videoPacketMutex_);
    latestVideoConfig_.assign(data, data + len);
    latestVideoConfigFlags_ = flags;
    ++latestVideoConfigSerial_;
}

bool ScrcpyStreamManager::copyPendingVideoConfig(std::vector<uint8_t>& out, uint32_t& flags,
                                                 uint64_t& serial, uint64_t lastSerial) {
    std::lock_guard<std::mutex> lock(videoPacketMutex_);
    if (latestVideoConfigSerial_ == 0 || latestVideoConfigSerial_ == lastSerial || latestVideoConfig_.empty()) {
        return false;
    }
    out = latestVideoConfig_;
    flags = latestVideoConfigFlags_;
    serial = latestVideoConfigSerial_;
    return true;
}

EncodedAudioPacket* ScrcpyStreamManager::acquireAudioPacket() {
    std::lock_guard<std::mutex> lock(audioPacketMutex_);
    if (!freeAudioPackets_.empty()) {
        EncodedAudioPacket* packet = freeAudioPackets_.front();
        freeAudioPackets_.pop_front();
        return packet;
    }
    if (!audioPacketQueue_.empty()) {
        EncodedAudioPacket* packet = audioPacketQueue_.front();
        audioPacketQueue_.pop_front();
        ++droppedAudioPackets_;
        return packet;
    }
    return nullptr;
}

void ScrcpyStreamManager::enqueueAudioPacket(EncodedAudioPacket* packet) {
    if (!packet) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(audioPacketMutex_);
        audioPacketQueue_.push_back(packet);
    }
    audioPacketCv_.notify_one();
}

bool ScrcpyStreamManager::waitDequeueAudioPacket(EncodedAudioPacket*& packet) {
    std::unique_lock<std::mutex> lock(audioPacketMutex_);
    audioPacketCv_.wait(lock, [this]() {
        return !audioPacketQueue_.empty() || !running_.load() || audioReaderDone_.load();
    });
    if (audioPacketQueue_.empty()) {
        return false;
    }
    packet = audioPacketQueue_.front();
    audioPacketQueue_.pop_front();
    return true;
}

void ScrcpyStreamManager::recycleAudioPacket(EncodedAudioPacket* packet) {
    if (!packet) {
        return;
    }
    packet->pts = 0;
    packet->submitFlags = 0;
    {
        std::lock_guard<std::mutex> lock(audioPacketMutex_);
        freeAudioPackets_.push_back(packet);
    }
}

void ScrcpyStreamManager::cacheAudioConfig(const uint8_t* data, size_t len, uint32_t flags) {
    std::lock_guard<std::mutex> lock(audioPacketMutex_);
    latestAudioConfig_.assign(data, data + len);
    latestAudioConfigFlags_ = flags;
    ++latestAudioConfigSerial_;
}

bool ScrcpyStreamManager::copyPendingAudioConfig(std::vector<uint8_t>& out, uint32_t& flags,
                                                 uint64_t& serial, uint64_t lastSerial) {
    std::lock_guard<std::mutex> lock(audioPacketMutex_);
    if (latestAudioConfigSerial_ == 0 || latestAudioConfigSerial_ == lastSerial || latestAudioConfig_.empty()) {
        return false;
    }
    out = latestAudioConfig_;
    flags = latestAudioConfigFlags_;
    serial = latestAudioConfigSerial_;
    return true;
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

    running_.store(true);
    videoReaderDone_.store(false);
    audioReaderDone_.store(false);
    drainReliableQueue(controlReliableQueue_);
    initPacketPools();

    OH_LOG_INFO(LOG_APP,
                "[StreamManager] Starting with video=%{public}d, audio=%{public}d, control=%{public}d",
                config_.videoStreamId, config_.audioStreamId, config_.controlStreamId);

    if (videoStream_) {
        videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
    }

    if (audioStream_) {
        audioThread_ = std::thread(&ScrcpyStreamManager::audioThreadFunc, this);
    }

    if (controlStream_) {
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
    videoReaderDone_.store(false);
    audioReaderDone_.store(false);
    drainReliableQueue(controlReliableQueue_);
    initPacketPools();
    acceptThread_ = std::thread(&ScrcpyStreamManager::acceptThreadFunc, this);

    OH_LOG_INFO(LOG_APP,
                "[StreamManager] Reverse listener started on port=%{public}u, video=%{public}d, audio=%{public}d, control=%{public}d",
                port, config_.expectVideo, config_.expectAudio, config_.expectControl);
    return static_cast<int32_t>(port);
}

// ===================== stop =====================

void ScrcpyStreamManager::stop() {
    bool wasRunning = running_.exchange(false);
    if (!wasRunning && !videoThread_.joinable() && !videoDecodeThread_.joinable() &&
        !audioThread_.joinable() && !audioDecodeThread_.joinable() &&
        !controlThread_.joinable() && !controlSendThread_.joinable() &&
        !acceptThread_.joinable()) {
        return;
    }

    OH_LOG_INFO(LOG_APP, "[StreamManager] Stopping...");

    closeLocalTunnels();
    closeListener();
    videoReaderDone_.store(true);
    audioReaderDone_.store(true);
    videoPacketCv_.notify_all();
    audioPacketCv_.notify_all();

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
    joinThread(videoDecodeThread_);
    joinThread(audioThread_);
    joinThread(audioDecodeThread_);
    joinThread(controlThread_);
    joinThread(controlSendThread_);
    joinThread(acceptThread_);
    drainReliableQueue(controlReliableQueue_);
    releaseLocalTunnels();
    resetPacketPools();

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

bool ScrcpyStreamManager::sendControl(const uint8_t* data, size_t len) {
    if (!running_.load() || len == 0) {
        return false;
    }

    if (controlReliableQueue_.size_approx() >= CONTROL_MSG_QUEUE_MAX) {
        return false;
    }

    controlReliableQueue_.enqueue(std::vector<uint8_t>(data, data + len));
    return true;
}

void ScrcpyStreamManager::controlSendThreadFunc() {
    while (true) {
        std::vector<uint8_t> packet;
        if (!controlReliableQueue_.wait_dequeue_timed(packet, std::chrono::milliseconds(1))) {
            if (!running_.load()) {
                break;
            }
            continue;
        }

        try {
            if (adb_ && controlStream_) {
                adb_->streamWrite(controlStream_, packet.data(), packet.size());
            } else if (controlChannel_) {
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

// ===================== Video Thread =====================

void ScrcpyStreamManager::videoThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[VideoThread] Started");

    try {
        auto readToBuffer = [this](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            if (videoChannel_) {
                readExactToBuffer(videoChannel_, dest, size, timeoutMs);
                return;
            }
            if (videoStream_) {
                readExactToBuffer(videoStream_, dest, size, timeoutMs);
                return;
            }
            throw std::runtime_error("video source not found");
        };

        auto readBytes = [this, &readToBuffer](size_t size, int32_t timeoutMs = -1) {
            std::vector<uint8_t> data(size);
            readToBuffer(data.data(), size, timeoutMs);
            return data;
        };

        if (config_.sendDummyByte) {
            auto dummy = readBytes(1, 2000);
            (void) dummy;
            OH_LOG_DEBUG(LOG_APP, "[VideoThread] Dummy byte read");
        }

        auto deviceNameData = readBytes(64, 2000);
        std::string deviceName(reinterpret_cast<char*>(deviceNameData.data()), 64);
        deviceName = deviceName.c_str();
        OH_LOG_INFO(LOG_APP, "[VideoThread] Device: %{public}s", deviceName.c_str());

        auto codecMeta = readBytes(12, 2000);
        int32_t codecId = readInt32BE(codecMeta.data());
        int32_t width = readInt32BE(codecMeta.data() + 4);
        int32_t height = readInt32BE(codecMeta.data() + 8);

        OH_LOG_INFO(LOG_APP, "[VideoThread] Codec=%{public}d, Size=%{public}dx%{public}d",
                    codecId, width, height);
        videoWidth_.store(width);
        videoHeight_.store(height);

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
            this->videoWidth_.store(w);
            this->videoHeight_.store(h);
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
            videoReaderDone_.store(true);
            videoPacketCv_.notify_all();
            return;
        }

        int32_t startRet = videoDecoder_->Start();
        if (startRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Decoder start failed: %{public}d", startRet);
            emitEvent("error", "Video decoder start failed");
            videoReaderDone_.store(true);
            videoPacketCv_.notify_all();
            return;
        }

        videoDecodeThread_ = std::thread(&ScrcpyStreamManager::videoDecodeThreadFunc, this);
        OH_LOG_INFO(LOG_APP, "[VideoThread] Decoder started, entering frame loop");

        uint8_t headerBuf[8];

        while (running_.load()) {
            readToBuffer(headerBuf, 8);
            int64_t ptsRaw = readInt64BE(headerBuf);

            bool isConfig = (ptsRaw & SCRCPY_PACKET_FLAG_CONFIG) != 0;
            bool isKeyFrame = (ptsRaw & SCRCPY_PACKET_FLAG_KEY_FRAME) != 0;
            int64_t cleanPts = ptsRaw & SCRCPY_PACKET_PTS_MASK;
            uint32_t submitFlags = isConfig ? PACKET_FLAG_CONFIG : 0;

            readToBuffer(headerBuf, 4);
            int32_t frameSize = readInt32BE(headerBuf);

            if (frameSize <= 0 || frameSize > 20 * 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            EncodedVideoPacket* packet = acquireVideoPacket();
            if (!packet) {
                OH_LOG_WARN(LOG_APP, "[VideoThread] No available packet slot, dropping frame");
                std::vector<uint8_t> dropBuffer(static_cast<size_t>(frameSize));
                readToBuffer(dropBuffer.data(), static_cast<size_t>(frameSize));
                continue;
            }

            packet->data.resize(static_cast<size_t>(frameSize));
            readToBuffer(packet->data.data(), static_cast<size_t>(frameSize));
            packet->pts = cleanPts;
            packet->submitFlags = submitFlags;
            packet->isKeyFrame = isKeyFrame;

            if (isConfig) {
                cacheVideoConfig(packet->data.data(), packet->data.size(), packet->submitFlags);
                recycleVideoPacket(packet);
                OH_LOG_INFO(LOG_APP, "[VideoThread] Cached config packet (SPS/PPS)");
                continue;
            }

            enqueueVideoPacket(packet);
        }

        OH_LOG_INFO(LOG_APP, "[VideoThread] Exiting");
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Video thread error: ") + e.what());
        } else {
            OH_LOG_INFO(LOG_APP, "[VideoThread] Exiting (stopped)");
        }
    }

    videoReaderDone_.store(true);
    videoPacketCv_.notify_all();

    if (running_.load()) {
        emitEvent("disconnected", "video");
    }
}

void ScrcpyStreamManager::videoDecodeThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[VideoDecode] Started");

    uint64_t appliedConfigSerial = 0;
    bool firstFrameNotified = false;
    uint32_t frameCount = 0;

    try {
        while (running_.load() || !videoReaderDone_.load()) {
            EncodedVideoPacket* packet = nullptr;
            if (!waitDequeueVideoPacket(packet)) {
                if (videoReaderDone_.load() || !running_.load()) {
                    break;
                }
                continue;
            }

            std::vector<uint8_t> configData;
            uint32_t configFlags = 0;
            uint64_t nextConfigSerial = appliedConfigSerial;
            if (copyPendingVideoConfig(configData, configFlags, nextConfigSerial, appliedConfigSerial)) {
                uint32_t cfgIndex = 0;
                uint8_t* cfgData = nullptr;
                int32_t cfgCapacity = 0;
                void* cfgHandle = nullptr;
                while (running_.load()) {
                    int32_t ret = videoDecoder_->GetInputBuffer(&cfgIndex, &cfgData, &cfgCapacity, &cfgHandle, 10);
                    if (ret == 0) {
                        if (cfgCapacity >= static_cast<int32_t>(configData.size())) {
                            std::memcpy(cfgData, configData.data(), configData.size());
                            videoDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0,
                                                             static_cast<int32_t>(configData.size()), configFlags);
                            appliedConfigSerial = nextConfigSerial;
                        } else {
                            videoDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0, 0, 0);
                        }
                        break;
                    }
                    if (ret != -2) {
                        OH_LOG_ERROR(LOG_APP, "[VideoDecode] GetInputBuffer for config failed: %{public}d", ret);
                        break;
                    }
                }
            }

            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;
            int32_t getBufRet = -1;
            while (running_.load()) {
                getBufRet = videoDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0 || getBufRet != -2) {
                    break;
                }
            }

            if (getBufRet != 0) {
                recycleVideoPacket(packet);
                if (running_.load()) {
                    OH_LOG_ERROR(LOG_APP, "[VideoDecode] GetInputBuffer failed: %{public}d", getBufRet);
                }
                break;
            }

            if (bufCapacity < static_cast<int32_t>(packet->data.size())) {
                OH_LOG_ERROR(LOG_APP, "[VideoDecode] Buffer too small: %{public}d < %{public}zu",
                             bufCapacity, packet->data.size());
                videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                recycleVideoPacket(packet);
                continue;
            }

            std::memcpy(bufData, packet->data.data(), packet->data.size());
            int32_t submitRet = videoDecoder_->SubmitInputBuffer(
                bufIndex,
                bufHandle,
                packet->pts,
                static_cast<int32_t>(packet->data.size()),
                packet->submitFlags);
            recycleVideoPacket(packet);

            if (submitRet == 0) {
                ++frameCount;
                if (!firstFrameNotified) {
                    firstFrameNotified = true;
                    OH_LOG_INFO(LOG_APP, "[VideoDecode] First frame submitted");
                    emitEvent("first_frame", "");
                }
            } else {
                OH_LOG_ERROR(LOG_APP, "[VideoDecode] Submit failed: %{public}d", submitRet);
            }
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[VideoDecode] Error: %{public}s", e.what());
        }
    }

    OH_LOG_INFO(LOG_APP, "[VideoDecode] Exiting, total frames: %{public}u", frameCount);
}

// ===================== Audio Thread =====================

void ScrcpyStreamManager::audioThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[AudioThread] Started");

    try {
        auto readToBuffer = [this](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            if (audioChannel_) {
                readExactToBuffer(audioChannel_, dest, size, timeoutMs);
                return;
            }
            if (audioStream_) {
                readExactToBuffer(audioStream_, dest, size, timeoutMs);
                return;
            }
            throw std::runtime_error("audio source not found");
        };

        uint8_t codecBytes[4];
        readToBuffer(codecBytes, 4, 2000);
        int32_t codecId = readInt32BE(codecBytes);

        OH_LOG_INFO(LOG_APP, "[AudioThread] Audio codec ID: 0x%{public}x", codecId);

        if (codecId == 0) {
            OH_LOG_INFO(LOG_APP, "[AudioThread] Audio disabled by server");
            emitEvent("audio_disabled", "");
            audioReaderDone_.store(true);
            audioPacketCv_.notify_all();
            return;
        }
        if (codecId == 1) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Audio config error from server");
            audioReaderDone_.store(true);
            audioPacketCv_.notify_all();
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
            audioReaderDone_.store(true);
            audioPacketCv_.notify_all();
            return;
        }

        int32_t startRet = audioDecoder_->Start();
        if (startRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Decoder start failed: %{public}d", startRet);
            emitEvent("error", "Audio decoder start failed");
            audioReaderDone_.store(true);
            audioPacketCv_.notify_all();
            return;
        }

        audioDecodeThread_ = std::thread(&ScrcpyStreamManager::audioDecodeThreadFunc, this);
        OH_LOG_INFO(LOG_APP, "[AudioThread] Decoder started, entering frame loop");

        uint8_t ptsData[8];
        uint8_t sizeData[4];
        while (running_.load()) {
            readToBuffer(ptsData, 8);
            int64_t ptsRaw = readInt64BE(ptsData);

            bool isConfig = (ptsRaw & SCRCPY_PACKET_FLAG_CONFIG) != 0;
            int64_t cleanPts = ptsRaw & SCRCPY_PACKET_PTS_MASK;

            readToBuffer(sizeData, 4);
            int32_t frameSize = readInt32BE(sizeData);

            if (frameSize <= 0 || frameSize > 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[AudioThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            EncodedAudioPacket* packet = acquireAudioPacket();
            if (!packet) {
                OH_LOG_WARN(LOG_APP, "[AudioThread] No available packet slot, dropping packet");
                std::vector<uint8_t> dropBuffer(static_cast<size_t>(frameSize));
                readToBuffer(dropBuffer.data(), static_cast<size_t>(frameSize));
                continue;
            }

            packet->data.resize(static_cast<size_t>(frameSize));
            readToBuffer(packet->data.data(), static_cast<size_t>(frameSize));
            packet->pts = cleanPts;
            packet->submitFlags = isConfig ? PACKET_FLAG_CONFIG : 0;

            if (isConfig) {
                cacheAudioConfig(packet->data.data(), packet->data.size(), packet->submitFlags);
                recycleAudioPacket(packet);
                OH_LOG_INFO(LOG_APP, "[AudioThread] Cached config packet: %{public}d bytes", frameSize);
                continue;
            }

            enqueueAudioPacket(packet);
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

    audioReaderDone_.store(true);
    audioPacketCv_.notify_all();
}

void ScrcpyStreamManager::audioDecodeThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[AudioDecode] Started");

    uint64_t appliedConfigSerial = 0;

    try {
        while (running_.load() || !audioReaderDone_.load()) {
            EncodedAudioPacket* packet = nullptr;
            if (!waitDequeueAudioPacket(packet)) {
                if (audioReaderDone_.load() || !running_.load()) {
                    break;
                }
                continue;
            }

            std::vector<uint8_t> configData;
            uint32_t configFlags = 0;
            uint64_t nextConfigSerial = appliedConfigSerial;
            if (copyPendingAudioConfig(configData, configFlags, nextConfigSerial, appliedConfigSerial)) {
                uint32_t cfgIndex = 0;
                uint8_t* cfgData = nullptr;
                int32_t cfgCapacity = 0;
                void* cfgHandle = nullptr;
                while (running_.load()) {
                    int32_t ret = audioDecoder_->GetInputBuffer(&cfgIndex, &cfgData, &cfgCapacity, &cfgHandle, 10);
                    if (ret == 0) {
                        if (cfgCapacity >= static_cast<int32_t>(configData.size())) {
                            std::memcpy(cfgData, configData.data(), configData.size());
                            audioDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0,
                                                             static_cast<int32_t>(configData.size()), configFlags);
                            appliedConfigSerial = nextConfigSerial;
                        } else {
                            audioDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0, 0, 0);
                        }
                        break;
                    }
                    if (ret != -2) {
                        OH_LOG_ERROR(LOG_APP, "[AudioDecode] GetInputBuffer for config failed: %{public}d", ret);
                        break;
                    }
                }
            }

            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;
            int32_t getBufRet = -1;
            while (running_.load()) {
                getBufRet = audioDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0 || getBufRet != -2) {
                    break;
                }
            }

            if (getBufRet != 0) {
                recycleAudioPacket(packet);
                if (running_.load()) {
                    OH_LOG_ERROR(LOG_APP, "[AudioDecode] GetInputBuffer failed: %{public}d", getBufRet);
                }
                break;
            }

            if (bufCapacity < static_cast<int32_t>(packet->data.size())) {
                OH_LOG_ERROR(LOG_APP, "[AudioDecode] Buffer too small: %{public}d < %{public}zu",
                             bufCapacity, packet->data.size());
                audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                recycleAudioPacket(packet);
                continue;
            }

            std::memcpy(bufData, packet->data.data(), packet->data.size());
            int32_t submitRet = audioDecoder_->SubmitInputBuffer(
                bufIndex,
                bufHandle,
                packet->pts,
                static_cast<int32_t>(packet->data.size()),
                packet->submitFlags);
            recycleAudioPacket(packet);
            if (submitRet != 0) {
                OH_LOG_WARN(LOG_APP, "[AudioDecode] Submit failed: %{public}d", submitRet);
            }
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[AudioDecode] Error: %{public}s", e.what());
        }
    }

    OH_LOG_INFO(LOG_APP, "[AudioDecode] Exiting");
}

// ===================== Control Thread =====================

void ScrcpyStreamManager::controlThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[ControlThread] Started");

    try {
        auto readToBuffer = [this](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            if (controlChannel_) {
                readExactToBuffer(controlChannel_, dest, size, timeoutMs);
                return;
            }
            if (controlStream_) {
                readExactToBuffer(controlStream_, dest, size, timeoutMs);
                return;
            }
            throw std::runtime_error("control source not found");
        };

        auto readBytes = [this, &readToBuffer](size_t size, int32_t timeoutMs = -1) {
            std::vector<uint8_t> data(size);
            readToBuffer(data.data(), size, timeoutMs);
            return data;
        };

        uint8_t typeByte[1];
        uint8_t lenData[4];
        uint8_t ackData[8];
        uint8_t uhidHeader[4];
        while (running_.load()) {
            readToBuffer(typeByte, 1);
            const uint8_t eventType = typeByte[0];

            if (!running_.load()) break;

            switch (eventType) {
                case 0: {
                    readToBuffer(lenData, 4);
                    int32_t clipLen = readInt32BE(lenData);
                    if (clipLen > 0 && clipLen <= 100000) {
                        auto clipTextData = readBytes(static_cast<size_t>(clipLen));
                        std::string text(reinterpret_cast<char*>(clipTextData.data()), clipTextData.size());
                        OH_LOG_DEBUG(LOG_APP, "[ControlThread] Clipboard received: %{public}zu bytes", text.size());
                        emitEvent("clipboard", text);
                    }
                    break;
                }
                case 1: {
                    readToBuffer(ackData, sizeof(ackData));
                    break;
                }
                case 2: {
                    readToBuffer(uhidHeader, sizeof(uhidHeader));
                    int32_t size = (static_cast<int32_t>(uhidHeader[2]) << 8) |
                                   static_cast<int32_t>(uhidHeader[3]);
                    if (size > 0) {
                        readBytes(static_cast<size_t>(size));
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
