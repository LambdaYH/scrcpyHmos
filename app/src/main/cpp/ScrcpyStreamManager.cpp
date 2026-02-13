// ScrcpyStreamManager - C++ 层流管理器实现
// 视频线程、音频线程、控制线程分别独立运行
#include "ScrcpyStreamManager.h"
#include <hilog/log.h>
#include <cstring>
#include <stdexcept>
#include <chrono>
#include <sstream>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

// ===================== 辅助函数 =====================

int32_t ScrcpyStreamManager::readInt32BE(const uint8_t* data) {
    return (static_cast<int32_t>(data[0]) << 24) |
           (static_cast<int32_t>(data[1]) << 16) |
           (static_cast<int32_t>(data[2]) << 8)  |
           (static_cast<int32_t>(data[3]));
}

int64_t ScrcpyStreamManager::readInt64BE(const uint8_t* data) {
    return (static_cast<int64_t>(data[0]) << 56) |
           (static_cast<int64_t>(data[1]) << 48) |
           (static_cast<int64_t>(data[2]) << 40) |
           (static_cast<int64_t>(data[3]) << 32) |
           (static_cast<int64_t>(data[4]) << 24) |
           (static_cast<int64_t>(data[5]) << 16) |
           (static_cast<int64_t>(data[6]) << 8)  |
           (static_cast<int64_t>(data[7]));
}

std::vector<uint8_t> ScrcpyStreamManager::readExact(int32_t streamId, size_t size) {
    if (!running_.load() || !adb_) {
        throw std::runtime_error("Stream manager not running");
    }
    auto data = adb_->streamRead(streamId, size);
    if (data.size() < size) {
        throw std::runtime_error("Stream closed or read incomplete");
    }
    return data;
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
    running_.store(true);

    OH_LOG_INFO(LOG_APP, "[StreamManager] Starting with video=%{public}d, audio=%{public}d, control=%{public}d",
                config_.videoStreamId, config_.audioStreamId, config_.controlStreamId);

    // 启动视频线程
    if (config_.videoStreamId >= 0) {
        videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
    }

    // 启动音频线程
    if (config_.audioStreamId >= 0) {
        audioThread_ = std::thread(&ScrcpyStreamManager::audioThreadFunc, this);
    }

    // 启动控制线程
    if (config_.controlStreamId >= 0) {
        controlThread_ = std::thread(&ScrcpyStreamManager::controlThreadFunc, this);
    }

    return 0;
}

// ===================== stop =====================

void ScrcpyStreamManager::stop() {
    if (!running_.load()) return;

    OH_LOG_INFO(LOG_APP, "[StreamManager] Stopping...");
    running_.store(false);

    // 等待线程退出
    if (videoThread_.joinable()) {
        videoThread_.join();
    }
    if (audioThread_.joinable()) {
        audioThread_.join();
    }
    if (controlThread_.joinable()) {
        controlThread_.join();
    }

    // 释放解码器
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

    adb_ = nullptr;
    OH_LOG_INFO(LOG_APP, "[StreamManager] Stopped");
}

// ===================== sendControl =====================

void ScrcpyStreamManager::sendControl(const uint8_t* data, size_t len) {
    if (!running_.load() || !adb_ || config_.controlStreamId < 0) return;

    try {
        adb_->streamWrite(config_.controlStreamId, data, len);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] sendControl error: %{public}s", e.what());
    }
}

// ===================== Video Thread =====================

void ScrcpyStreamManager::videoThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[VideoThread] Started");

    try {
        // 1. 读取 dummy byte (1 字节)
        auto dummy = readExact(config_.videoStreamId, 1);
        OH_LOG_DEBUG(LOG_APP, "[VideoThread] Dummy byte read");

        // 2. 读取设备名 (64 字节)
        auto deviceNameData = readExact(config_.videoStreamId, 64);
        std::string deviceName(reinterpret_cast<char*>(deviceNameData.data()), 64);
        // 去掉尾零
        deviceName = deviceName.c_str();
        OH_LOG_INFO(LOG_APP, "[VideoThread] Device: %{public}s", deviceName.c_str());

        // 3. 读取编码元数据 (12 字节: codecId(4) + width(4) + height(4))
        auto codecMeta = readExact(config_.videoStreamId, 12);
        int32_t codecId = readInt32BE(codecMeta.data());
        int32_t width = readInt32BE(codecMeta.data() + 4);
        int32_t height = readInt32BE(codecMeta.data() + 8);

        OH_LOG_INFO(LOG_APP, "[VideoThread] Codec=%{public}d, Size=%{public}dx%{public}d",
                    codecId, width, height);

        // 确定 codec 类型
        std::string codecType = "h264";
        if (codecId == 1 || codecId == 1748121141) codecType = "h265";   // 0x68323635
        if (codecId == 2 || codecId == 1635135537) codecType = "av1";

        // 通知 ArkTS video_config
        {
            std::ostringstream oss;
            oss << "{\"codecId\":" << codecId
                << ",\"width\":" << width
                << ",\"height\":" << height
                << ",\"codecType\":\"" << codecType << "\""
                << ",\"deviceName\":\"" << deviceName << "\"}";
            emitEvent("video_config", oss.str());
        }

        // 4. 初始化视频解码器
        videoDecoder_ = new VideoDecoderNative();
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

        // 5. 帧读取循环
        uint32_t frameCount = 0;
        bool firstFrameNotified = false;

        while (running_.load()) {
            // 读取 PTS (8 字节)
            auto ptsData = readExact(config_.videoStreamId, 8);
            int64_t ptsRaw = readInt64BE(ptsData.data());

            // 解析 flags
            const int64_t PACKET_FLAG_CONFIG = 1LL << 63;
            bool isConfig = (ptsRaw & PACKET_FLAG_CONFIG) != 0;
            int64_t cleanPts = ptsRaw & ~PACKET_FLAG_CONFIG;

            uint32_t flags = 0;
            if (isConfig) {
                OH_LOG_INFO(LOG_APP, "[VideoThread] Config packet (SPS/PPS)");
                flags = 8; // AVCODEC_BUFFER_FLAGS_CODEC_DATA
            }

            // 读取 size (4 字节)
            auto sizeData = readExact(config_.videoStreamId, 4);
            int32_t frameSize = readInt32BE(sizeData.data());

            if (frameSize <= 0 || frameSize > 20 * 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            // 读取帧数据
            auto frameData = readExact(config_.videoStreamId, frameSize);

            // 推送到解码器（带背压处理）
            int32_t pushResult = videoDecoder_->PushData(frameData.data(), frameSize, cleanPts, flags);

            if (pushResult == 0) {
                frameCount++;
                if (!firstFrameNotified) {
                    firstFrameNotified = true;
                    OH_LOG_INFO(LOG_APP, "[VideoThread] First frame decoded");
                    emitEvent("first_frame", "");
                }
            } else if (pushResult == -2) {
                // Buffer 满，等待重试
                int retryCount = 0;
                while (pushResult == -2 && running_.load() && retryCount < 500) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    pushResult = videoDecoder_->PushData(frameData.data(), frameSize, cleanPts, flags);
                    retryCount++;
                    if (pushResult == 0) {
                        frameCount++;
                        if (!firstFrameNotified) {
                            firstFrameNotified = true;
                            emitEvent("first_frame", "");
                        }
                    }
                }
                if (pushResult == -2) {
                    OH_LOG_WARN(LOG_APP, "[VideoThread] Frame dropped after %{public}d retries", retryCount);
                }
            } else {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Push failed: %{public}d", pushResult);
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

    emitEvent("disconnected", "video");
}

// ===================== Audio Thread =====================

void ScrcpyStreamManager::audioThreadFunc() {
    OH_LOG_INFO(LOG_APP, "[AudioThread] Started");

    try {
        // 1. 读取音频 codec header (4 字节)
        auto codecBytes = readExact(config_.audioStreamId, 4);
        int32_t codecId = readInt32BE(codecBytes.data());

        OH_LOG_INFO(LOG_APP, "[AudioThread] Audio codec ID: 0x%{public}x", codecId);

        // 检查 disabled / error
        if (codecId == 0) {
            OH_LOG_INFO(LOG_APP, "[AudioThread] Audio disabled by server");
            emitEvent("audio_disabled", "");
            return;
        }
        if (codecId == 1) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Audio config error from server");
            return;
        }

        // 确定 codec 名称
        std::string codecName;
        switch (codecId) {
            case 0x6F707573: codecName = "opus"; break;   // "opus"
            case 0x00616163: codecName = "aac"; break;    // "\0aac"
            case 0x666C6163: codecName = "flac"; break;   // "flac"
            case 0x00726177: codecName = "raw"; break;    // "\0raw"
            default:
                OH_LOG_WARN(LOG_APP, "[AudioThread] Unknown codec 0x%{public}x, fallback to opus", codecId);
                codecName = "opus";
                break;
        }

        OH_LOG_INFO(LOG_APP, "[AudioThread] Using codec: %{public}s", codecName.c_str());

        // 2. 初始化音频解码器
        audioDecoder_ = new AudioDecoderNative();
        int32_t initRet = audioDecoder_->Init(codecName.c_str(),
                                               config_.audioSampleRate,
                                               config_.audioChannelCount);
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

        // 3. 帧读取循环
        const int64_t PACKET_FLAG_CONFIG = 1LL << 63;
        const int64_t PACKET_FLAG_KEY_FRAME = 1LL << 62;
        const int64_t PTS_MASK = PACKET_FLAG_KEY_FRAME - 1;

        while (running_.load()) {
            // 读取 PTS (8 字节)
            auto ptsData = readExact(config_.audioStreamId, 8);
            int64_t ptsRaw = readInt64BE(ptsData.data());

            bool isConfig = (ptsRaw & PACKET_FLAG_CONFIG) != 0;
            int64_t cleanPts = ptsRaw & PTS_MASK;

            // 读取 size (4 字节)
            auto sizeData = readExact(config_.audioStreamId, 4);
            int32_t frameSize = readInt32BE(sizeData.data());

            if (frameSize <= 0 || frameSize > 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[AudioThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            // 读取帧数据
            auto frameData = readExact(config_.audioStreamId, frameSize);

            if (isConfig) {
                OH_LOG_INFO(LOG_APP, "[AudioThread] Config packet: %{public}d bytes", frameSize);
            }

            // 推送到解码器（带背压处理）
            int32_t pushResult = audioDecoder_->PushData(frameData.data(), frameSize, cleanPts);

            if (pushResult == -2) {
                int retryCount = 0;
                while (pushResult == -2 && running_.load() && retryCount < 500) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    pushResult = audioDecoder_->PushData(frameData.data(), frameSize, cleanPts);
                    retryCount++;
                }
            }

            if (pushResult < 0 && pushResult != -2) {
                OH_LOG_WARN(LOG_APP, "[AudioThread] Push frame failed: %{public}d", pushResult);
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
        while (running_.load()) {
            // 读取事件类型 (1 字节)
            auto typeByte = readExact(config_.controlStreamId, 1);
            uint8_t eventType = typeByte[0];

            if (!running_.load()) break;

            switch (eventType) {
                case 0: { // DEVICE_MSG_TYPE_CLIPBOARD
                    auto lenData = readExact(config_.controlStreamId, 4);
                    int32_t clipLen = readInt32BE(lenData.data());
                    if (clipLen > 0 && clipLen <= 100000) {
                        auto clipTextData = readExact(config_.controlStreamId, clipLen);
                        std::string text(reinterpret_cast<char*>(clipTextData.data()), clipTextData.size());
                        OH_LOG_DEBUG(LOG_APP, "[ControlThread] Clipboard received: %{public}zu bytes",
                                     text.size());
                        emitEvent("clipboard", text);
                    }
                    break;
                }
                case 1: { // DEVICE_MSG_TYPE_ACK_CLIPBOARD
                    readExact(config_.controlStreamId, 8);
                    break;
                }
                case 2: { // DEVICE_MSG_TYPE_UHID_OUTPUT
                    readExact(config_.controlStreamId, 2); // UHID id
                    auto sizeBytes = readExact(config_.controlStreamId, 2);
                    int32_t size = (static_cast<int32_t>(sizeBytes[0]) << 8) |
                                   static_cast<int32_t>(sizeBytes[1]);
                    if (size > 0) {
                        readExact(config_.controlStreamId, size);
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
