#include "video_decoder_native.h"
#include "video_stream_processor.h"
#include <hilog/log.h>
#include <queue>
#include <mutex>
#include <cstring>
#include <chrono>
#include <thread>
#include <map>
#include "multimedia/player_framework/native_avbuffer.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "VideoDecoderNative"
#define LOG_DOMAIN 0x3200

// DecoderContext - 使用 queue（EasyControl 风格）
struct DecoderContext {
    VideoDecoderNative* decoder = nullptr;
    std::queue<uint32_t> inputBufferQueue;  // 只存索引
    std::queue<OH_AVBuffer*> inputBuffers;  // 存 buffer 指针
    std::mutex queueMutex;
    bool isDecFirstFrame = true;
    int32_t outputWidth = 0;
    int32_t outputHeight = 0;
};

VideoDecoderNative::VideoDecoderNative()
    : decoder_(nullptr), window_(nullptr), isStarted_(false),
      width_(0), height_(0), frameCount_(0), codecType_("h264"), context_(nullptr) {
}

VideoDecoderNative::~VideoDecoderNative() {
    Release();
}

void VideoDecoderNative::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "[Native] Decoder error: %{public}d", errorCode);
}

void VideoDecoderNative::OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "[Native] Stream format changed");
}

void VideoDecoderNative::OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    DecoderContext* ctx = static_cast<DecoderContext*>(userData);
    if (ctx == nullptr || buffer == nullptr) return;

    std::lock_guard<std::mutex> lock(ctx->queueMutex);
    ctx->inputBufferQueue.push(index);
    ctx->inputBuffers.push(buffer);
    ctx->isDecFirstFrame = false;
}

void VideoDecoderNative::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    DecoderContext* ctx = static_cast<DecoderContext*>(userData);
    if (ctx == nullptr) return;

    if (ctx->isDecFirstFrame) {
        OH_AVFormat* format = OH_VideoDecoder_GetOutputDescription(codec);
        if (format != nullptr) {
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &ctx->outputWidth);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &ctx->outputHeight);
            OH_AVFormat_Destroy(format);
        }
        ctx->isDecFirstFrame = false;
    }

    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK) {
        OH_VideoDecoder_RenderOutputBuffer(codec, index);
    } else {
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
    }
}

int32_t VideoDecoderNative::Init(const char* codecType, const char* surfaceId, int32_t width, int32_t height) {
    OH_LOG_INFO(LOG_APP, "[Native] Init: codec=%{public}s, size=%{public}dx%{public}d",
                codecType, width, height);

    width_ = width;
    height_ = height;
    codecType_ = codecType ? codecType : "h264";

    const char* mimeType = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    if (strcmp(codecType_.c_str(), "h265") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
    } else if (strcmp(codecType_.c_str(), "av1") == 0) {
        mimeType = "video/av01";
    }

    decoder_ = OH_VideoDecoder_CreateByMime(mimeType);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create decoder failed");
        return -1;
    }

    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, 60);
    OH_AVFormat_SetIntValue(format, "video_enable_low_latency", 1);

    int32_t ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Configure failed: %{public}d", ret);
        return ret;
    }

    uint64_t surfaceIdNum = std::stoull(surfaceId);
    int32_t windowRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceIdNum, &window_);
    if (windowRet != 0 || window_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create NativeWindow failed");
        return -1;
    }

    ret = OH_VideoDecoder_SetSurface(decoder_, window_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] SetSurface failed");
        return ret;
    }

    context_ = new DecoderContext();
    context_->decoder = this;

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;

    ret = OH_VideoDecoder_RegisterCallback(decoder_, callback, context_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] RegisterCallback failed");
        delete context_;
        context_ = nullptr;
        return ret;
    }

    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Prepare failed");
        return ret;
    }

    OH_LOG_INFO(LOG_APP, "[Native] Init complete");
    return 0;
}

int32_t VideoDecoderNative::Start() {
    if (decoder_ == nullptr) return -1;

    int32_t ret = OH_VideoDecoder_Start(decoder_);
    if (ret == AV_ERR_OK) {
        isStarted_ = true;
        OH_LOG_INFO(LOG_APP, "[Native] Started");

        int waitCount = 0;
        while (waitCount < 200) {
            {
                std::lock_guard<std::mutex> lock(context_->queueMutex);
                if (!context_->inputBufferQueue.empty()) {
                    return ret;
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            waitCount++;
        }
        OH_LOG_WARN(LOG_APP, "[Native] Timeout waiting for buffers");
    }
    return ret;
}

int32_t VideoDecoderNative::PushData(uint8_t* data, int32_t size, int64_t pts, uint32_t flags) {
    if (!isStarted_ || decoder_ == nullptr || context_ == nullptr) {
        return -1;
    }

    uint32_t bufferIndex = 0;
    OH_AVBuffer* buffer = nullptr;

    {
        std::lock_guard<std::mutex> lock(context_->queueMutex);
        if (context_->inputBufferQueue.empty()) {
            return -2;
        }
        bufferIndex = context_->inputBufferQueue.front();
        context_->inputBufferQueue.pop();
        buffer = context_->inputBuffers.front();
        context_->inputBuffers.pop();
    }

    if (buffer == nullptr) return -2;

    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_ERROR(LOG_APP, "[Native] Buffer too small: %{public}d < %{public}d", bufferSize, size);
        return -1;
    }

    memcpy(bufferAddr, data, size);

    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = flags;

    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, bufferIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushInputBuffer failed: %{public}d", ret);
        return -1;
    }

    frameCount_++;
    return 0;
}

int32_t VideoDecoderNative::PushFromRingBuffer(RingBuffer* ringBuffer, int32_t size, int64_t pts, uint32_t flags) {
    // RingBuffer 已废弃，不再使用
    return -1;
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
