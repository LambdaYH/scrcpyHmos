#include "adb/channel/TlsAdbChannel.h"

#include <cerrno>
#include <poll.h>
#include <stdexcept>
#include <string_view>
#include <chrono>
#include <sys/socket.h>
#include <unistd.h>

namespace {
int pollRetryOnEintr(struct pollfd* pfd, nfds_t nfds, int timeoutMs) {
    if (timeoutMs < 0) {
        while (true) {
            int ret = poll(pfd, nfds, -1);
            if (ret < 0 && errno == EINTR) {
                continue;
            }
            return ret;
        }
    }

    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            return 0;
        }
        int remainingMs = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count()
        );
        int ret = poll(pfd, nfds, remainingMs);
        if (ret < 0 && errno == EINTR) {
            continue;
        }
        return ret;
    }
}
}

TlsAdbChannel::TlsAdbChannel(std::unique_ptr<scrcpy::pairing::TlsConnection> tlsConnection, int fd)
    : tlsConnection_(std::move(tlsConnection)), fd_(fd) {
    if (!tlsConnection_ || fd_ < 0) {
        throw std::invalid_argument("Invalid TLS ADB channel");
    }
}

TlsAdbChannel::~TlsAdbChannel() {
    if (!closed_.load()) {
        close();
    }
    tlsConnection_.reset();
}

void TlsAdbChannel::write(const uint8_t* data, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TlsAdbChannel: write on closed channel");
    }
    if (!tlsConnection_->WriteFully(std::string_view(reinterpret_cast<const char*>(data), len))) {
        throw std::runtime_error("TlsAdbChannel: write failed");
    }
}

void TlsAdbChannel::read(uint8_t* buf, size_t len) {
    readWithTimeout(buf, len, -1);
}

void TlsAdbChannel::readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) {
    if (closed_.load()) {
        throw std::runtime_error("TlsAdbChannel: read on closed channel");
    }

    size_t offset = 0;
    const bool hasDeadline = timeoutMs >= 0;
    const auto deadline = hasDeadline
        ? std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs)
        : std::chrono::steady_clock::time_point{};

    while (offset < len) {
        if (closed_.load()) {
            throw std::runtime_error("TlsAdbChannel: read on closed channel");
        }

        if (tlsConnection_->PendingBytes() == 0) {
            int waitTimeout = -1;
            if (hasDeadline) {
                auto now = std::chrono::steady_clock::now();
                if (now >= deadline) {
                    throw std::runtime_error("TlsAdbChannel: read timeout");
                }
                waitTimeout = static_cast<int>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count()
                );
            }

            struct pollfd pfd;
            pfd.fd = fd_;
            pfd.events = POLLIN;
            pfd.revents = 0;
            int pollResult = pollRetryOnEintr(&pfd, 1, waitTimeout);
            if (pollResult == 0) {
                throw std::runtime_error("TlsAdbChannel: read timeout");
            }
            if (pollResult < 0) {
                throw std::runtime_error("TlsAdbChannel: poll failed");
            }
            if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                throw std::runtime_error("TlsAdbChannel: read failed");
            }
        }

        int bytesRead = tlsConnection_->ReadSome(buf + offset, len - offset);
        if (bytesRead <= 0) {
            throw std::runtime_error("TlsAdbChannel: read failed");
        }
        offset += static_cast<size_t>(bytesRead);
    }
}

void TlsAdbChannel::close() {
    if (closed_.exchange(true)) {
        return;
    }
    if (fd_ >= 0) {
        ::shutdown(fd_, SHUT_RDWR);
        ::close(fd_);
        fd_ = -1;
    }
}

bool TlsAdbChannel::isClosed() const {
    return closed_.load();
}
