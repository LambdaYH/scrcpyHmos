#ifndef VIDEO_STREAM_PROCESSOR_H
#define VIDEO_STREAM_PROCESSOR_H

#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <queue>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "VideoStreamProcessor"
#define LOG_DOMAIN 0x3200

// Forward declarations
class VideoDecoderNative;

/**
 * Ring Buffer for efficient data streaming
 */
class RingBuffer {
public:
    RingBuffer(size_t capacity);
    ~RingBuffer();

    // Write data to buffer (returns bytes written) - exclusive lock
    inline size_t Write(const uint8_t* data, size_t size) {
        if (size == 0 || buffer_ == nullptr) return 0;

        size_t wpos = writePos_.load(std::memory_order_acquire);
        size_t rpos = readPos_.load(std::memory_order_relaxed);
        size_t available = (wpos >= rpos) ? (capacity_ - wpos + rpos - 1) : (rpos - wpos - 1);

        if (available == 0) return 0;

        size_t toWrite = std::min(size, available);
        size_t firstPart = std::min(toWrite, capacity_ - wpos);
        memcpy(buffer_ + wpos, data, firstPart);

        if (firstPart < toWrite) {
            memcpy(buffer_, data + firstPart, toWrite - firstPart);
            wpos = toWrite - firstPart;
        } else {
            wpos += firstPart;
            if (wpos >= capacity_) wpos = 0;
        }

        writePos_.store(wpos, std::memory_order_release);
        cv_.notify_one();
        return toWrite;
    }

    // Read data from buffer (returns bytes read) - lock-free for single reader
    inline size_t Read(uint8_t* data, size_t size) {
        if (size == 0 || buffer_ == nullptr) return 0;

        size_t rpos = readPos_.load(std::memory_order_relaxed);
        size_t wpos = writePos_.load(std::memory_order_acquire);
        size_t available = (wpos >= rpos) ? (wpos - rpos) : (capacity_ - rpos + wpos);

        if (available == 0) return 0;

        size_t toRead = std::min(size, available);
        size_t firstPart = std::min(toRead, capacity_ - rpos);
        memcpy(data, buffer_ + rpos, firstPart);

        if (firstPart < toRead) {
            memcpy(data + firstPart, buffer_, toRead - firstPart);
            rpos = toRead - firstPart;
        } else {
            rpos += firstPart;
            if (rpos >= capacity_) rpos = 0;
        }

        readPos_.store(rpos, std::memory_order_release);
        return toRead;
    }

    // Peek at data without consuming (returns bytes peeked) - lock-free
    inline size_t Peek(uint8_t* data, size_t size) {
        if (size == 0 || buffer_ == nullptr) return 0;

        size_t rpos = readPos_.load(std::memory_order_relaxed);
        size_t wpos = writePos_.load(std::memory_order_acquire);
        size_t available = (wpos >= rpos) ? (wpos - rpos) : (capacity_ - rpos + wpos);

        if (available == 0) return 0;

        size_t toPeek = std::min(size, available);
        size_t firstPart = std::min(toPeek, capacity_ - rpos);
        memcpy(data, buffer_ + rpos, firstPart);

        if (firstPart < toPeek) {
            memcpy(data + firstPart, buffer_, toPeek - firstPart);
        }

        return toPeek;
    }

    // Advance read position (for consumed bytes) - lock-free
    inline void AdvanceRead(size_t size) {
        size_t rpos = readPos_.load(std::memory_order_relaxed);
        size_t wpos = writePos_.load(std::memory_order_acquire);
        size_t available = (wpos >= rpos) ? (wpos - rpos) : (capacity_ - rpos + wpos);
        size_t toAdvance = std::min(size, available);

        rpos += toAdvance;
        if (rpos >= capacity_) rpos -= capacity_;
        readPos_.store(rpos, std::memory_order_release);
    }

    // Get available data for reading - lock-free
    inline size_t GetReadAvailable() const {
        size_t rpos = readPos_.load(std::memory_order_acquire);
        size_t wpos = writePos_.load(std::memory_order_acquire);
        return (wpos >= rpos) ? (wpos - rpos) : (capacity_ - rpos + wpos);
    }

private:
    uint8_t* buffer_;
    size_t capacity_;
    std::atomic<size_t> readPos_;   // 优化：使用原子变量支持无锁读取
    std::atomic<size_t> writePos_;  // 优化：使用原子变量支持无锁读取
    mutable std::mutex mutex_;
    std::condition_variable cv_;
};

/**
 * Frame metadata for parsed frames
 */
struct FrameMetadata {
    int64_t pts;
    uint32_t flags;
    size_t size;
};

/**
 * Parsed frame ready for decoding
 */
struct ParsedFrame {
    std::unique_ptr<uint8_t[]> data;
    size_t size;
    int64_t pts;
    uint32_t flags;

    ParsedFrame() : data(nullptr), size(0), pts(0), flags(0) {}
    ParsedFrame(ParsedFrame&& other) noexcept
        : data(std::move(other.data)), size(other.size), pts(other.pts), flags(other.flags) {
        other.size = 0;
    }
};

/**
 * Video/Audio Stream Processor
 * Handles frame parsing and data pushing in C++ layer
 */
class VideoStreamProcessor {
public:
    enum class MediaType { VIDEO, AUDIO };

    VideoStreamProcessor();
    ~VideoStreamProcessor();

    // Initialize the processor
    int32_t Init(MediaType type, void* decoder, const char* codecType = "h264");

    // Start processing
    int32_t Start();

    // Stop processing
    int32_t Stop();

    // Release resources
    int32_t Release();

    // Push raw data from ArkTS (called frequently)
    // Returns: 0=success, -1=error, -2=queue full (caller should wait)
    int32_t PushData(const uint8_t* data, int32_t size, int64_t pts, uint32_t flags);

    // Check if processor is running
    bool IsRunning() const { return running_.load(); }

    // Get stats
    uint64_t GetProcessedFrameCount() const { return processedFrameCount_.load(); }
    uint64_t GetDroppedFrameCount() const { return droppedFrameCount_.load(); }

private:
    static void ProcessingThread(VideoStreamProcessor* self);

    // Scrcpy V2 frame parsing
    // Video format: [8 bytes PTS] [4 bytes size] [N bytes data]
    // Audio format: [4 bytes size] [N bytes data]
    int32_t ParseAndPushFrame();

    // Audio frame parsing (4-byte size header)
    int32_t ParseAudioFrame(size_t available);

    // Video frame parsing (8-byte PTS + 4-byte size header)
    int32_t ParseVideoFrame(size_t available);

    // Push frame to decoder
    int32_t PushToDecoder(const ParsedFrame& frame);

    // Direct push from RingBuffer to decoder (optimized)
    int32_t PushToDecoderFromRingBuffer(RingBuffer* ringBuffer, int32_t size, int64_t pts, uint32_t flags);

    MediaType mediaType_;
    void* decoder_;  // VideoDecoderNative* or AudioDecoderNative*

    // Ring buffer for incoming data
    std::unique_ptr<RingBuffer> ringBuffer_;

    // Parsed frame queue
    std::queue<ParsedFrame> frameQueue_;
    std::mutex frameQueueMutex_;

    // Processing thread
    std::unique_ptr<std::thread> processingThread_;

    // Control flags
    std::atomic<bool> running_{false};
    std::atomic<bool> stopped_{false};

    // Condition variable for data arrival
    mutable std::mutex cvMutex_;
    std::condition_variable dataCV_;

    // Statistics
    std::atomic<uint64_t> processedFrameCount_{0};
    std::atomic<uint64_t> droppedFrameCount_{0};

    // For video: codec type
    std::string codecType_;

    // Pending flags from ArkTS (set in PushData, used in ParseVideoFrame)
    std::atomic<uint32_t> pendingFlags_{0};

    // Constants
    static constexpr size_t RING_BUFFER_SIZE = 2 * 1024 * 1024;  // 2MB
    static constexpr size_t MAX_FRAME_SIZE = 20 * 1024 * 1024;   // 20MB max frame
    static constexpr size_t MIN_READ_SIZE = 12;  // 8 (PTS) + 4 (size)
};

#endif // VIDEO_STREAM_PROCESSOR_H
