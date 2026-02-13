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

std::vector<uint8_t> ScrcpyStreamManager::readExact(int32_t streamId, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !adb_) {
        throw std::runtime_error("Stream manager not running");
    }
    auto data = adb_->streamRead(streamId, size, timeoutMs);
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

    // Force close streams to unblock read threads
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
        auto dummy = readExact(config_.videoStreamId, 1, 2000); // 2s Timeout
        OH_LOG_DEBUG(LOG_APP, "[VideoThread] Dummy byte read");

        // 2. 读取设备名 (64 字节)
        auto deviceNameData = readExact(config_.videoStreamId, 64, 2000);
        std::string deviceName(reinterpret_cast<char*>(deviceNameData.data()), 64);
        // 去掉尾零
        deviceName = deviceName.c_str();
        OH_LOG_INFO(LOG_APP, "[VideoThread] Device: %{public}s", deviceName.c_str());

        // 3. 读取编码元数据 (12 字节: codecId(4) + width(4) + height(4))
        auto codecMeta = readExact(config_.videoStreamId, 12, 2000);
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
        // 5. 帧读取循环
        uint32_t frameCount = 0;
        bool firstFrameNotified = false;
        
        uint8_t headerBuf[8]; // Reuse for PTS(8) and Size(4)

        while (running_.load()) {
            // 读取 PTS (8 字节)
            // Use exact=true to throw if incomplete
            try {
                adb_->streamReadToBuffer(config_.videoStreamId, headerBuf, 8, -1, true);
            } catch (const std::exception& e) {
                if (running_.load()) OH_LOG_WARN(LOG_APP, "[VideoThread] Stream read error (PTS): %{public}s", e.what());
                break;
            }
            int64_t ptsRaw = readInt64BE(headerBuf);

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
            try {
                adb_->streamReadToBuffer(config_.videoStreamId, headerBuf, 4, -1, true);
            } catch (...) {
                break;
            }
            int32_t frameSize = readInt32BE(headerBuf);

            if (frameSize <= 0 || frameSize > 20 * 1024 * 1024) {
                OH_LOG_ERROR(LOG_APP, "[VideoThread] Invalid frame size: %{public}d", frameSize);
                break;
            }

            // *** ZERO-COPY PATH ***
            // 1. Acquire Input Buffer
            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;
            
            int32_t getBufRet = -1;
            while (running_.load()) {
                getBufRet = videoDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10); // 10ms timeout
                if (getBufRet == 0) break; // Success
                // If timeout (-2), loop again
                if (getBufRet != -2) {
                     OH_LOG_ERROR(LOG_APP, "[VideoThread] GetInputBuffer failed: %{public}d", getBufRet);
                     break; 
                }
            }
            
            if (getBufRet != 0) break; // Error or Stopped
            
            // 2. Check Capacity
            if (bufCapacity < frameSize) {
                 OH_LOG_ERROR(LOG_APP, "[VideoThread] Buffer too small: %{public}d < %{public}d", bufCapacity, frameSize);
                 // We must read/consume the data from network to stay in sync, even if we drop frame
                 // Or we could just break/restart?
                 // For now, let's just drain to a temp buffer and Submit empty flag?
                 // Or just SubmitInputBuffer with size 0?
                 // We need to consume stream data!
                 std::vector<uint8_t> temp(frameSize);
                 adb_->streamReadToBuffer(config_.videoStreamId, temp.data(), frameSize, -1, true);
                 
                 // Return buffer empty
                 videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0); 
                 continue;
            }

            // 3. Read directly into Buffer
            try {
                adb_->streamReadToBuffer(config_.videoStreamId, bufData, frameSize, -1, true);
            } catch (...) {
                 // Return buffer before exiting
                 videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0); 
                 break;
            }

            // 4. Submit Buffer
            int32_t submitRet = videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, cleanPts, frameSize, flags);

            if (submitRet == 0) {
                frameCount++;
                if (!firstFrameNotified) {
                    firstFrameNotified = true;
                    OH_LOG_INFO(LOG_APP, "[VideoThread] First frame decoded (Zero-Copy)");
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
        // 1. 读取音频 codec header (4 字节)
        // 1. 读取音频 codec header (4 字节)
        auto codecBytes = readExact(config_.audioStreamId, 4, 2000);
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

            // *** ZERO-COPY PATH ***
            // 1. Acquire Input Buffer
            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;

            int32_t getBufRet = -1;
            int retryCount = 0;
            while (running_.load()) {
                getBufRet = audioDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10); // 10ms timeout
                if (getBufRet == 0) break; // Success
                
                // If timeout (-2), loop again (backpressure)
                if (getBufRet == -2) {
                    retryCount++;
                    if (retryCount % 100 == 0) {
                         // OH_LOG_WARN(LOG_APP, "[AudioThread] Waiting for input buffer...");
                    }
                    continue; 
                }
                
                OH_LOG_ERROR(LOG_APP, "[AudioThread] GetInputBuffer failed: %{public}d", getBufRet);
                break;
            }

            if (getBufRet != 0) break; // Error or Stopped

            // 2. Check Capacity
            if (bufCapacity < frameSize) {
                 OH_LOG_ERROR(LOG_APP, "[AudioThread] Buffer too small: %{public}d < %{public}d", bufCapacity, frameSize);
                 // Consume data ensuring synchronization
                 std::vector<uint8_t> temp(frameSize);
                 adb_->streamReadToBuffer(config_.audioStreamId, temp.data(), frameSize, -1, true);
                 
                 // Return buffer empty
                 audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0); 
                 continue;
            }

            // 3. Read directly into Buffer
            try {
                adb_->streamReadToBuffer(config_.audioStreamId, bufData, frameSize, -1, true);
            } catch (...) {
                 // Return buffer before exiting
                 audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0); 
                 break;
            }

            if (isConfig) {
                OH_LOG_INFO(LOG_APP, "[AudioThread] Config packet: %{public}d bytes", frameSize);
            }

            // 4. Submit Buffer
            // Audio decoder doesn't use specific flags for now, but we pass 0
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
