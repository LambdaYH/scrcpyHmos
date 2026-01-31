#include "audio_decoder_native.h"
#include "video_stream_processor.h"  // Include for RingBuffer access
#include <hilog/log.h>
#include <cstring>
#include <thread>
#include <ohaudio/native_audiostreambuilder.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "AudioDecoderNative"
#define LOG_DOMAIN 0x3200

AudioDecoderNative::AudioDecoderNative()
    : decoder_(nullptr), renderer_(nullptr), builder_(nullptr),
      isStarted_(false), isRaw_(false),
      sampleRate_(48000), channelCount_(2), frameCount_(0),
      codecType_("opus"), context_(nullptr) {
}

AudioDecoderNative::~AudioDecoderNative() {
    Release();
}

void AudioDecoderNative::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "[AudioNative] Decoder error: %{public}d", errorCode);
}

void AudioDecoderNative::OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "[AudioNative] Stream format changed");
}

void AudioDecoderNative::OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    AudioDecoderContext* context = static_cast<AudioDecoderContext*>(userData);
    std::lock_guard<std::mutex> lock(context->inputMutex);
    if (buffer != nullptr) {
        context->inputBufferQueue.push(index);
        context->inputBuffers.push(buffer);
    }
    context->waitForFirstBuffer = false;
    context->waitForFirstBuffer = false;
    // OH_LOG_DEBUG(LOG_APP, "[AudioNative] OnNeedInputBuffer: index=%{public}u, queueSize=%{public}zu",
    //             index, context->inputBufferQueue.size());
}

void AudioDecoderNative::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    AudioDecoderContext* context = static_cast<AudioDecoderContext*>(userData);

    if (buffer == nullptr) {
        return;
    }

    // 获取解码后的PCM数据
    OH_AVCodecBufferAttr attr;
    OH_AVBuffer_GetBufferAttr(buffer, &attr);

    if (attr.size > 0) {
        uint8_t* data = OH_AVBuffer_GetAddr(buffer);

        // 使用预分配的buffer池（避免每帧vector分配）
        std::lock_guard<std::mutex> lock(context->decoder->pcmMutex_);

        // 如果池中有可用的buffer，使用它
        if (context->decoder->pcmPool_.size() < AudioDecoderNative::PCM_POOL_SIZE) {
            std::array<uint8_t, PCM_BUFFER_SIZE> pcmBuffer{};
            size_t copySize = std::min(static_cast<size_t>(attr.size), AudioDecoderNative::PCM_BUFFER_SIZE);
            memcpy(pcmBuffer.data(), data, copySize);
            context->decoder->pcmPool_.push(std::move(pcmBuffer));
            context->decoder->pcmPoolSizes_.push(copySize);
            context->decoder->pcmPoolOffsets_.push({0, copySize});
        } else {
            // 池满了，丢弃这帧（或者可以扩展池大小）
            OH_LOG_WARN(LOG_APP, "[AudioNative] PCM pool full, dropping frame");
        }

        // OH_LOG_DEBUG(LOG_APP, "[AudioNative] OnNewOutputBuffer: size=%{public}d, pts=%{public}lld",
        //             attr.size, (long long)attr.pts);
    }

    // 释放输出buffer
    OH_AudioCodec_FreeOutputBuffer(codec, index);
}

int32_t AudioDecoderNative::OnAudioRendererWriteData(OH_AudioRenderer* renderer,
                                                      void* userData,
                                                      void* buffer,
                                                      int32_t length) {
    AudioDecoderNative* self = static_cast<AudioDecoderNative*>(userData);

    std::lock_guard<std::mutex> lock(self->pcmMutex_);

    int32_t written = 0;
    uint8_t* outBuffer = static_cast<uint8_t*>(buffer);

    // 使用预分配的buffer池
    while (written < length && !self->pcmPool_.empty()) {
        std::array<uint8_t, PCM_BUFFER_SIZE>& front = self->pcmPool_.front();
        size_t frontSize = self->pcmPoolSizes_.front();
        auto& offsetPair = self->pcmPoolOffsets_.front();

        size_t offset = offsetPair.first;
        size_t remaining = offsetPair.second;

        int32_t toCopy = std::min(static_cast<int32_t>(remaining), length - written);
        memcpy(outBuffer + written, front.data() + offset, toCopy);
        written += toCopy;

        offsetPair.first += toCopy;
        offsetPair.second -= toCopy;

        if (offsetPair.second == 0) {
            self->pcmPool_.pop();
            self->pcmPoolSizes_.pop();
            self->pcmPoolOffsets_.pop();
        }
    }

    // 如果没有足够数据，填充静音
    if (written < length) {
        memset(outBuffer + written, 0, length - written);
    }

    return length;
}

int32_t AudioDecoderNative::InitAudioRenderer() {
    // 创建音频流构建器
    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER);
    if (result != AUDIOSTREAM_SUCCESS || builder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Create AudioStreamBuilder failed: %{public}d", result);
        return -1;
    }

    // 设置采样率
    OH_AudioStreamBuilder_SetSamplingRate(builder_, sampleRate_);

    // 设置声道数
    OH_AudioStreamBuilder_SetChannelCount(builder_, channelCount_);

    // 设置采样格式为S16LE
    OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);

    // 设置编码类型为PCM
    OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);

    // 设置渲染信息
    OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_MUSIC);

    // 设置回调
    OH_AudioRenderer_Callbacks callbacks;
    callbacks.OH_AudioRenderer_OnWriteData = OnAudioRendererWriteData;
    OH_AudioStreamBuilder_SetRendererCallback(builder_, callbacks, this);

    // 创建渲染器
    result = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (result != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Create AudioRenderer failed: %{public}d", result);
        return -1;
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] AudioRenderer created: sampleRate=%{public}d, channels=%{public}d",
                sampleRate_, channelCount_);
    return 0;
}

int32_t AudioDecoderNative::Init(const char* codecType, int32_t sampleRate, int32_t channelCount) {
    OH_LOG_DEBUG(LOG_APP, "[AudioNative] Init: codec=%{public}s, sampleRate=%{public}d, channels=%{public}d",
                codecType, sampleRate, channelCount);

    sampleRate_ = sampleRate;
    channelCount_ = channelCount;
    codecType_ = codecType ? codecType : "opus";

    // RAW格式不需要解码器，直接播放PCM
    if (strcmp(codecType_.c_str(), "raw") == 0) {
        isRaw_ = true;
        OH_LOG_INFO(LOG_APP, "[AudioNative] RAW mode, no decoder needed");

        // 只初始化音频渲染器
        int32_t ret = InitAudioRenderer();
        if (ret != 0) {
            return ret;
        }

        return 0;
    }

    isRaw_ = false;

    // 根据codecType选择对应的MIME类型
    const char* mimeType = nullptr;
    if (strcmp(codecType_.c_str(), "opus") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_OPUS;
    } else if (strcmp(codecType_.c_str(), "aac") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_AAC;
    } else if (strcmp(codecType_.c_str(), "flac") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_FLAC;
    } else {
        OH_LOG_WARN(LOG_APP, "[AudioNative] Unknown codec type: %{public}s, fallback to OPUS", codecType);
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_OPUS;
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] Creating decoder with MIME: %{public}s", mimeType);

    // 创建解码器
    decoder_ = OH_AudioCodec_CreateByMime(mimeType, false);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Create decoder failed, codec=%{public}s", mimeType);
        return -1;
    }

    // 配置解码器
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, sampleRate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, channelCount);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, 1);  // SAMPLE_S16LE
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_CHANNEL_LAYOUT,
                             channelCount == 2 ? 3 : 4);  // STEREO or MONO

    int32_t ret = OH_AudioCodec_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);

    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Configure failed: %{public}d", ret);
        return ret;
    }

    // 设置回调
    context_ = new AudioDecoderContext();
    context_->decoder = this;
    context_->waitForFirstBuffer = true;

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;

    ret = OH_AudioCodec_RegisterCallback(decoder_, callback, context_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] RegisterCallback failed: %{public}d", ret);
        delete context_;
        context_ = nullptr;
        return ret;
    }

    // 准备解码器
    ret = OH_AudioCodec_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Prepare failed: %{public}d", ret);
        return ret;
    }

    // 初始化音频渲染器
    ret = InitAudioRenderer();
    if (ret != 0) {
        return ret;
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] Init success with codec %{public}s", codecType);
    return 0;
}

int32_t AudioDecoderNative::Start() {
    // 启动音频渲染器
    if (renderer_ != nullptr) {
        OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_ERROR(LOG_APP, "[AudioNative] Start renderer failed: %{public}d", result);
            return -1;
        }
    }

    // 如果不是RAW模式，启动解码器
    if (!isRaw_ && decoder_ != nullptr) {
        int32_t ret = OH_AudioCodec_Start(decoder_);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "[AudioNative] Start decoder failed: %{public}d", ret);
            return ret;
        }
    }

    isStarted_ = true;
    OH_LOG_INFO(LOG_APP, "[AudioNative] Started (raw=%{public}d)", isRaw_);
    return 0;
}

int32_t AudioDecoderNative::PushData(uint8_t* data, int32_t size, int64_t pts) {
    if (!isStarted_) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushData: not started");
        return -1;
    }

    // RAW模式直接放入PCM队列（使用buffer池）
    if (isRaw_) {
        std::lock_guard<std::mutex> lock(pcmMutex_);

        if (pcmPool_.size() < PCM_POOL_SIZE) {
            std::array<uint8_t, PCM_BUFFER_SIZE> pcmBuffer{};
            size_t copySize = std::min(static_cast<size_t>(size), PCM_BUFFER_SIZE);
            memcpy(pcmBuffer.data(), data, copySize);
            pcmPool_.push(std::move(pcmBuffer));
            pcmPoolSizes_.push(copySize);
            pcmPoolOffsets_.push({0, copySize});
        }
        frameCount_++;
        return 0;
    }

    // 解码模式
    if (decoder_ == nullptr || context_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushData: decoder not ready");
        return -1;
    }

    // 获取输入buffer
    uint32_t bufferIndex = 0;
    OH_AVBuffer* buffer = nullptr;

    {
        std::lock_guard<std::mutex> lock(context_->inputMutex);
        if (context_->inputBufferQueue.empty() || context_->inputBuffers.empty()) {
            OH_LOG_DEBUG(LOG_APP, "[AudioNative] PushData: no available input buffer");
            return -2;
        }
        bufferIndex = context_->inputBufferQueue.front();
        context_->inputBufferQueue.pop();
        buffer = context_->inputBuffers.front();
        context_->inputBuffers.pop();
    }

    // 复制数据
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushData: buffer too small");
        return -1;
    }

    memcpy(bufferAddr, data, size);

    // 设置属性
    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = 0;

    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    // 提交
    int32_t ret = OH_AudioCodec_PushInputBuffer(decoder_, bufferIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushInputBuffer failed: %{public}d", ret);
        return -1;
    }

    frameCount_++;
//    if (frameCount_ % 100 == 0) {
//        OH_LOG_DEBUG(LOG_APP, "[AudioNative] Pushed %{public}u audio frames", frameCount_);
//    }

    return 0;
}

int32_t AudioDecoderNative::PushFromRingBuffer(RingBuffer* ringBuffer, int32_t size, int64_t pts, uint32_t flags) {
    if (!isStarted_) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushFromRingBuffer: not started");
        return -1;
    }

    // RAW模式直接放入PCM队列（使用buffer池）
    if (isRaw_) {
        std::lock_guard<std::mutex> lock(pcmMutex_);

        if (pcmPool_.size() < PCM_POOL_SIZE) {
            std::array<uint8_t, PCM_BUFFER_SIZE> pcmBuffer{};
            size_t copySize = std::min(static_cast<size_t>(size), PCM_BUFFER_SIZE);
            size_t read = ringBuffer->Read(pcmBuffer.data(), copySize);
            pcmPool_.push(std::move(pcmBuffer));
            pcmPoolSizes_.push(read);
            pcmPoolOffsets_.push({0, read});
        }
        frameCount_++;
        return 0;
    }

    // 解码模式
    if (decoder_ == nullptr || context_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushFromRingBuffer: decoder not ready");
        return -1;
    }

    // 获取输入buffer
    uint32_t bufferIndex = 0;
    OH_AVBuffer* buffer = nullptr;

    {
        std::lock_guard<std::mutex> lock(context_->inputMutex);
        if (context_->inputBufferQueue.empty() || context_->inputBuffers.empty()) {
            return -2;  // No available buffer
        }
        bufferIndex = context_->inputBufferQueue.front();
        context_->inputBufferQueue.pop();
        buffer = context_->inputBuffers.front();
        context_->inputBuffers.pop();
    }

    // 获取buffer的内存地址和容量
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushFromRingBuffer: buffer too small");
        // Put buffer back
        {
            std::lock_guard<std::mutex> lock(context_->inputMutex);
            context_->inputBufferQueue.push(bufferIndex);
            context_->inputBuffers.push(buffer);
        }
        return -1;
    }

    // 直接从RingBuffer读取到buffer（优化：减少一次memcpy）
    size_t read = ringBuffer->Read(bufferAddr, size);

    if (read < static_cast<size_t>(size)) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushFromRingBuffer: incomplete read");
        // Put buffer back
        {
            std::lock_guard<std::mutex> lock(context_->inputMutex);
            context_->inputBufferQueue.push(bufferIndex);
            context_->inputBuffers.push(buffer);
        }
        return -1;
    }

    // 设置属性
    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = 0;

    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    // 提交
    int32_t ret = OH_AudioCodec_PushInputBuffer(decoder_, bufferIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushFromRingBuffer: PushInputBuffer failed: %{public}d", ret);
        // Put buffer back
        {
            std::lock_guard<std::mutex> lock(context_->inputMutex);
            context_->inputBufferQueue.push(bufferIndex);
            context_->inputBuffers.push(buffer);
        }
        return -1;
    }

    frameCount_++;
    return 0;
}

int32_t AudioDecoderNative::Stop() {
    if (!isStarted_) {
        return 0;
    }

    isStarted_ = false;

    // 停止渲染器
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Stop(renderer_);
    }

    // 停止解码器
    if (!isRaw_ && decoder_ != nullptr) {
        OH_AudioCodec_Stop(decoder_);
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] Stopped");
    return 0;
}

int32_t AudioDecoderNative::Release() {
    Stop();

    if (decoder_ != nullptr) {
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
    }

    if (renderer_ != nullptr) {
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }

    if (builder_ != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }

    if (context_ != nullptr) {
        delete context_;
        context_ = nullptr;
    }

    // 清空PCM队列和buffer池
    {
        std::lock_guard<std::mutex> lock(pcmMutex_);
        while (!pcmQueue_.empty()) {
            pcmQueue_.pop();
        }
        // 清空buffer池
        while (!pcmPool_.empty()) {
            pcmPool_.pop();
            pcmPoolSizes_.pop();
            pcmPoolOffsets_.pop();
        }
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] Released, total frames: %{public}u", frameCount_);
    return 0;
}

void AudioDecoderNative::ProcessOutputBuffers() {
    // 输出buffer已在回调中处理
}
