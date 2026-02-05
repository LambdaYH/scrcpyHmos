#ifndef VIDEO_DECODER_NATIVE_H
#define VIDEO_DECODER_NATIVE_H

#include <string>
#include <queue>
#include <mutex>
#include "multimedia/player_framework/native_avcodec_videodecoder.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "native_window/external_window.h"

// Forward declaration for RingBuffer
class RingBuffer;

class VideoDecoderNative {
public:
    VideoDecoderNative();
    ~VideoDecoderNative();

    // codecType: "h264", "h265", "av1"
    int32_t Init(const char* codecType, const char* surfaceId, int32_t width, int32_t height);
    int32_t Start();
    int32_t PushData(uint8_t* data, int32_t size, int64_t pts, uint32_t flags);
    int32_t PushFromRingBuffer(RingBuffer* ringBuffer, int32_t size, int64_t pts, uint32_t flags);
    int32_t Stop();
    int32_t Release();
    bool HasAvailableBuffer() const;

private:
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);

    OH_AVCodec* decoder_;
    OHNativeWindow* window_;
    bool isStarted_;
    int32_t width_;
    int32_t height_;
    uint32_t frameCount_;
    std::string codecType_;
    struct DecoderContext* context_;
};

#endif // VIDEO_DECODER_NATIVE_H
