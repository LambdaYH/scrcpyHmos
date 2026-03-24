// ScrcpyStreamManager - C++ 层流管理器实现
// 媒体流拆分为“收流线程 + 解码线程”，降低 socket 抖动对解码节奏的直接影响
#include "ScrcpyStreamManager.h"

#include <stdexcept>
#include <vector>

constexpr size_t VIDEO_PACKET_POOL_SIZE = 64;
constexpr size_t AUDIO_PACKET_POOL_SIZE = 32;

// ===================== 辅助函数 =====================
std::vector<uint8_t> ScrcpyStreamManager::readExact(IByteStream* source, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !source) {
        throw std::runtime_error("Stream manager not running");
    }
    std::vector<uint8_t> data(size);
    readExactToBuffer(source, data.data(), size, timeoutMs);
    return data;
}

void ScrcpyStreamManager::readExactToBuffer(IByteStream* source, uint8_t* dest, size_t size, int32_t timeoutMs) {
    if (!running_.load() || !source || !dest) {
        throw std::runtime_error("Stream manager not running");
    }
    source->readExact(dest, size, timeoutMs);
}

void ScrcpyStreamManager::initPacketPools() {
    videoPackets_.initialize(VIDEO_PACKET_POOL_SIZE);
    audioPackets_.initialize(AUDIO_PACKET_POOL_SIZE);
}

void ScrcpyStreamManager::resetPacketPools() {
    videoPackets_.reset();
    audioPackets_.reset();
}

void ScrcpyStreamManager::emitEvent(const std::string& type, const std::string& data) {
    std::lock_guard<std::mutex> lock(eventMutex_);
    if (eventCallback_) {
        eventCallback_(type, data);
    }
}


