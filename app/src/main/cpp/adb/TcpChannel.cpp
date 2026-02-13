// TcpChannel - 基于文件描述符的通道实现
// 参考 TcpChannel.ets 实现
// 不实现网络连接逻辑，fd由ArkTS传入
#include "TcpChannel.h"
#include <unistd.h>
#include <stdexcept>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "TcpChannel"

TcpChannel::TcpChannel(int fd) : fd_(fd) {
    if (fd < 0) {
        throw std::runtime_error("TcpChannel: invalid fd");
    }
    OH_LOG_INFO(LOG_APP, "TcpChannel: created with fd=%{public}d", fd);
}

TcpChannel::~TcpChannel() {
    close();
}

void TcpChannel::write(const uint8_t* data, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: write on closed channel");
    }

    std::lock_guard<std::mutex> lock(writeMutex_);
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = ::write(fd_, data + offset, len - offset);
        if (n <= 0) {
            throw std::runtime_error("TcpChannel: write failed");
        }
        offset += static_cast<size_t>(n);
    }
}

void TcpChannel::read(uint8_t* buf, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: read on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        ssize_t n = ::read(fd_, buf + offset, len - offset);
        if (n <= 0) {
            throw std::runtime_error("TcpChannel: read failed or connection closed");
        }
        offset += static_cast<size_t>(n);
    }
}

void TcpChannel::close() {
    bool expected = false;
    if (closed_.compare_exchange_strong(expected, true)) {
        OH_LOG_INFO(LOG_APP, "TcpChannel: closing fd=%{public}d", fd_);
        if (fd_ >= 0) {
            ::close(fd_);
            fd_ = -1;
        }
    }
}

bool TcpChannel::isClosed() const {
    return closed_.load();
}
