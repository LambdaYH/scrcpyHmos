#include "ScrcpyStreamManager.h"

#include "adb/channel/LocalSocketChannel.h"

#include <arpa/inet.h>
#include <cerrno>
#include <hilog/log.h>
#include <netinet/in.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

void ScrcpyStreamManager::closeFd(int& fd) {
    if (fd < 0) {
        return;
    }
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
    fd = -1;
}

void ScrcpyStreamManager::closeLocalTunnels() {
    if (videoChannel_) {
        videoChannel_->close();
    }
    if (audioChannel_) {
        audioChannel_->close();
    }
    if (controlChannel_) {
        controlChannel_->close();
    }
}

void ScrcpyStreamManager::releaseLocalTunnels() {
    if (videoChannel_) {
        delete videoChannel_;
        videoChannel_ = nullptr;
    }
    if (audioChannel_) {
        delete audioChannel_;
        audioChannel_ = nullptr;
    }
    if (controlChannel_) {
        delete controlChannel_;
        controlChannel_ = nullptr;
    }
}

void ScrcpyStreamManager::closeListener() {
    closeFd(listenFd_);
}

int32_t ScrcpyStreamManager::createTcpListener(uint16_t& port) {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] create listener socket failed errno=%{public}d", errno);
        return -1;
    }

    int reuseAddr = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, sizeof(reuseAddr));

    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(0);

    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] bind listener failed errno=%{public}d", errno);
        ::close(fd);
        return -2;
    }

    if (listen(fd, 4) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] listen failed errno=%{public}d", errno);
        ::close(fd);
        return -3;
    }

    sockaddr_in localAddr {};
    socklen_t localAddrLen = sizeof(localAddr);
    if (getsockname(fd, reinterpret_cast<sockaddr*>(&localAddr), &localAddrLen) != 0) {
        OH_LOG_ERROR(LOG_APP, "[StreamManager] getsockname failed errno=%{public}d", errno);
        ::close(fd);
        return -4;
    }

    listenFd_ = fd;
    port = ntohs(localAddr.sin_port);
    return 0;
}

void ScrcpyStreamManager::acceptThreadFunc() {
    try {
        auto acceptChannel = [this]() -> AdbChannel* {
            int fd = ::accept(listenFd_, nullptr, nullptr);
            if (fd < 0) {
                throw std::runtime_error("accept failed");
            }
            return new LocalSocketChannel(fd);
        };

        if (config_.expectVideo) {
            videoChannel_ = acceptChannel();
            videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
        }
        if (config_.expectAudio) {
            audioChannel_ = acceptChannel();
            audioThread_ = std::thread(&ScrcpyStreamManager::audioThreadFunc, this);
        }
        if (config_.expectControl) {
            controlChannel_ = acceptChannel();
            controlThread_ = std::thread(&ScrcpyStreamManager::controlThreadFunc, this);
            controlSendThread_ = std::thread(&ScrcpyStreamManager::controlSendThreadFunc, this);
        }
        emitEvent("reverse_ready", "");
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[StreamManager] Reverse accept failed: %{public}s", e.what());
            emitEvent("error", std::string("Reverse accept failed: ") + e.what());
        }
    }
}
