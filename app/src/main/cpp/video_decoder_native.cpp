#include "video_decoder_native.h"
#include <hilog/log.h>
#include <queue>
#include <mutex>
#include <cstring>  // for memcpy, strcmp
#include "multimedia/player_framework/native_avbuffer.h"  // for OH_AVBuffer_SetBufferAttr

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
    std::lock_guard<std::mutex> lock(context->queueMutex);
    if (buffer != nullptr) {
        context->inputBufferQueue.push(index);
        context->inputBuffers.push(buffer);  // 保存buffer指针
    }
    context->waitForFirstBuffer = false;
    // OH_LOG_DEBUG(LOG_APP, "[Native] OnNeedInputBuffer: index=%{public}u, buffer=%{public}s, queueSize=%{public}zu",
    //             index, buffer ? "valid" : "null", context->inputBufferQueue.size());
}

void VideoDecoderNative::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    // 获取buffer属性获取更多信息
    OH_AVCodecBufferAttr attr;
    OH_AVErrCode ret = OH_AVBuffer_GetBufferAttr(buffer, &attr);
//    if (ret == AV_ERR_OK) {
//        OH_LOG_DEBUG(LOG_APP, "[Native] OnNewOutputBuffer: index=%{public}u, size=%{public}d, pts=%{public}lld",
//                    index, attr.size, (long long)attr.pts);
//    } else {
//        OH_LOG_DEBUG(LOG_APP, "[Native] OnNewOutputBuffer: index=%{public}u", index);
//    }

    // 渲染到Surface
    OH_AVErrCode renderRet = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (renderRet != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] RenderOutputBuffer failed: %{public}d", renderRet);
    }

    // 释放输出buffer (HarmonyOS只需要2个参数)
    OH_VideoDecoder_FreeOutputBuffer(codec, index);
}

int32_t VideoDecoderNative::Init(const char* codecType, const char* surfaceId, int32_t width, int32_t height) {
    OH_LOG_DEBUG(LOG_APP, "[Native] Init: codec=%{public}s, size=%{public}dx%{public}d",
                codecType, width, height);

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
        OH_LOG_ERROR(LOG_APP, "[Native] Create decoder failed, codec=%{public}s", mimeType);
        return -1;
    }

    // 配置解码器
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);

    int32_t ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Configure failed: %{public}d", ret);
        return ret;
    }

    // 从surfaceId获取window
    uint64_t surfaceIdNum = std::stoull(surfaceId);
    int32_t windowRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceIdNum, &window_);
    if (windowRet != 0 || window_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create window failed: %{public}d", windowRet);
        return -1;
    }

    // 设置输出Surface
    ret = OH_VideoDecoder_SetSurface(decoder_, window_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] SetSurface failed: %{public}d", ret);
        return ret;
    }

    // 设置回调
    context_ = new DecoderContext();
    context_->decoder = this;
    context_->waitForFirstBuffer = true;

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;

    ret = OH_VideoDecoder_RegisterCallback(decoder_, callback, context_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] RegisterCallback failed: %{public}d", ret);
        delete context_;
        context_ = nullptr;
        return ret;
    }

    // 准备解码器
    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Prepare failed: %{public}d", ret);
        return ret;
    }

    OH_LOG_INFO(LOG_APP, "[Native] Init success with codec %{public}s, waiting for input buffer callbacks...", codecType);
    return 0;
}

int32_t VideoDecoderNative::Start() {
    if (decoder_ == nullptr) {
        return -1;
    }

    int32_t ret = OH_VideoDecoder_Start(decoder_);
    if (ret == AV_ERR_OK) {
        isStarted_ = true;
        OH_LOG_INFO(LOG_APP, "[Native] Decoder started");
    } else {
        OH_LOG_ERROR(LOG_APP, "[Native] Start failed: %{public}d", ret);
    }
    return ret;
}

int32_t VideoDecoderNative::PushData(uint8_t* data, int32_t size, int64_t pts) {
    if (!isStarted_ || decoder_ == nullptr || context_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushData: decoder not ready, started=%{public}d, decoder=%{public}s, context=%{public}s",
                     isStarted_, decoder_ ? "valid" : "null", context_ ? "valid" : "null");
        return -1;
    }

    // 从队列获取可用的input buffer index
    uint32_t bufferIndex = 0;
    bool hasBuffer = false;

    {
        std::lock_guard<std::mutex> lock(context_->queueMutex);
        if (!context_->inputBufferQueue.empty()) {
            bufferIndex = context_->inputBufferQueue.front();
            context_->inputBufferQueue.pop();
            hasBuffer = true;
        }
    }

    if (!hasBuffer) {
        OH_LOG_DEBUG(LOG_APP, "[Native] PushData: no available input buffer");
        return -2;  // 表示暂时没有可用buffer
    }

    // 从队列获取buffer
    OH_AVBuffer* buffer = nullptr;
    {
        std::lock_guard<std::mutex> lock(context_->queueMutex);
        if (!context_->inputBuffers.empty()) {
            buffer = context_->inputBuffers.front();
            context_->inputBuffers.pop();
        } else {
            OH_LOG_ERROR(LOG_APP, "[Native] PushData: no buffer available");
            return -1;
        }
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
    // 对于CSD数据（SPS/PPS），设置为codec config flag；对于普通帧数据，设置为0
    attr.flags = (frameCount_ < 2) ? OH_AVCodecBufferFlags::AVCODEC_BUFFER_FLAGS_CODEC_DATA : 0;

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
            context_->inputBuffers.push(buffer);
        }
        return -1;
    }

    // buffer已经提交，不需要清理

    frameCount_++;
    // if (frameCount_ % 30 == 0) {
    //    OH_LOG_DEBUG(LOG_APP, "[Native] Pushed %{public}u frames (size=%{public}d)", frameCount_, size);
    // }

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
