// ScrcpyStreamManager - C++ 层流管理器
// 接管 ADB 流的读取，使用独立线程解析 Scrcpy V2 协议并推送至解码器
#ifndef SCRCPY_STREAM_MANAGER_H
#define SCRCPY_STREAM_MANAGER_H

#include "adb/Adb.h"
#include "video_decoder_native.h"
#include "audio_decoder_native.h"

#include <string>
#include <thread>
#include <atomic>
#include <functional>
#include <mutex>

// 事件回调: type, data (JSON string)
using StreamEventCallback = std::function<void(const std::string& type, const std::string& data)>;

class ScrcpyStreamManager {
public:
    struct Config {
        int32_t videoStreamId = -1;
        int32_t audioStreamId = -1;    // -1 if no audio
        int32_t controlStreamId = -1;
        std::string videoCodec;        // "h264", "h265", "av1"
        std::string audioCodec;        // "opus", "aac", "flac", "raw"
        std::string surfaceId;
        int32_t videoWidth = 0;
        int32_t videoHeight = 0;
        int32_t audioSampleRate = 48000;
        int32_t audioChannelCount = 2;
    };

    ScrcpyStreamManager();
    ~ScrcpyStreamManager();

    // 启动流处理，adb 必须已连接且 stream 已打开
    int32_t start(Adb* adb, const Config& config, StreamEventCallback callback);

    // 向控制流发送数据
    void sendControl(const uint8_t* data, size_t len);

    // 停止所有线程并释放资源
    void stop();

    bool isRunning() const { return running_.load(); }

private:
    // 线程函数
    void videoThreadFunc();
    void audioThreadFunc();
    void controlThreadFunc();

    // 精确读取 N 字节（阻塞），抛出异常表示流关闭或超时
    std::vector<uint8_t> readExact(int32_t streamId, size_t size, int32_t timeoutMs = -1);

    // 辅助：从字节读取大端整数
    static int32_t readInt32BE(const uint8_t* data);
    static int64_t readInt64BE(const uint8_t* data);

    // 发送事件到 ArkTS
    void emitEvent(const std::string& type, const std::string& data = "");

    Adb* adb_ = nullptr;
    Config config_;
    StreamEventCallback eventCallback_;

    VideoDecoderNative* videoDecoder_ = nullptr;
    AudioDecoderNative* audioDecoder_ = nullptr;

    std::thread videoThread_;
    std::thread audioThread_;
    std::thread controlThread_;
    std::atomic<bool> running_{false};
    std::mutex eventMutex_;
};

#endif // SCRCPY_STREAM_MANAGER_H
