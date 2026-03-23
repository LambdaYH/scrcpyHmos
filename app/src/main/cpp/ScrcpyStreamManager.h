// ScrcpyStreamManager - C++ 层流管理器
// 接管 ADB 流的读取，使用独立线程解析 Scrcpy V2 协议并推送至解码器
#ifndef SCRCPY_STREAM_MANAGER_H
#define SCRCPY_STREAM_MANAGER_H

#include "adb/Adb.h"
#include "adb/AdbChannel.h"
#include "video_decoder_native.h"
#include "audio_decoder_native.h"

#include <cstdint>
#include <string>
#include <thread>
#include <atomic>
#include <functional>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <unordered_map>
#include <vector>

// 事件回调: type, data (JSON string)
using StreamEventCallback = std::function<void(const std::string& type, const std::string& data)>;

class ScrcpyStreamManager {
public:
    struct Config {
        int32_t videoStreamId = -1;
        int32_t audioStreamId = -1;    // -1 if no audio
        int32_t controlStreamId = -1;
        std::string surfaceId;
        int32_t audioSampleRate = 48000;
        int32_t audioChannelCount = 2;
        bool reverse = false;
        bool expectVideo = true;
        bool expectAudio = false;
        bool expectControl = true;
        bool sendDummyByte = true;
    };

    ScrcpyStreamManager();
    ~ScrcpyStreamManager();

    // 启动流处理，adb 必须已连接且 stream 已打开
    int32_t start(Adb* adb, const Config& config, StreamEventCallback callback);
    int32_t startReverse(Adb* adb, const Config& config, StreamEventCallback callback);

    // 向控制流发送数据
    bool sendControl(const uint8_t* data, size_t len);

    int32_t getVideoWidth() const { return videoWidth_.load(); }
    int32_t getVideoHeight() const { return videoHeight_.load(); }

    // 停止所有线程并释放资源
    void stop();

    bool isRunning() const { return running_.load(); }

private:
    // 线程函数
    void videoThreadFunc();
    void audioThreadFunc();
    void controlThreadFunc();
    void controlSendThreadFunc();
    void controlAdbToProxyThreadFunc();
    void videoProxyThreadFunc();
    void audioProxyThreadFunc();
    void acceptThreadFunc();

    // 精确读取 N 字节（阻塞），抛出异常表示流关闭或超时
    std::vector<uint8_t> readExact(AdbChannel* channel, size_t size, int32_t timeoutMs = -1);
    void readExactToBuffer(AdbChannel* channel, uint8_t* dest, size_t size, int32_t timeoutMs = -1);
    std::vector<uint8_t> readExact(AdbStream* stream, size_t size, int32_t timeoutMs = -1);
    void readExactToBuffer(AdbStream* stream, uint8_t* dest, size_t size, int32_t timeoutMs = -1);
    int32_t createLocalTunnel(AdbChannel*& channel, int& proxyFd);
    int32_t createTcpListener(uint16_t& port);
    void closeLocalTunnels();
    void releaseLocalTunnels();
    void closeListener();
    static void closeFd(int& fd);

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
    AdbStream* videoStream_ = nullptr;
    AdbStream* audioStream_ = nullptr;
    AdbStream* controlStream_ = nullptr;
    AdbChannel* videoChannel_ = nullptr;
    AdbChannel* audioChannel_ = nullptr;
    AdbChannel* controlChannel_ = nullptr;

    int videoProxyFd_ = -1;
    int audioProxyFd_ = -1;
    int controlProxyFd_ = -1;
    int listenFd_ = -1;

    std::thread videoThread_;
    std::thread audioThread_;
    std::thread controlThread_;
    std::thread controlAdbToProxyThread_;
    std::thread videoProxyThread_;
    std::thread audioProxyThread_;
    std::thread acceptThread_;
    std::thread controlSendThread_;
    std::atomic<bool> running_{false};
    std::atomic<int32_t> videoWidth_{0};
    std::atomic<int32_t> videoHeight_{0};
    std::mutex eventMutex_;
    std::mutex controlProxyFdMutex_;
    std::mutex controlSendQueueMutex_;
    std::condition_variable controlSendQueueCv_;
    std::deque<std::vector<uint8_t>> controlSendQueue_;
    std::deque<int64_t> controlPendingMoveOrder_;
    std::unordered_map<int64_t, std::vector<uint8_t>> controlPendingMovePackets_;
};

#endif // SCRCPY_STREAM_MANAGER_H
