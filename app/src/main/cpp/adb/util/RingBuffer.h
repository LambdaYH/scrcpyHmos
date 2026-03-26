#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <vector>
#include <atomic>
#include <cstdint>
#include <algorithm>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <cstring>

/**
 * RingBuffer - SPSC (Single-Producer Single-Consumer) Lock-Free Hybrid Buffer.
 * 
 * DESIGN:
 * - Indices (head_, tail_) are monotonic atomic<uint64_t> to avoid ABA and modulo complexity during indexing.
 * - Buffer size must be Power of 2 to use bitwise AND masking.
 * - "Fast Path": getWritePtr/getReadPtr/commit/consume use ONLY atomics. NO mutex.
 * - "Slow Path": waitForData/waitForSpace use Mutex/CV, but only when necessary.
 */
class RingBuffer {
public:
    explicit RingBuffer(size_t capacity) : head_(0), tail_(0), closed_(false) {
        // Ensure capacity is Power of 2
        if (capacity < 4096) capacity = 4096;
        size_t cap = 1;
        while (cap < capacity) cap <<= 1;
        capacity_ = cap;
        mask_ = capacity_ - 1;
        buffer_.resize(capacity_);
    }

    // Producer: Get write pointer and available contiguous size
    std::pair<uint8_t*, size_t> getWritePtr() {
        uint64_t h = head_.load(std::memory_order_relaxed);
        uint64_t t = tail_.load(std::memory_order_acquire);
        
        uint64_t size = h - t;
        if (size >= capacity_) return {nullptr, 0}; // Full

        uint64_t writeIdx = h & mask_;
        size_t available = capacity_ - size;
        size_t contiguous = capacity_ - writeIdx;
        
        return {&buffer_[writeIdx], std::min(available, contiguous)};
    }

    // Producer: Commit written bytes
    void commitWrite(size_t written) {
        uint64_t h = head_.load(std::memory_order_relaxed);
        // Release ordering ensures data is visible before head is updated
        head_.store(h + written, std::memory_order_release);
        cv_.notify_all();
    }

    // Consumer: Get read pointer and available contiguous data
    std::pair<const uint8_t*, size_t> getReadPtr() {
        uint64_t t = tail_.load(std::memory_order_relaxed);
        uint64_t h = head_.load(std::memory_order_acquire);
        
        uint64_t size = h - t;
        if (size == 0) return {nullptr, 0}; // Empty

        uint64_t readIdx = t & mask_;
        size_t contiguous = capacity_ - readIdx;
        
        return {&buffer_[readIdx], std::min(static_cast<size_t>(size), contiguous)};
    }

    // Consumer: Consume bytes
    void consumeRead(size_t consumed) {
        uint64_t t = tail_.load(std::memory_order_relaxed);
        // Release ordering ensures data read completion is theoretically ordered (though for SPSC read it's more about tail update visibility)
        tail_.store(t + consumed, std::memory_order_release);
        cv_.notify_all();
    }

    // Consumer: Blocking wait for data
    // Returns true if data available, false if timeout or closed
    bool waitForData(size_t needed, int timeoutMs) {
        if (needed == 0) needed = 1;

        // Fast check without lock (Fast Path)
        if (size() >= needed) return true;
        
        if (closed_.load(std::memory_order_acquire)) return false;
        
        // Timeout 0 = Non-blocking
        if (timeoutMs == 0) return false;

        std::unique_lock<std::mutex> lock(mutex_);

        bool result = false;
        if (timeoutMs < 0) {
            cv_.wait(lock, [this, needed] {
                return size() >= needed || closed_.load();
            });
            result = size() >= needed;
        } else {
            result = cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this, needed] {
                return size() >= needed || closed_.load();
            });
        }

        return result;
    }

    // Producer: Blocking wait for free space
    // Returns true if enough space is available, false if closed or timeout
    bool waitForSpace(size_t needed, int timeoutMs) {
        if (needed == 0) needed = 1;
        if (freeSpace() >= needed) return true;
        if (closed_.load(std::memory_order_acquire)) return false;
        if (timeoutMs == 0) return false;

        std::unique_lock<std::mutex> lock(mutex_);
        bool result = false;
        if (timeoutMs < 0) {
            cv_.wait(lock, [this, needed] {
                return freeSpace() >= needed || closed_.load();
            });
            result = freeSpace() >= needed;
        } else {
            result = cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this, needed] {
                return freeSpace() >= needed || closed_.load();
            });
        }

        return result;
    }

    void close() {
        closed_.store(true, std::memory_order_release);
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.notify_all();
    }

    bool isClosed() const {
        return closed_.load(std::memory_order_acquire);
    }
    
    // Helper for legacy copy
    size_t copyTo(uint8_t* dest, size_t count) {
        size_t totalCopied = 0;
        
        while (totalCopied < count) {
            auto readInfo = getReadPtr();
            if (readInfo.second == 0) break;
            
            size_t toCopy = std::min(count - totalCopied, readInfo.second);
            std::memcpy(dest + totalCopied, readInfo.first, toCopy);
            consumeRead(toCopy);
            totalCopied += toCopy;
        }
        return totalCopied;
    }

    size_t size() const {
        // Snapshot
        uint64_t h = head_.load(std::memory_order_acquire);
        uint64_t t = tail_.load(std::memory_order_acquire);
        return static_cast<size_t>(h - t);
    }

    size_t freeSpace() const {
        return capacity_ - size();
    }

    bool empty() const {
        return size() == 0;
    }

private:
    std::vector<uint8_t> buffer_;
    size_t capacity_;
    size_t mask_;
    
    // Cache line alignment padding could go here for true optimization to avoid false sharing
    // alignas(64) 
    std::atomic<uint64_t> head_; // Written by Producer
    // alignas(64)
    std::atomic<uint64_t> tail_; // Written by Consumer
    
    // Synchronization for blocking wait
    std::mutex mutex_;
    std::condition_variable cv_;
    std::atomic<bool> closed_;
};

#endif // RING_BUFFER_H
