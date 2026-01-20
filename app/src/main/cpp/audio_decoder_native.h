#ifndef AUDIO_DECODER_NATIVE_H
#define AUDIO_DECODER_NATIVE_H

#include <string>
#include <queue>
#include <mutex>
#include <condition_variable>
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "ohaudio/native_audiorenderer.h"

struct AudioDecoderContext {
    std::queue<uint32_t> inputBufferQueue;
    std::queue<OH_AVBuffer*> inputBuffers;
    std::queue<OH_AVBuffer*> outputBuffers;
    std::queue<uint32_t> outputBufferIndices;
    std::mutex inputMutex;
    std::mutex outputMutex;
    std::condition_variable outputCond;
    class AudioDecoderNative* decoder;
    bool waitForFirstBuffer;
};

class AudioDecoderNative {
public:
    AudioDecoderNative();
    ~AudioDecoderNative();

    // codecType: "opus", "aac", "raw", "flac"
    int32_t Init(const char* codecType, int32_t sampleRate, int32_t channelCount);
    int32_t Start();
    int32_t PushData(uint8_t* data, int32_t size, int64_t pts);
    int32_t Stop();
    int32_t Release();

    // 获取解码后的PCM数据并播放
    void ProcessOutputBuffers();

private:
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);

    // 音频渲染回调
    static int32_t OnAudioRendererWriteData(OH_AudioRenderer* renderer,
                                            void* userData,
                                            void* buffer,
                                            int32_t length);

    int32_t InitAudioRenderer();

    OH_AVCodec* decoder_;
    OH_AudioRenderer* renderer_;
    OH_AudioStreamBuilder* builder_;
    bool isStarted_;
    bool isRaw_;  // raw格式不需要解码
    int32_t sampleRate_;
    int32_t channelCount_;
    uint32_t frameCount_;
    std::string codecType_;
    AudioDecoderContext* context_;

    // PCM缓冲区（用于RAW模式或解码后数据）
    std::queue<std::vector<uint8_t>> pcmQueue_;
    std::mutex pcmMutex_;
};

#endif // AUDIO_DECODER_NATIVE_H
