// LocalSocketChannel - 基于本地 socket fd 的通道实现
#include "LocalSocketChannel.h"

#include <cerrno>
#include <cstring>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

namespace {
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
        offset += static_cast<size_t>(n);
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
