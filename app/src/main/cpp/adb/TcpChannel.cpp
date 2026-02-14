// TcpChannel - 基于文件描述符的通道实现
// 参考 TcpChannel.ets 实现
// 不实现网络连接逻辑，fd由ArkTS传入
#include "TcpChannel.h"
#include <cerrno>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netdb.h> // for getaddrinfo
#include <poll.h>
#include <stdexcept>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "TcpChannel"

TcpChannel::TcpChannel(int fd) : fd_(fd) {
    if (fd_ < 0) {
        throw std::invalid_argument("Invalid fd");
    }
    // ArkTS TCPSocket sets the fd to non-blocking mode for its event loop.
    // We need blocking I/O for synchronous read()/write(), so clear O_NONBLOCK.
    int flags = fcntl(fd_, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd_, F_SETFL, flags & ~O_NONBLOCK);
        OH_LOG_INFO(LOG_APP, "TcpChannel: set fd=%{public}d to blocking mode (was flags=0x%{public}x)", fd_, flags);
    }
    buffer_.resize(BUFFER_SIZE);
    OH_LOG_INFO(LOG_APP, "TcpChannel: created with fd=%{public}d", fd_);
}

TcpChannel::TcpChannel(const std::string& host, int port) {
    fd_ = -1;
    buffer_.resize(BUFFER_SIZE);

    struct addrinfo hints, *res, *p;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; // IPv4 or IPv6
    hints.ai_socktype = SOCK_STREAM;

    std::string portStr = std::to_string(port);
    
    OH_LOG_INFO(LOG_APP, "TcpChannel: Resolving %{public}s:%{public}s...", host.c_str(), portStr.c_str());

    int status = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
    if (status != 0) {
        throw std::runtime_error("getaddrinfo failed: " + std::string(gai_strerror(status)));
    }

    // Iterate through results and try to connect
    for (p = res; p != nullptr; p = p->ai_next) {
        fd_ = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd_ < 0) {
            continue;
        }

        OH_LOG_INFO(LOG_APP, "TcpChannel: Type connecting...");

        if (connect(fd_, p->ai_addr, p->ai_addrlen) == 0) {
            // Success
            break;
        }

        ::close(fd_);
        fd_ = -1;
    }

    freeaddrinfo(res);

    if (fd_ < 0) {
        throw std::runtime_error("Failed to connect to " + host + ":" + portStr);
    }

    // Set TCP_NODELAY
    int flag = 1;
    setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, (char *)&flag, sizeof(int));

    OH_LOG_INFO(LOG_APP, "TcpChannel: connected fd=%{public}d", fd_);
}

TcpChannel::~TcpChannel() {
    close();
}

void TcpChannel::write(const uint8_t* data, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: write on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        // Use send with MSG_NOSIGNAL to avoid SIGPIPE if the socket is closed by peer
        ssize_t n = ::send(fd_, data + offset, len - offset, MSG_NOSIGNAL);
        if (n <= 0) {
            // If error is EPIPE, it means connection closed, handled as runtime_error
            throw std::runtime_error("TcpChannel: write failed (broken pipe or closed)");
        }
        offset += static_cast<size_t>(n);
    }
}

void TcpChannel::read(uint8_t* buf, size_t len) {
    readWithTimeout(buf, len, -1);
}

void TcpChannel::readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: read on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        // 1. Try reading from buffer
        size_t available = bufferTail_ - bufferHead_;
        if (available > 0) {
            size_t toCopy = std::min(available, len - offset);
            std::memcpy(buf + offset, buffer_.data() + bufferHead_, toCopy);
            bufferHead_ += toCopy;
            offset += toCopy;
            if (offset == len) break;
        }

        // 2. Buffer empty. Needs more data.
        size_t needed = len - offset;
        
        // Optimization: if needed size >= BUFFER_SIZE, read directly to user buffer
        if (needed >= BUFFER_SIZE) {
             if (timeoutMs >= 0) {
                 struct pollfd pfd;
                 pfd.fd = fd_;
                 pfd.events = POLLIN;
                 int ret = poll(&pfd, 1, timeoutMs);
                 if (ret <= 0) {
                     if (ret == 0) throw std::runtime_error("TcpChannel: read timeout");
                     throw std::runtime_error("TcpChannel: poll failed");
                 }
             }
             ssize_t n = ::read(fd_, buf + offset, needed);
             if (n <= 0) {
                 OH_LOG_ERROR(LOG_APP, "TcpChannel: read failed n=%{public}zd errno=%{public}d", n, errno);
                 throw std::runtime_error("TcpChannel: read failed or connection closed");
             }
             offset += static_cast<size_t>(n);
        } else {
             // Fill buffer
             fillBuffer(timeoutMs);
        }
    }
}

void TcpChannel::fillBuffer(int timeoutMs) {
    bufferHead_ = 0;
    bufferTail_ = 0;
    
    if (timeoutMs >= 0) {
         struct pollfd pfd;
         pfd.fd = fd_;
         pfd.events = POLLIN;
         int ret = poll(&pfd, 1, timeoutMs);
         if (ret <= 0) {
             if (ret == 0) throw std::runtime_error("TcpChannel: read timeout");
             throw std::runtime_error("TcpChannel: poll failed");
         }
    }
    
    ssize_t n = ::read(fd_, buffer_.data(), BUFFER_SIZE);
    if (n <= 0) {
        OH_LOG_ERROR(LOG_APP, "TcpChannel: fillBuffer failed n=%{public}zd errno=%{public}d", n, errno);
        throw std::runtime_error("TcpChannel: read failed or connection closed");
    }
    bufferTail_ = static_cast<size_t>(n);
}

void TcpChannel::close() {
    bool expected = false;
    if (closed_.compare_exchange_strong(expected, true)) {
        OH_LOG_INFO(LOG_APP, "TcpChannel: closing fd=%{public}d", fd_);
        if (fd_ >= 0) {
            // Shutdown both read and write to force unblock any pending read/write operations
            ::shutdown(fd_, SHUT_RDWR);
            ::close(fd_);
            fd_ = -1;
        }
    }
}

bool TcpChannel::isClosed() const {
    return closed_.load();
}
