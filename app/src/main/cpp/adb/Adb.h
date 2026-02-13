// Adb - 完整的ADB实现
// 参考 Adb.ets 实现
// 核心ADB协议处理类，使用fd进行I/O
#ifndef ADB_H
#define ADB_H

#include "AdbChannel.h"
#include "AdbProtocol.h"
#include "AdbKeyPair.h"

#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>
#include <functional>

// 进度回调函数类型
using ProcessCallback = std::function<void(int progress)>;

// 内部流数据结构 (替代ArkTS的BufferStream)
struct AdbStream {
    int32_t localId = 0;
    int32_t remoteId = 0;
    bool canMultipleSend = false;
    bool closed = false;
    bool canWrite = false;

    // 读缓冲区
    std::vector<uint8_t> readBuffer;
    std::mutex readMutex;
    std::condition_variable readCv;

    // 关闭前的累积数据
    std::vector<uint8_t> closedData;
};

// ADB主类 - 完全参考Adb.ets
class Adb {
public:
    ~Adb();

    // 通过fd创建并连接ADB实例
    // fd由ArkTS传入，不在C++中创建网络连接
    static Adb* create(int fd);

    // ADB认证连接
    // 如果需要认证，needAuth会被设置为true，此时需要ArkTS弹出授权对话框
    // 返回值: 0=成功, 1=需要用户授权(已发送公钥), -1=失败
    int connect(AdbKeyPair& keyPair);

    // 执行ADB命令
    std::string runAdbCmd(const std::string& cmd);

    // 推送文件
    void pushFile(const uint8_t* fileData, size_t fileLen,
                  const std::string& remotePath, ProcessCallback callback = nullptr);

    // 切换到TCP模式
    std::string restartOnTcpip(int port);

    // TCP端口转发 - 返回stream id
    int32_t tcpForward(int port);

    // 本地Socket转发 - 返回stream id
    int32_t localSocketForward(const std::string& socketName);

    // 获取Shell流 - 返回stream id
    int32_t getShell();

    // 从流中读取数据
    std::vector<uint8_t> streamRead(int32_t streamId, size_t size);

    // 向流中写入数据
    void streamWrite(int32_t streamId, const uint8_t* data, size_t len);

    // 关闭流
    void streamClose(int32_t streamId);

    // 流是否已关闭
    bool isStreamClosed(int32_t streamId);

    // 读取流关闭前的全部数据
    std::vector<uint8_t> streamReadAllBeforeClose(int32_t streamId);

    // 关闭ADB连接
    void close();

    // 是否已关闭
    bool isAdbClosed() const { return isClosed_.load(); }

    // 获取最大数据大小
    uint32_t getMaxData() const { return maxData_; }

private:
    Adb(AdbChannel* channel);

    // 后台消息处理线程
    void handleInLoop();

    // 打开一个流
    int32_t open(const std::string& destination, bool canMultipleSend);

    // 等待/通知机制
    void waitForNotify();
    void notifyAll();

    // 写入channel
    void writeToChannel(const std::vector<uint8_t>& data);

    // 创建新的流
    AdbStream* createNewStream(int32_t localId, int32_t remoteId, bool canMultipleSend);

    // 向流推送接收到的数据
    void pushToStream(AdbStream* stream, const uint8_t* data, size_t len);

    // 向流的底层channel写入数据（分块）
    void streamWriteRaw(AdbStream* stream, const uint8_t* data, size_t len);

    AdbChannel* channel_ = nullptr;
    std::atomic<bool> isClosed_{false};
    std::atomic<bool> handleInRunning_{false};
    int32_t localIdPool_ = 1;
    uint32_t maxData_ = AdbProtocol::CONNECT_MAXDATA;

    // 流管理
    std::map<int32_t, AdbStream*> connectionStreams_;
    std::map<int32_t, AdbStream*> openStreams_;
    std::mutex streamsMutex_;

    // 等待通知
    std::mutex waitMutex_;
    std::condition_variable waitCv_;

    // channel写入锁
    std::mutex channelWriteMutex_;

    // 后台处理线程
    std::thread handleInThread_;
};

#endif // ADB_H
