#ifndef VIDEO_DECODER_NATIVE_H
#define VIDEO_DECODER_NATIVE_H

#include <string>
#include <queue>
#include <mutex>
#include <map>
#include "multimedia/player_framework/native_avcodec_videodecoder.h"
#include "native_window/external_window.h"

struct DecoderContext {
    std::queue<uint32_t> inputBufferQueue;
    std::queue<OH_AVBuffer*> inputBuffers;  // 保存buffer指针队列
    std::mutex queueMutex;
    class VideoDecoderNative* decoder;
    bool waitForFirstBuffer;  // 标记是否在等待第一个buffer
};

class VideoDecoderNative {
public:
    VideoDecoderNative();
    ~VideoDecoderNative();
    
    int32_t Init(bool useH265, const char* surfaceId, int32_t width, int32_t height);
    int32_t Start();
    int32_t PushData(uint8_t* data, int32_t size, int64_t pts);
    int32_t Stop();
    int32_t Release();
    
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
    DecoderContext* context_;  // 添加上下文指针访问
};

#endif // VIDEO_DECODER_NATIVE_H
