// LocalSocketChannel - 基于本地 socket fd 的通道实现
#ifndef LOCAL_SOCKET_CHANNEL_H
#define LOCAL_SOCKET_CHANNEL_H

#include "adb/core/AdbChannel.h"

#include <atomic>
#include <mutex>

class LocalSocketChannel : public AdbChannel {
public:
    explicit LocalSocketChannel(int fd);
    ~LocalSocketChannel() override;

    void write(const uint8_t* data, size_t len) override;
    void read(uint8_t* buf, size_t len) override;
    void readWithTimeout(uint8_t* buf, size_t len, int timeoutMs = -1) override;
    void close() override;
    bool isClosed() const override;

private:
    int fd_;
    std::atomic<bool> closed_{false};
    std::mutex writeMutex_;
};

#endif // LOCAL_SOCKET_CHANNEL_H
