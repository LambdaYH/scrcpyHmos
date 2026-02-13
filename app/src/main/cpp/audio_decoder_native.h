#ifndef AUDIO_DECODER_NATIVE_H
#define AUDIO_DECODER_NATIVE_H

#include <string>
#include <queue>
#include <mutex>
#include <array>
#include "multimedia/player_framework/native_avcodec_audiocodec.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "ohaudio/native_audiorenderer.h"



struct PcmFrame {
    std::array<uint8_t, 32 * 1024> data{};
    size_t size = 0;
    size_t offset = 0;
    size_t remaining() const { return size - offset; }
};

class AudioDecoderNative {
public:
    AudioDecoderNative();
    ~AudioDecoderNative();

    // codecType: "opus", "aac", "raw", "flac"
    int32_t Init(const char* codecType, int32_t sampleRate, int32_t channelCount);
    int32_t Start();
    int32_t PushData(uint8_t* data, int32_t size, int64_t pts);

    // Zero-Copy API
    int32_t GetInputBuffer(uint32_t* outIndex, uint8_t** outData, int32_t* outCapacity, void** outHandle, int32_t timeoutMs = 10);
    int32_t SubmitInputBuffer(uint32_t index, void* handle, int64_t pts, int32_t size, uint32_t flags);

    int32_t Stop();
    int32_t Release();
    bool HasAvailableBuffer() const;

private:
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);

    static int32_t OnAudioRendererWriteData(OH_AudioRenderer* renderer,
                                            void* userData,
                                            void* buffer,
                                            int32_t length);

    int32_t InitAudioRenderer();

    OH_AVCodec* decoder_;
    OH_AudioRenderer* renderer_;
    OH_AudioStreamBuilder* builder_;
    bool isStarted_;
    bool isRaw_;
    int32_t sampleRate_;
    int32_t channelCount_;
    uint32_t frameCount_;
    std::string codecType_;

    struct AudioDecoderContext* context_;
    static constexpr size_t PCM_POOL_SIZE = 32;
    std::queue<PcmFrame> pcmPool_;
    std::mutex pcmMutex_;
};

#endif // AUDIO_DECODER_NATIVE_H
