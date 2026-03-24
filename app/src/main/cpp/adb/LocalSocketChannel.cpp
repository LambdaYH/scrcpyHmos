// LocalSocketChannel - 基于本地 socket fd 的通道实现
#include "LocalSocketChannel.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <hilog/log.h>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "SocketChannel"
#define LOG_DOMAIN 0x3200

namespace {
struct LocalSocketReadStats {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    double totalMs = 0.0;
    double minMs = 0.0;
    double maxMs = 0.0;
    double totalReqBytes = 0.0;
    double totalSyscalls = 0.0;
    double totalChunkBytes = 0.0;
    uint32_t calls = 0;
};

double elapsedMs(const std::chrono::steady_clock::time_point& start,
                 const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}

int pollRetryOnEintr(int fd, short events, int timeoutMs) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = events;
    pfd.revents = 0;

    while (true) {
        int ret = poll(&pfd, 1, timeoutMs);
        if (ret < 0 && errno == EINTR) {
            continue;
        }
        if (ret < 0) {
            throw std::runtime_error("LocalSocketChannel: poll failed");
        }
        if (ret == 0) {
            return 0;
        }
        if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            throw std::runtime_error("LocalSocketChannel: peer closed");
        }
        return ret;
    }
}

void recordLargeRead(LocalSocketReadStats& stats, double ms, size_t requestedBytes, uint32_t syscalls, size_t actualBytes) {
    auto now = std::chrono::steady_clock::now();
    if (stats.calls == 0) {
        stats.minMs = ms;
        stats.maxMs = ms;
    } else {
        stats.minMs = std::min(stats.minMs, ms);
        stats.maxMs = std::max(stats.maxMs, ms);
    }
    stats.totalMs += ms;
    stats.totalReqBytes += static_cast<double>(requestedBytes);
    stats.totalSyscalls += static_cast<double>(syscalls);
    stats.totalChunkBytes += static_cast<double>(actualBytes);
    ++stats.calls;

    if (elapsedMs(stats.start, now) < 1000.0) {
        return;
    }

    double avgReqKiB = (stats.totalReqBytes / stats.calls) / 1024.0;
    double avgSyscalls = stats.totalSyscalls / stats.calls;
    double avgChunkBytes = stats.totalSyscalls > 0.0 ? stats.totalChunkBytes / stats.totalSyscalls : 0.0;
    OH_LOG_INFO(LOG_APP,
                "[LocalSocketLargeRead] avg=%{public}.2f ms, min=%{public}.2f ms, max=%{public}.2f ms, avgReq=%{public}.1f KiB, avgSyscalls=%{public}.2f, avgChunk=%{public}.1f B, calls=%{public}u",
                stats.totalMs / stats.calls, stats.minMs, stats.maxMs, avgReqKiB, avgSyscalls, avgChunkBytes, stats.calls);
    stats = {};
    stats.start = now;
}
}

LocalSocketChannel::LocalSocketChannel(int fd) : fd_(fd) {
    if (fd_ < 0) {
        throw std::invalid_argument("LocalSocketChannel: invalid fd");
    }
}

LocalSocketChannel::~LocalSocketChannel() {
    close();
}

void LocalSocketChannel::write(const uint8_t* data, size_t len) {
    if (!data && len > 0) {
        throw std::invalid_argument("LocalSocketChannel: invalid write buffer");
    }
    if (closed_.load()) {
        throw std::runtime_error("LocalSocketChannel: write on closed channel");
    }

    std::lock_guard<std::mutex> lock(writeMutex_);
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = ::send(fd_, data + offset, len - offset, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            throw std::runtime_error("LocalSocketChannel: write failed");
        }
        offset += static_cast<size_t>(n);
    }
}

void LocalSocketChannel::read(uint8_t* buf, size_t len) {
    readWithTimeout(buf, len, -1);
}

void LocalSocketChannel::readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) {
    if (!buf && len > 0) {
        throw std::invalid_argument("LocalSocketChannel: invalid read buffer");
    }
    if (closed_.load()) {
        throw std::runtime_error("LocalSocketChannel: read on closed channel");
    }

    auto readStart = std::chrono::steady_clock::now();
    uint32_t readSyscalls = 0;
    size_t actualBytes = 0;
    thread_local LocalSocketReadStats largeReadStats;

    size_t offset = 0;
    while (offset < len) {
        if (timeoutMs >= 0) {
            int pollRet = pollRetryOnEintr(fd_, POLLIN, timeoutMs);
            if (pollRet == 0) {
                throw std::runtime_error("LocalSocketChannel: read timeout");
            }
        }

        ssize_t n = ::read(fd_, buf + offset, len - offset);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            throw std::runtime_error("LocalSocketChannel: read failed");
        }
        ++readSyscalls;
        offset += static_cast<size_t>(n);
        actualBytes += static_cast<size_t>(n);
    }

    if (len >= 4096) {
        recordLargeRead(largeReadStats,
                        elapsedMs(readStart, std::chrono::steady_clock::now()),
                        len,
                        readSyscalls,
                        actualBytes);
    }
}

void LocalSocketChannel::close() {
    bool expected = false;
    if (!closed_.compare_exchange_strong(expected, true)) {
        return;
    }

    if (fd_ >= 0) {
        ::shutdown(fd_, SHUT_RDWR);
        ::close(fd_);
        fd_ = -1;
    }
}

bool LocalSocketChannel::isClosed() const {
    return closed_.load();
}
