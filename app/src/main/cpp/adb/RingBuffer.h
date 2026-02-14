#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <vector>
#include <atomic>
#include <cstdint>
#include <algorithm>
#include <mutex>
#include <condition_variable>
#include <cstring>

/**
 * RingBuffer - SPSC (Single-Producer Single-Consumer) Lock-Free Hybrid Buffer.
 * 
 * DESIGN:
 * - Indices (head_, tail_) are monotonic atomic<uint64_t> to avoid ABA and modulo complexity during indexing.
 * - Buffer size must be Power of 2 to use bitwise AND masking.
 * - "Fast Path": getWritePtr/getReadPtr/commit/consume use ONLY atomics. NO mutex.
 * - "Slow Path": waitForData uses Mutex/CV, but only when necessary.
 */
class RingBuffer {
public:
    explicit RingBuffer(size_t capacity) : head_(0), tail_(0), waiting_(false), closed_(false) {
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

        // Check if consumer is waiting (with full memory barrier to prevent reordering beyond store head)
        // Store Head -> Fence -> Load Waiting
        std::atomic_thread_fence(std::memory_order_seq_cst); // Ensure Head update is visible before load Waiting
        
        if (waiting_.load(std::memory_order_acquire)) {
            std::unique_lock<std::mutex> lock(mutex_);
            // Double check waiting inside lock to be safe/avoid spurious wakeups, 
            // though strict necessity depends on exact waiting_ lifecycle.
            // Simplified: Just notify if flag seen.
            waiting_.store(false, std::memory_order_relaxed); // Clear flag as we are waking up
            cv_.notify_all();
        }
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
        
        // Set waiting flag BEFORE checking size a second time
        waiting_.store(true, std::memory_order_release);
        
        // Full barrier to ensure Waiting stored before loading Head
        std::atomic_thread_fence(std::memory_order_seq_cst);

        // Re-check state after setting flag to avoid race (lost wakeup)
        // If producer wrote after our first check but before we set waiting, we might miss it
        if (size() >= needed || closed_.load()) {
            waiting_.store(false, std::memory_order_relaxed);
            return size() >= needed;
        }

        bool result = false;
        if (timeoutMs < 0) {
            cv_.wait(lock, [this, needed] { 
                // Inside wait, spurious wakeups handled by loop, but we need to create loop manually 
                // or just rely on predicate.
                bool ready = size() >= needed || closed_.load();
                if (ready) waiting_.store(false, std::memory_order_relaxed);
                return ready;
            });
            result = size() >= needed;
        } else {
            result = cv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [this, needed] { 
                bool ready = size() >= needed || closed_.load();
                if (ready) waiting_.store(false, std::memory_order_relaxed);
                return ready;
            });
        }
        
        // Ensure flag cleared on exit (timeout case)
        if (!result) waiting_.store(false, std::memory_order_relaxed);
        
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
    std::atomic<bool> waiting_; 
    std::atomic<bool> closed_;
};

#endif // RING_BUFFER_H
