#include "ScrcpyStreamManager.h"

#include "stream/StreamStats.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <hilog/log.h>
#include <sstream>
#include <stdexcept>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

namespace {
constexpr size_t VIDEO_STARTUP_PREBUFFER_FRAMES = 10;
constexpr size_t VIDEO_REBUFFER_LOW_WATERMARK = 2;
constexpr int32_t VIDEO_REBUFFER_TRIGGER_MS = 90;
constexpr int32_t VIDEO_REBUFFER_MAX_WAIT_MS = 120;
constexpr int32_t VIDEO_HANDSHAKE_TIMEOUT_MS = 10000;
}

void ScrcpyStreamManager::videoThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[VideoThread] Started");

    try {
        auto source = ::createByteStream(adb_, videoChannel_, videoStream_, "video");
        if (!source) {
            throw std::runtime_error("video source not found");
        }
        ThroughputStats readThroughput;
        FrameStats frameStats;
        DurationStats headerReadStats;
        DurationStats sizeReadStats;
        DurationStats payloadReadStats;
        JitterStats readJitterStats;
        OH_LOG_INFO(LOG_APP, "[VideoThread] Using source: %{public}s", source->debugName());

        auto readToBuffer = [this, &source](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            readExactToBuffer(source.get(), dest, size, timeoutMs);
        };

        auto readBytes = [this, &source](size_t size, int32_t timeoutMs = -1) {
            return readExact(source.get(), size, timeoutMs);
        };

        OH_LOG_INFO(LOG_APP, "[VideoThread] Waiting for startup handshake, timeout=%{public}d ms",
                    VIDEO_HANDSHAKE_TIMEOUT_MS);

        if (config_.sendDummyByte) {
            auto dummy = readBytes(1, VIDEO_HANDSHAKE_TIMEOUT_MS);
            (void)dummy;
            OH_LOG_DEBUG(LOG_APP, "[VideoThread] Dummy byte read");
        }

        auto deviceNameData = readBytes(64, VIDEO_HANDSHAKE_TIMEOUT_MS);
        std::string deviceName(reinterpret_cast<char*>(deviceNameData.data()), 64);
        deviceName = deviceName.c_str();
        OH_LOG_INFO(LOG_APP, "[VideoThread] Device: %{public}s", deviceName.c_str());

        auto codecMeta = readBytes(12, VIDEO_HANDSHAKE_TIMEOUT_MS);
        int32_t codecId = readInt32BEValue(codecMeta.data());
        int32_t width = readInt32BEValue(codecMeta.data() + 4);
        int32_t height = readInt32BEValue(codecMeta.data() + 8);

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
            videoPackets_.notifyAll();
            return;
        }

        int32_t startRet = videoDecoder_->Start();
        if (startRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Decoder start failed: %{public}d", startRet);
            emitEvent("error", "Video decoder start failed");
            videoReaderDone_.store(true);
            videoPackets_.notifyAll();
            return;
        }

        videoDecodeThread_ = std::thread(&ScrcpyStreamManager::videoDecodeThreadFunc, this);
        OH_LOG_INFO(LOG_APP, "[VideoThread] Decoder started, entering frame loop");

        uint8_t ptsBuf[8];
        uint8_t sizeBuf[4];

        while (running_.load()) {
            ScrcpyPacketMeta meta = readScrcpyPacketMeta(readToBuffer, ptsBuf, sizeBuf, 20 * 1024 * 1024,
                                                         "VideoThread", &headerReadStats, &sizeReadStats);
            EncodedVideoPacket* packet = readScrcpyPacketPayload<EncodedVideoPacket>(
                readToBuffer, [this]() { return videoPackets_.acquireForWrite(); }, meta,
                "VideoThread", "frame", &payloadReadStats, &readJitterStats);
            if (!packet) {
                continue;
            }
            applyPacketMeta(packet, meta);

            readThroughput.bytes += packet->data.size();
            frameStats.totalBytes += packet->data.size();
            frameStats.maxBytes = std::max(frameStats.maxBytes, packet->data.size());
            ++frameStats.frames;

            maybeLogDurationStats("VideoHeaderRead", headerReadStats);
            maybeLogDurationStats("VideoSizeRead", sizeReadStats);
            maybeLogDurationStats("VideoPayloadRead", payloadReadStats);
            maybeLogJitterStats("VideoReadJitter", readJitterStats);
            maybeLogThroughput("VideoRead", readThroughput);
            maybeLogFrameStats(frameStats);

            if (meta.isConfig) {
                videoPackets_.cacheConfig(packet->data.data(), packet->data.size(), packet->submitFlags);
                videoPackets_.recycle(packet);
                OH_LOG_INFO(LOG_APP, "[VideoThread] Cached config packet (SPS/PPS)");
                continue;
            }

            videoPackets_.enqueue(packet);
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
    videoPackets_.notifyAll();

    if (running_.load()) {
        emitEvent("disconnected", "video");
    }
}

void ScrcpyStreamManager::videoDecodeThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[VideoDecode] Started");

    uint64_t appliedConfigSerial = 0;
    bool firstFrameNotified = false;
    bool startupBuffered = false;
    bool rebuffering = false;
    bool starvationActive = false;
    auto rebufferStart = std::chrono::steady_clock::now();
    auto starvationStart = std::chrono::steady_clock::now();
    uint32_t frameCount = 0;
    ThroughputStats decoderInThroughput;
    JitterStats decoderInJitter;
    DurationStats inputWaitStats;

    try {
        while (running_.load() || !videoReaderDone_.load()) {
            if ((!startupBuffered || rebuffering) && running_.load()) {
                size_t queuedFrames = videoPackets_.queuedSize();
                const size_t targetFrames = startupBuffered ? VIDEO_REBUFFER_LOW_WATERMARK
                                                            : VIDEO_STARTUP_PREBUFFER_FRAMES;
                if (!videoReaderDone_.load() && queuedFrames < targetFrames) {
                    if (rebuffering &&
                        elapsedMs(rebufferStart, std::chrono::steady_clock::now()) >= VIDEO_REBUFFER_MAX_WAIT_MS) {
                        OH_LOG_INFO(LOG_APP,
                                    "[VideoDecode] Rebuffer timeout, continue with queued=%{public}zu",
                                    queuedFrames);
                        rebuffering = false;
                    } else {
                        std::this_thread::sleep_for(std::chrono::milliseconds(2));
                        continue;
                    }
                }
                startupBuffered = true;
                rebuffering = false;
                starvationActive = false;
                OH_LOG_INFO(LOG_APP, "[VideoDecode] Buffer ready: queued=%{public}zu", queuedFrames);
            }

            EncodedVideoPacket* packet = nullptr;
            if (!videoPackets_.waitDequeueTimed(packet, 10, running_, videoReaderDone_)) {
                if (videoReaderDone_.load() || !running_.load()) {
                    break;
                }
                auto now = std::chrono::steady_clock::now();
                if (!startupBuffered) {
                    continue;
                }
                if (!starvationActive) {
                    starvationActive = true;
                    starvationStart = now;
                    continue;
                }
                if (!rebuffering &&
                    elapsedMs(starvationStart, now) >= VIDEO_REBUFFER_TRIGGER_MS) {
                    rebuffering = true;
                    rebufferStart = now;
                    OH_LOG_INFO(LOG_APP, "[VideoDecode] Sustained starvation, enter rebuffer");
                }
                continue;
            }
            starvationActive = false;
            rebuffering = false;

            std::vector<uint8_t> configData;
            uint32_t configFlags = 0;
            uint64_t nextConfigSerial = appliedConfigSerial;
            if (videoPackets_.copyPendingConfig(configData, configFlags, nextConfigSerial, appliedConfigSerial)) {
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
            auto inputWaitStart = std::chrono::steady_clock::now();
            while (running_.load()) {
                getBufRet = videoDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0 || getBufRet != -2) {
                    break;
                }
            }
            recordDuration(inputWaitStats, elapsedMs(inputWaitStart, std::chrono::steady_clock::now()));

            if (getBufRet != 0) {
                videoPackets_.recycle(packet);
                if (running_.load()) {
                    OH_LOG_ERROR(LOG_APP, "[VideoDecode] GetInputBuffer failed: %{public}d", getBufRet);
                }
                break;
            }

            if (bufCapacity < static_cast<int32_t>(packet->data.size())) {
                OH_LOG_ERROR(LOG_APP, "[VideoDecode] Buffer too small: %{public}d < %{public}zu",
                             bufCapacity, packet->data.size());
                videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                videoPackets_.recycle(packet);
                continue;
            }

            std::memcpy(bufData, packet->data.data(), packet->data.size());
            int32_t submitRet = videoDecoder_->SubmitInputBuffer(
                bufIndex,
                bufHandle,
                packet->pts,
                static_cast<int32_t>(packet->data.size()),
                packet->submitFlags);
            videoPackets_.recycle(packet);

            if (submitRet == 0) {
                ++frameCount;
                decoderInThroughput.bytes += packet->data.size();
                ++decoderInThroughput.frames;
                recordJitter(decoderInJitter, std::chrono::steady_clock::now());
                maybeLogDecoderRate("DecoderIn", decoderInThroughput);
                maybeLogJitterStats("DecoderInJitter", decoderInJitter);
                maybeLogDurationStats("VideoInputWait", inputWaitStats);
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
