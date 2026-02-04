#include "video_decoder_native.h"
#include "video_stream_processor.h"  // Include for RingBuffer access
#include <hilog/log.h>
#include <queue>
#include <mutex>
#include <cstring>  // for memcpy, strcmp
#include <time.h>   // for nanosleep
#include "multimedia/player_framework/native_avbuffer.h"  // for OH_AVBuffer_SetBufferAttr
#include "multimedia/player_framework/native_avcodec_videoencoder.h"  // for HEVC_PROFILE_MAIN

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "VideoDecoderNative"
#define LOG_DOMAIN 0x3200

VideoDecoderNative::VideoDecoderNative()
    : decoder_(nullptr), window_(nullptr), isStarted_(false),
      width_(0), height_(0), frameCount_(0), codecType_("h264"), context_(nullptr) {
}

VideoDecoderNative::~VideoDecoderNative() {
    Release();
}

void VideoDecoderNative::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    const char* errorStr = "UNKNOWN";
    switch (errorCode) {
        case 1: errorStr = "STREAM_ERR"; break;
        case 2: errorStr = "codec_ERR"; break;
        case 3: errorStr = "RENDER_ERR"; break;
        case 4: errorStr = "UNSUPPORTED"; break;
        case 5: errorStr = "TIMEOUT"; break;
        case 6: errorStr = "INVALID_STATE"; break;
        case 7: errorStr = "INVALID_OPERATION"; break;
        case 8: errorStr = "INVALID_PARAMETER"; break;
        case 9: errorStr = "INSUFFICIENT_DATA"; break;
        default: errorStr = "UNKNOWN"; break;
    }
    OH_LOG_ERROR(LOG_APP, "[Native] Decoder error %{public}s (%{public}d)", errorStr, errorCode);
}

void VideoDecoderNative::OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "[Native] Stream format changed");
}

void VideoDecoderNative::OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    DecoderContext* context = static_cast<DecoderContext*>(userData);
    if (context == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] OnNeedInputBuffer: context is null");
        return;
    }

    std::lock_guard<std::mutex> lock(context->queueMutex);
    if (buffer != nullptr) {
        // 只保存buffer指针到map，使用index作为key
        context->inputBuffers[index] = buffer;
        context->inputBufferQueue.push(index);
        // 添加日志追踪输入缓冲区
        static int bufferCount = 0;
        bufferCount++;
        // 记录前10个缓冲区的详细时间戳，用于诊断H265延迟问题
        if (bufferCount <= 10) {
            OH_LOG_INFO(LOG_APP, "[Native] OnNeedInputBuffer: index=%{public}u, queueSize=%{public}zu, totalCount=%{public}d (FIRST %{public}d BUFFERS)",
                        index, context->inputBufferQueue.size(), bufferCount, bufferCount <= 10 ? bufferCount : 10);
        } else if (bufferCount == 11) {
            OH_LOG_INFO(LOG_APP, "[Native] OnNeedInputBuffer: ... (continuing normal logging)");
        }
    } else {
        OH_LOG_ERROR(LOG_APP, "[Native] OnNeedInputBuffer: buffer is null for index=%{public}u", index);
    }
    context->waitForFirstBuffer = false;
}

void VideoDecoderNative::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    DecoderContext* context = static_cast<DecoderContext*>(userData);
    if (context == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] OnNewOutputBuffer: context is null");
        return;
    }

    // 第一帧输出时获取输出格式信息（对于H265特别重要）
    if (context->isDecFirstFrame) {
        OH_AVFormat* format = OH_VideoDecoder_GetOutputDescription(codec);
        if (format != nullptr) {
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &context->outputWidth);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &context->outputHeight);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &context->widthStride);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &context->heightStride);

//            OH_LOG_INFO(LOG_APP, "[Native] First frame output format: %{public}dx%{public}d, stride=%{public}d, sliceHeight=%{public}d",
//                       context->outputWidth, context->outputHeight, context->widthStride, context->heightStride);

            OH_AVFormat_Destroy(format);
        }
        context->isDecFirstFrame = false;
    }

    // 获取buffer属性
    OH_AVCodecBufferAttr attr;
    OH_AVErrCode ret = OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (ret == AV_ERR_OK) {
    // Get presentation timestamp
    int64_t pts = (int64_t)attr.pts;

    // 启用日志以便诊断渲染问题
    OH_LOG_DEBUG(LOG_APP, "[Native] OnNewOutputBuffer: index=%{public}u, size=%{public}d, pts=%{public}lld, flags=0x%{public}x",
                 index, attr.size, (long long)pts, attr.flags);

    // 渲染到Surface - 只调用RenderOutputBuffer，不要调用FreeOutputBuffer
    OH_AVErrCode renderRet = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (renderRet != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] RenderOutputBuffer failed: %{public}d", renderRet);
        // 如果渲染失败，尝试释放buffer
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
    } else {
        OH_LOG_DEBUG(LOG_APP, "[Native] Rendered frame successfully, pts=%{public}lld", (long long)pts);
        // 诊断：检查此时队列中剩余的buffer数量
        std::lock_guard<std::mutex> lock(context->queueMutex);
        OH_LOG_DEBUG(LOG_APP, "[Native] Input buffer queue size after render: %{public}zu", context->inputBufferQueue.size());
    }
    } else {
        OH_LOG_ERROR(LOG_APP, "[Native] OnNewOutputBuffer: GetBufferAttr failed: %{public}d", ret);
    }
}

int32_t VideoDecoderNative::Init(const char* codecType, const char* surfaceId, int32_t width, int32_t height) {
    OH_LOG_INFO(LOG_APP, "[Native] Init START: codec=%{public}s, size=%{public}dx%{public}d, surfaceId=%{public}s",
                codecType, width, height, surfaceId);

    width_ = width;
    height_ = height;
    codecType_ = codecType ? codecType : "h264";

    // 根据codecType选择对应的MIME类型
    const char* mimeType = nullptr;
    if (strcmp(codecType_.c_str(), "h264") == 0 || codecType_.empty()) {
        mimeType = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    } else if (strcmp(codecType_.c_str(), "h265") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
    } else if (strcmp(codecType_.c_str(), "av1") == 0) {
        // AV1 support - HarmonyOS 5.0+
        mimeType = "video/av01";  // OH_AVCODEC_MIMETYPE_VIDEO_AV1 if defined
    } else {
        OH_LOG_WARN(LOG_APP, "[Native] Unknown codec type: %{public}s, fallback to H264", codecType);
        mimeType = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    }

    OH_LOG_INFO(LOG_APP, "[Native] Creating decoder with MIME: %{public}s", mimeType);

    // 创建解码器
    decoder_ = OH_VideoDecoder_CreateByMime(mimeType);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create decoder FAILED, codec=%{public}s", mimeType);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[Native] Create decoder SUCCESS");

    // 配置解码器
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, 60);
    // Enable low latency mode
    OH_AVFormat_SetIntValue(format, "video_enable_low_latency", 1);

    // 为H265添加特定的配置参数
    if (strcmp(codecType_.c_str(), "h265") == 0) {
        OH_LOG_INFO(LOG_APP, "[Native] Setting H265 specific parameters");
        // H265 Profile由解码器自动识别，不强制设置
        // OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, HEVC_PROFILE_MAIN);
    }

    OH_LOG_INFO(LOG_APP, "[Native] Decoder config: width=%{public}d, height=%{public}d, pixelFormat=NV12, frameRate=60",
                width, height);

    int32_t ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Configure FAILED: %{public}d", ret);
        return ret;
    }
    OH_LOG_INFO(LOG_APP, "[Native] Configure SUCCESS");

    // 从surfaceId获取window
    uint64_t surfaceIdNum = std::stoull(surfaceId);
    OH_LOG_INFO(LOG_APP, "[Native] Creating NativeWindow from surfaceId: %{public}llu", (unsigned long long)surfaceIdNum);
    int32_t windowRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceIdNum, &window_);
    if (windowRet != 0 || window_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create window FAILED: %{public}d", windowRet);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[Native] Create NativeWindow SUCCESS");

    // 设置输出Surface
    ret = OH_VideoDecoder_SetSurface(decoder_, window_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] SetSurface FAILED: %{public}d", ret);
        return ret;
    }
    OH_LOG_INFO(LOG_APP, "[Native] SetSurface SUCCESS");

    // 设置回调
    context_ = new DecoderContext();
    context_->decoder = this;
    context_->waitForFirstBuffer = true;
    context_->isDecFirstFrame = true;  // 标记第一帧输出
    context_->outputWidth = width;
    context_->outputHeight = height;
    context_->widthStride = 0;
    context_->heightStride = 0;

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;

    OH_LOG_INFO(LOG_APP, "[Native] Registering callback...");
    ret = OH_VideoDecoder_RegisterCallback(decoder_, callback, context_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] RegisterCallback FAILED: %{public}d", ret);
        delete context_;
        context_ = nullptr;
        return ret;
    }
    OH_LOG_INFO(LOG_APP, "[Native] RegisterCallback SUCCESS");

    // 准备解码器
    OH_LOG_INFO(LOG_APP, "[Native] Preparing decoder...");
    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Prepare FAILED: %{public}d", ret);
        return ret;
    }
    OH_LOG_INFO(LOG_APP, "[Native] Prepare SUCCESS");

    OH_LOG_INFO(LOG_APP, "[Native] Init COMPLETE, codec=%{public}s", codecType);
    return 0;
}

int32_t VideoDecoderNative::Start() {
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Start FAILED: decoder is null");
        return -1;
    }

    OH_LOG_INFO(LOG_APP, "[Native] Starting decoder...");
    int32_t ret = OH_VideoDecoder_Start(decoder_);
    if (ret == AV_ERR_OK) {
        isStarted_ = true;
        OH_LOG_INFO(LOG_APP, "[Native] Decoder STARTED successfully");

        // 等待初始输入缓冲区可用（最多等待2秒）
        // 这是为了确保在推送数据前，解码器已经准备好接收数据
        OH_LOG_INFO(LOG_APP, "[Native] Waiting for initial input buffers...");
        int waitCount = 0;
        constexpr int MAX_WAIT_COUNT = 200;  // 200 * 10ms = 2000ms
        while (waitCount < MAX_WAIT_COUNT) {
            {
                std::lock_guard<std::mutex> lock(context_->queueMutex);
                if (!context_->inputBufferQueue.empty()) {
                    OH_LOG_INFO(LOG_APP, "[Native] Initial input buffer available after %{public}dx10ms", waitCount);
                    return ret;
                }
            }
            // 使用nanosleep替代sleep_for
            struct timespec ts = {0, 10000000};  // 10ms
            nanosleep(&ts, nullptr);
            waitCount++;
        }
        OH_LOG_WARN(LOG_APP, "[Native] Timeout waiting for initial input buffers (queue still empty after %{public}ms), continuing anyway",
                   waitCount * 10);
    } else {
        OH_LOG_ERROR(LOG_APP, "[Native] Start FAILED: %{public}d", ret);
    }
    return ret;
}

int32_t VideoDecoderNative::PushData(uint8_t* data, int32_t size, int64_t pts, uint32_t flags) {
    if (!isStarted_ || decoder_ == nullptr || context_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushData: decoder not ready, started=%{public}d, decoder=%{public}s, context=%{public}s",
                     isStarted_, decoder_ ? "valid" : "null", context_ ? "valid" : "null");
        return -1;
    }

    // 从队列获取可用的input buffer index
    uint32_t bufferIndex = 0;
    OH_AVBuffer* buffer = nullptr;

    {
        std::lock_guard<std::mutex> lock(context_->queueMutex);
        if (!context_->inputBufferQueue.empty()) {
            bufferIndex = context_->inputBufferQueue.front();
            context_->inputBufferQueue.pop();
            // 从map获取buffer
            auto it = context_->inputBuffers.find(bufferIndex);
            if (it != context_->inputBuffers.end()) {
                buffer = it->second;
                context_->inputBuffers.erase(it);
            }
        }
    }

    if (buffer == nullptr) {
        // OH_LOG_DEBUG(LOG_APP, "[Native] PushData: no available input buffer");
        return -2;  // 表示暂时没有可用buffer
    }

    if (buffer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushData: buffer is null");
        return -1;
    }

    // OH_LOG_DEBUG(LOG_APP, "[Native] Got buffer, capacity=%{public}d", OH_AVBuffer_GetCapacity(buffer));

    // 获取buffer的内存地址
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushData: buffer size %{public}d < data size %{public}d", bufferSize, size);
        return -1;
    }

    // 复制数据到buffer
    memcpy(bufferAddr, data, size);

    // 设置buffer属性 - 必须告诉解码器实际数据大小
    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = flags;

    if (flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
        OH_LOG_INFO(LOG_APP, "[Native] CSD data received, size=%{public}d, flags=0x%{public}x, totalFrames=%{public}u",
                   size, flags, frameCount_);
        // Log first few bytes to help debug H.265 VPS/SPS
        if (size >= 4) {
            OH_LOG_INFO(LOG_APP, "[Native] CSD first 4 bytes: 0x%02X 0x%02X 0x%02X 0x%02X",
                       data[0], data[1], data[2], data[3]);
        }
    }

    OH_AVErrCode attrRet = OH_AVBuffer_SetBufferAttr(buffer, &attr);
    if (attrRet != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] SetBufferAttr failed: %{public}d", attrRet);
        return -1;
    }

    // 提交buffer到解码器
    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, bufferIndex);
    if (ret != AV_ERR_OK) {
        const char* errorStr = "UNKNOWN";
        switch (ret) {
            case 1: errorStr = "STREAM_ERR"; break;
            case 2: errorStr = "codec_ERR"; break;
            case 3: errorStr = "RENDER_ERR"; break;
            case 4: errorStr = "UNSUPPORTED"; break;
            case 5: errorStr = "TIMEOUT"; break;
            case 6: errorStr = "INVALID_STATE"; break;
            case 7: errorStr = "INVALID_OPERATION"; break;
            case 8: errorStr = "INVALID_PARAMETER"; break;
            case 9: errorStr = "INSUFFICIENT_DATA"; break;
            default: errorStr = "UNKNOWN"; break;
        }
        OH_LOG_ERROR(LOG_APP, "[Native] PushData: failed to push input buffer, %{public}s (%{public}d), index=%{public}u, size=%{public}d",
                     errorStr, ret, bufferIndex, size);

        // 将buffer放回队列以便重试
        {
            std::lock_guard<std::mutex> lock(context_->queueMutex);
            context_->inputBuffers[bufferIndex] = buffer;
        }
        return -1;
    }

    // buffer已经提交，不需要清理

    frameCount_++;

    // 每50帧输出一次统计信息
//    if (frameCount_ % 50 == 0) {
//        OH_LOG_DEBUG(LOG_APP, "[Native] Pushed %{public}u frames total (last size=%{public}d)", frameCount_, size);
//    }

    return 0;
}

int32_t VideoDecoderNative::PushFromRingBuffer(RingBuffer* ringBuffer, int32_t size, int64_t pts, uint32_t flags) {
    if (!isStarted_ || decoder_ == nullptr || context_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushFromRingBuffer: decoder not ready");
        return -1;
    }
    
    

    if (ringBuffer == nullptr || size <= 0) {
        OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: decoder not ready");
        return -1;
    }
    
    // 从队列获取可用的input buffer index
    uint32_t bufferIndex = 0;
    OH_AVBuffer* buffer = nullptr;

    {
        std::lock_guard<std::mutex> lock(context_->queueMutex);
        if (!context_->inputBufferQueue.empty()) {
            bufferIndex = context_->inputBufferQueue.front();
            context_->inputBufferQueue.pop();
            // 从map获取buffer
            auto it = context_->inputBuffers.find(bufferIndex);
            if (it != context_->inputBuffers.end()) {
                buffer = it->second;
                context_->inputBuffers.erase(it);
            }
        }
    }

    OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: 1");
    
    if (buffer == nullptr) {
        // 输入缓冲区不可用，记录频率以诊断
        static int64_t lastWarnTime = 0;
        int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        if (now - lastWarnTime > 1000) {
            std::lock_guard<std::mutex> lock(context_->queueMutex);
            OH_LOG_WARN(LOG_APP, "[Native] PushFromRingBuffer: no available input buffer, queueSize=%{public}zu, decoderStarted=%{public}d, time=%{public}lld",
                       context_->inputBufferQueue.size(), isStarted_, (long long)now);
            lastWarnTime = now;
        }
        return -2;  // No available buffer
    }
    OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: 2");

    // 获取buffer的内存地址和容量
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_WARN(LOG_APP, "[Native] PushFromRingBuffer: buffer too small (%{public}d < %{public}d), frame may be dropped",
                   bufferSize, size);
        // Put buffer back
        {
            std::lock_guard<std::mutex> lock(context_->queueMutex);
            context_->inputBufferQueue.push(bufferIndex);
            context_->inputBuffers[bufferIndex] = buffer;
        }
        OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: buffer too small");
        return -1;
    }
    OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: 3");

    // 直接从RingBuffer读取到buffer（优化：减少一次memcpy）
    size_t read = ringBuffer->Read(bufferAddr, size);

    if (read < static_cast<size_t>(size)) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushFromRingBuffer: incomplete read");
        // Put buffer back
        {
            std::lock_guard<std::mutex> lock(context_->queueMutex);
            context_->inputBufferQueue.push(bufferIndex);
            context_->inputBuffers[bufferIndex] = buffer;
        }
        
        OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: incomplete read");
        return -1;
    }
    OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: 4");

    // 设置buffer属性
    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = flags;

    OH_AVErrCode attrRet = OH_AVBuffer_SetBufferAttr(buffer, &attr);
    if (attrRet != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushFromRingBuffer: SetBufferAttr failed");
        OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: SetBufferAttr failed");
        return -1;
    }
    OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: 5");

    // 提交buffer到解码器
    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, bufferIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushFromRingBuffer: PushInputBuffer failed: %{public}d", ret);
        // Put buffer back
        {
            std::lock_guard<std::mutex> lock(context_->queueMutex);
            context_->inputBufferQueue.push(bufferIndex);
            context_->inputBuffers[bufferIndex] = buffer;
        }
        OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: PushInputBuffer failed");
        return -1;
    }
    OH_LOG_WARN(LOG_APP, "[测试标志Native] PushFromRingBuffer: 6");

    frameCount_++;
    return 0;
}

int32_t VideoDecoderNative::Stop() {
    if (decoder_ != nullptr && isStarted_) {
        OH_VideoDecoder_Stop(decoder_);
        isStarted_ = false;
        OH_LOG_INFO(LOG_APP, "[Native] Decoder stopped");
    }
    return 0;
}

int32_t VideoDecoderNative::Release() {
    Stop();

    if (decoder_ != nullptr) {
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
    }

    if (window_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(window_);
        window_ = nullptr;
    }

    if (context_ != nullptr) {
        delete context_;
        context_ = nullptr;
    }

    OH_LOG_INFO(LOG_APP, "[Native] Released, total frames: %{public}u", frameCount_);
    return 0;
}

bool VideoDecoderNative::HasAvailableBuffer() const {
    if (context_ == nullptr) return false;

    std::lock_guard<std::mutex> lock(context_->queueMutex);
    return !context_->inputBufferQueue.empty();
}
