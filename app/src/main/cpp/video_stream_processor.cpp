#include "video_stream_processor.h"
#include "video_decoder_native.h"
#include "audio_decoder_native.h"
#include <hilog/log.h>
#include <thread>
#include <chrono>
#include <time.h>  // for nanosleep

// Thread priority setting for HarmonyOS/Linux

#include <pthread.h>
#include <sys/resource.h>


// Define static constexpr members (required for ODR-use)
constexpr size_t VideoStreamProcessor::RING_BUFFER_SIZE;
constexpr size_t VideoStreamProcessor::MAX_FRAME_SIZE;
constexpr size_t VideoStreamProcessor::MIN_READ_SIZE;

// ============== RingBuffer Constructor/Destructor ==============

RingBuffer::RingBuffer(size_t capacity)
    : capacity_(capacity), readPos_(0), writePos_(0) {
    buffer_ = new uint8_t[capacity_];
    if (!buffer_) {
        OH_LOG_ERROR(LOG_APP, "[RingBuffer] Failed to allocate buffer of size %{public}zu", capacity);
    } else {
        OH_LOG_DEBUG(LOG_APP, "[RingBuffer] Created with capacity %{public}zu", capacity_);
    }
}

RingBuffer::~RingBuffer() {
    delete[] buffer_;
    buffer_ = nullptr;
}

// ============== VideoStreamProcessor Implementation ==============

VideoStreamProcessor::VideoStreamProcessor()
    : mediaType_(MediaType::VIDEO), decoder_(nullptr), ringBuffer_(nullptr) {
}

VideoStreamProcessor::~VideoStreamProcessor() {
    Release();
}

int32_t VideoStreamProcessor::Init(MediaType type, void* decoder, const char* codecType) {
    mediaType_ = type;
    decoder_ = decoder;
    codecType_ = codecType ? codecType : "h264";

    // Create ring buffer
    ringBuffer_ = std::make_unique<RingBuffer>(RING_BUFFER_SIZE);
    if (!ringBuffer_) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Failed to create ring buffer");
        return -1;
    }

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Initialized for %{public}s, codec=%{public}s",
                type == MediaType::VIDEO ? "VIDEO" : "AUDIO", codecType_.c_str());

    return 0;
}

int32_t VideoStreamProcessor::Start() {
    if (running_.load()) {
        OH_LOG_WARN(LOG_APP, "[StreamProcessor] Already running");
        return 0;
    }
    
    running_ = true;
    stopped_ = false;

    // Create and start processing thread
    processingThread_ = std::make_unique<std::thread>(ProcessingThread, this);

    return 0;
}

int32_t VideoStreamProcessor::Stop() {
    if (!running_.load()) {
        return 0;
    }

    running_ = false;

    // Notify waiting threads using the same mutex as PushData
    if (ringBuffer_) {
        std::lock_guard<std::mutex> lock(frameQueueMutex_);
        dataCV_.notify_all();
    }

    // Wait for thread to finish
    if (processingThread_ && processingThread_->joinable()) {
        processingThread_->join();
    }

    stopped_ = true;
    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Stopped, processed %{public}llu frames",
                (unsigned long long)processedFrameCount_.load());

    return 0;
}

int32_t VideoStreamProcessor::Release() {
    Stop();

    // Clear frame queue
    {
        std::unique_lock<std::mutex> lock(frameQueueMutex_);
        while (!frameQueue_.empty()) {
            frameQueue_.pop();
        }
    }

    // Clear config buffer (for H.264/H.265 packet merger)
    configBuffer_.reset();
    configBufferSize_ = 0;

    ringBuffer_.reset();
    decoder_ = nullptr;
    processedFrameCount_ = 0;
    droppedFrameCount_ = 0;

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Released");
    return 0;
}

int32_t VideoStreamProcessor::PushData(const uint8_t* data, int32_t size, int64_t pts, uint32_t flags) {
    if (!running_.load() || !ringBuffer_) {
        OH_LOG_WARN(LOG_APP, "[StreamProcessor] PushData: not running or no ring buffer");
        return -1;
    }
    
    if (size <= 0) {
        return 0;
    }

    // Store flags for ParseVideoFrame to use (ArkTS already parsed config flag)
    pendingFlags_.store(flags, std::memory_order_release);

    // Write to ring buffer
    size_t written = ringBuffer_->Write(data, static_cast<size_t>(size));

    if (written < static_cast<size_t>(size)) {
        OH_LOG_WARN(LOG_APP, "[StreamProcessor] Ring buffer full, dropped %{public}zu bytes",
                    size - written);
        droppedFrameCount_++;
        return -2;  // Queue full
    }

    // Notify processing thread that data is available
    // Must acquire mutex before notifying to avoid missed wakeup
    {
        std::lock_guard<std::mutex> lock(frameQueueMutex_);
        dataCV_.notify_one();
    }
    return 0;
}

void VideoStreamProcessor::ProcessingThread(VideoStreamProcessor* self) {
    if (!self) return;

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Processing thread started (audio=%{public}d)",
                self->mediaType_ == MediaType::AUDIO);

    // 音频模式：等待音频流开始（服务器发送音频需要时间）
    size_t emptyFrameCount = 0;
    constexpr size_t MAX_EMPTY_FRAMES = 10;
    size_t noBufferCount = 0;  // 追踪无可用缓冲区的情况
    size_t waitingForDecoderCount = 0;  // 等待解码器缓冲区的次数
    constexpr size_t MAX_WAIT_FOR_DECODER = 500;  // 最多等待解码器缓冲区500次（约5秒）
    size_t loopCount = 0;  // 追踪循环次数，用于诊断

    while (self->running_.load()) {
        loopCount++;
        size_t available = self->ringBuffer_->GetReadAvailable();
        size_t minRequired = self->mediaType_ == MediaType::AUDIO ? 4 : VideoStreamProcessor::MIN_READ_SIZE;

        // 定期日志：每1000次循环输出一次状态
        if (loopCount % 1000 == 0) {
            OH_LOG_WARN(LOG_APP, "[StreamProcessor] Heartbeat: running=%{public}d, available=%{public}zu, minRequired=%{public}zu, loopCount=%{public}zu",
                       self->running_.load(), available, minRequired, loopCount);
        }

        if (available < minRequired) {
            // 使用 frameQueueMutex_ 和 dataCV_ 与 PushData() 保持一致
            std::unique_lock<std::mutex> lock(self->frameQueueMutex_);
            if (self->mediaType_ == MediaType::AUDIO) {
                self->dataCV_.wait_for(lock, std::chrono::milliseconds(5));
            } else {
                self->dataCV_.wait_for(lock, std::chrono::milliseconds(2));
            }
            continue;
        }

        // 检查解码器是否有可用的输入缓冲区
        // 如果没有缓冲区，先等待一段时间让解码器准备好
        if (!self->HasAvailableBuffer()) {
            waitingForDecoderCount++;
            if (waitingForDecoderCount > MAX_WAIT_FOR_DECODER) {
                OH_LOG_WARN(LOG_APP, "[StreamProcessor] Decoder buffers not available after %{public}zu attempts, continuing to wait...",
                           waitingForDecoderCount);
                waitingForDecoderCount = 0;  // 重置计数器，避免重复警告
            }
            // 减少等待时间：从 10ms 减少到 1ms，让 ProcessingThread 更活跃
            // 同时也减少睡眠次数限制
            struct timespec ts = {0, 1000000};  // 1ms
            nanosleep(&ts, nullptr);
            continue;
        }
        waitingForDecoderCount = 0;  // 重置计数器
        int32_t result = self->ParseAndPushFrame();

        // 每2秒输出诊断信息
        static size_t lastLogTime = 0;
        size_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();

        if (now - lastLogTime > 2000) {
            lastLogTime = now;
            size_t currentAvailable = self->ringBuffer_->GetReadAvailable();
            bool hasDecoderBuffer = self->HasAvailableBuffer();
            OH_LOG_INFO(LOG_APP, "[StreamProcessor] STATUS: available=%{public}zu, decoderBuf=%{public}d, processed=%{public}llu, dropped=%{public}llu",
                       currentAvailable, hasDecoderBuffer,
                       (unsigned long long)self->GetProcessedFrameCount(),
                       (unsigned long long)self->GetDroppedFrameCount());
        }
        
        OH_LOG_WARN(LOG_APP, "[测试日志result] %{public}d", result);

        if (result == -1) {
            // Error, wait a bit before retry
            // 但首先推进缓冲区以防止无限循环
            OH_LOG_WARN(LOG_APP, "[StreamProcessor] Parse error, advancing buffer to prevent stall");
            size_t currentAvail = self->ringBuffer_->GetReadAvailable();
            if (currentAvail >= MIN_READ_SIZE) {
                self->ringBuffer_->AdvanceRead(MIN_READ_SIZE);
            }
            emptyFrameCount++;
            if (emptyFrameCount > MAX_EMPTY_FRAMES) {
                OH_LOG_WARN(LOG_APP, "[StreamProcessor] Too many invalid frames, slowing down");
                struct timespec ts = {0, 10000000};  // 10ms
                nanosleep(&ts, nullptr);
                emptyFrameCount = 0;
            }
        } else if (result == -2) {
            // No available buffer, wait and retry
            noBufferCount++;
            if (noBufferCount > 100) {
                OH_LOG_WARN(LOG_APP, "[StreamProcessor] No available buffer for %{public}zu times, waiting...", noBufferCount);
                noBufferCount = 0;
            }
            OH_LOG_WARN(LOG_APP, "[StreamProcessor] wulallalalallaa");
            struct timespec ts = {0, 1000000};  // 1ms
            nanosleep(&ts, nullptr);
        } else {
            emptyFrameCount = 0;
            noBufferCount = 0;
        }
        // If result == 0 (success), continue immediately
    }

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Processing thread exited");
}

int32_t VideoStreamProcessor::ParseAndPushFrame() {

    if (!ringBuffer_) return -1;
    
    size_t available = ringBuffer_->GetReadAvailable();

    if (mediaType_ == MediaType::AUDIO) {
        // Audio format: [4 bytes size] [N bytes data]
        return ParseAudioFrame(available);
    } else {
        // Video format: [8 bytes PTS] [4 bytes size] [N bytes data]
        return ParseVideoFrame(available);
    }
}

int32_t VideoStreamProcessor::ParseAudioFrame(size_t available) {
    // Audio: just 4 bytes size header
    constexpr size_t AUDIO_HEADER_SIZE = 4;

    if (available < AUDIO_HEADER_SIZE) {
        return -2;  // Let ProcessingThread handle waiting
    }

    // Peek the size
    uint8_t sizeBuf[AUDIO_HEADER_SIZE];
    size_t peeked = ringBuffer_->Peek(sizeBuf, AUDIO_HEADER_SIZE);

    if (peeked < AUDIO_HEADER_SIZE) {
        return -2;
    }

    // Parse size (4 bytes big-endian)
    int32_t frameSize = 0;
    for (int i = 0; i < 4; i++) {
        frameSize = (frameSize << 8) | sizeBuf[i];
    }

    // 只在非静音期打印警告（避免刷屏）
    static int64_t lastWarnTime = 0;
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();

    // Validate frame size - 0 或过大的 size 是无效的
    if (frameSize <= 0 || frameSize > static_cast<int32_t>(MAX_FRAME_SIZE)) {
        // 如果 frameSize 为 0，可能是启动时的垃圾数据，跳过这 4 个字节
        if (frameSize == 0) {
            if (now - lastWarnTime > 10000) {
                OH_LOG_WARN(LOG_APP, "[StreamProcessor] Audio frame size is 0, possible startup delay or buffer underrun");
                lastWarnTime = now;
            }
            ringBuffer_->AdvanceRead(AUDIO_HEADER_SIZE);
        } else {
            OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Invalid audio frame size: %{public}d", frameSize);
            ringBuffer_->AdvanceRead(AUDIO_HEADER_SIZE);
        }
        droppedFrameCount_++;
        return 0;
    }

    // Check if we have the complete frame
    size_t totalFrameSize = AUDIO_HEADER_SIZE + frameSize;
    if (available < totalFrameSize) {
        return -2;  // Let ProcessingThread handle waiting
    }

    // 推进读取位置（跳过header）
    ringBuffer_->AdvanceRead(AUDIO_HEADER_SIZE);

    // 直接从RingBuffer推送到解码器（优化：消除ParsedFrame分配和额外memcpy）
    int32_t pushResult = PushToDecoderFromRingBuffer(ringBuffer_.get(), frameSize, 0, 0);

    if (pushResult == 0) {
        processedFrameCount_++;
    } else if (pushResult == -2) {
        // 需要更多数据，回退
        ringBuffer_->AdvanceRead(-static_cast<int64_t>(AUDIO_HEADER_SIZE));
        return -2;
    } else {
        // 错误或buffer满
        droppedFrameCount_++;
        // 跳过这帧数据
        ringBuffer_->AdvanceRead(frameSize);
    }

    return pushResult;
}

int32_t VideoStreamProcessor::ParseVideoFrame(size_t available) {
    if (available < MIN_READ_SIZE) {
        return -2;  // Let ProcessingThread handle waiting
    }

    // Peek the header
    uint8_t header[MIN_READ_SIZE];
    size_t peeked = ringBuffer_->Peek(header, MIN_READ_SIZE);

    if (peeked < MIN_READ_SIZE) {
        OH_LOG_WARN(LOG_APP, "[测试标志StreamProcessor] peeked < MIN_READ_SIZE");
        return -2;
    }

    // Parse header
    // PTS: 8 bytes big-endian
    int64_t pts = 0;
    for (int i = 0; i < 8; i++) {
        pts = (pts << 8) | header[i];
    }

    // Size: 4 bytes big-endian
    int32_t frameSize = 0;
    for (int i = 0; i < 4; i++) {
        frameSize = (frameSize << 8) | header[8 + i];
    }

    // Validate frame size BEFORE anything else - this catches parse errors early
    // A valid video frame should be between 1KB and 1MB typically
    static constexpr int32_t MAX_REASONABLE_FRAME_SIZE = 2 * 1024 * 1024;  // 2MB max reasonable

    if (frameSize <= 0 || frameSize > MAX_REASONABLE_FRAME_SIZE) {
        // This is likely a parse error - header bytes are not at frame boundary
        OH_LOG_WARN(LOG_APP, "[StreamProcessor] INVALID frameSize=%{public}d (available=%{public}zu), header bytes: "
                   "%02x %02x %02x %02x %02x %02x %02x %02x | "
                   "%02x %02x %02x %02x - SKIPPING 1 BYTE to resync",
                   frameSize, available,
                   header[0], header[1], header[2], header[3], header[4], header[5], header[6], header[7],
                   header[8], header[9], header[10], header[11]);
        // Skip 1 byte and try to resync on next boundary
        ringBuffer_->AdvanceRead(1);
        droppedFrameCount_++;
        return 0;
    }

    // Check if we have the complete frame BEFORE advancing
    size_t totalFrameSize = MIN_READ_SIZE + frameSize;
    if (available < totalFrameSize) {
        OH_LOG_DEBUG(LOG_APP, "[StreamProcessor] Incomplete frame: have %{public}zu, need %{public}zu (frameSize=%{public}d)",
                   available, totalFrameSize, frameSize);
        return -2;  // Let ProcessingThread handle waiting
    }

    // DEBUG: Log valid frame info
    static int debugCount = 0;
    if (debugCount < 10) {
        OH_LOG_DEBUG(LOG_APP, "[StreamProcessor] Parsed: PTS=%{public}lld, frameSize=%{public}d",
                   (long long)pts, frameSize);
        debugCount++;
    }

    // Use flags stored by PushData (ArkTS already parsed config flag from PTS)
    // Note: ArkTS passes flags separately, so we don't need to check bit 63 of PTS
    uint32_t flags = pendingFlags_.load(std::memory_order_acquire);

    // Check if this is a config packet (VPS/SPS/PPS for H.265, SPS/PPS for H.264)
    bool isConfig = (flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) != 0;

    // Log config frame handling
    static int configFrameCount = 0;
    OH_LOG_DEBUG(LOG_APP, "[StreamProcessor] isConfig=%{public}d, pts=%lld, frameSize=%{public}d",
                       isConfig ? 1 : 0, (long long)pts, frameSize);
    if (isConfig) {
        configFrameCount++;
        if (configFrameCount <= 5) {
            OH_LOG_INFO(LOG_APP, "[StreamProcessor] Config frame #%{public}d, size=%{public}d",
                       configFrameCount, frameSize);
        }
    }


    // Advance past header BEFORE storing/reading frame data
    ringBuffer_->AdvanceRead(MIN_READ_SIZE);
    
    // Handle config packet merger for H.264/H.265
    // According to scrcpy's packet_merger: config packets must be prepended to the next media packet
    if (isConfig) {
        // Store config data for merging with next frame
        configBuffer_ = std::make_unique<uint8_t[]>(frameSize);
        size_t read = ringBuffer_->Read(configBuffer_.get(), frameSize);
        if (read < static_cast<size_t>(frameSize)) {
            OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Incomplete config data read");
            configBuffer_.reset();
            droppedFrameCount_++;
            return 0;
        }
        configBufferSize_ = frameSize;
        OH_LOG_DEBUG(LOG_APP, "[StreamProcessor] Stored config data, size=%{public}zu", configBufferSize_);
        return 0;  // Config stored, will be merged with next frame
    }
    

    // Check if we have stored config data to merge
    if (configBuffer_) {
        // Merge config with current frame
        OH_LOG_DEBUG(LOG_APP, "[StreamProcessor] Merging config (%{public}zu bytes) with frame (%{public}d bytes)",
                   configBufferSize_, frameSize);

        // Read frame data first
        std::unique_ptr<uint8_t[]> frameData = std::make_unique<uint8_t[]>(frameSize);
        size_t read = ringBuffer_->Read(frameData.get(), frameSize);
        if (read < static_cast<size_t>(frameSize)) {
            OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Incomplete frame read during merge");
            droppedFrameCount_++;
            return 0;
        }

        // Create merged buffer: [config][frame]
        size_t mergedSize = configBufferSize_ + frameSize;
        std::unique_ptr<uint8_t[]> mergedData = std::make_unique<uint8_t[]>(mergedSize);
        std::memcpy(mergedData.get(), configBuffer_.get(), configBufferSize_);
        std::memcpy(mergedData.get() + configBufferSize_, frameData.get(), frameSize);

        // Clear stored config
        configBuffer_.reset();
        configBufferSize_ = 0;

        // Create ParsedFrame and push merged data to decoder
        ParsedFrame mergedFrame;
        mergedFrame.data = std::move(mergedData);
        mergedFrame.size = mergedSize;
        mergedFrame.pts = pts;
        mergedFrame.flags = flags;

        int32_t pushResult = PushToDecoder(mergedFrame);

        if (pushResult == 0) {
            processedFrameCount_++;
        } else if (pushResult != -2) {
            droppedFrameCount_++;
        }

        return pushResult;
    }

    // No config to merge, push frame directly
    int32_t pushResult = PushToDecoderFromRingBuffer(ringBuffer_.get(), frameSize, pts, flags);

    if (pushResult == 0) {
        processedFrameCount_++;
    } else if (pushResult == -2) {
        // 需要更多数据（不应该发生），回退
        ringBuffer_->AdvanceRead(-static_cast<int64_t>(frameSize));
        return -2;
    } else {
        // 错误或buffer满
        droppedFrameCount_++;
        // 跳过这帧数据
        ringBuffer_->AdvanceRead(frameSize);
    }

    return pushResult;
}

int32_t VideoStreamProcessor::PushToDecoder(const ParsedFrame& frame) {
    OH_LOG_WARN(LOG_APP, "[测试标志StreamProcessor] decoder_起");
    if (!decoder_) return -1;
    OH_LOG_WARN(LOG_APP, "[测试标志StreamProcessor] decoder_某啊啊啊啊啊啊啊啊啊");

    if (mediaType_ == MediaType::VIDEO) {
        VideoDecoderNative* videoDecoder = static_cast<VideoDecoderNative*>(decoder_);
        return videoDecoder->PushData(frame.data.get(), static_cast<int32_t>(frame.size),
                                       frame.pts, frame.flags);
    } else {
        AudioDecoderNative* audioDecoder = static_cast<AudioDecoderNative*>(decoder_);
        return audioDecoder->PushData(frame.data.get(), static_cast<int32_t>(frame.size),
                                       frame.pts);
    }
}

int32_t VideoStreamProcessor::PushToDecoderFromRingBuffer(RingBuffer* ringBuffer, int32_t size, int64_t pts, uint32_t flags) {
    if (!decoder_ || !ringBuffer) return -1;
//    OH_LOG_ERROR(LOG_APP, "[Native] PushToDecoderFromRingBuffer: mediaType_=%{public}d", mediaType_);
    if (mediaType_ == MediaType::VIDEO) {
        VideoDecoderNative* videoDecoder = static_cast<VideoDecoderNative*>(decoder_);
        return videoDecoder->PushFromRingBuffer(ringBuffer, size, pts, flags);
    } else {
        AudioDecoderNative* audioDecoder = static_cast<AudioDecoderNative*>(decoder_);
        return audioDecoder->PushFromRingBuffer(ringBuffer, size, pts, flags);
    }
}

bool VideoStreamProcessor::HasAvailableBuffer() const {
    if (!decoder_) return false;

    if (mediaType_ == MediaType::VIDEO) {
        VideoDecoderNative* videoDecoder = static_cast<VideoDecoderNative*>(decoder_);
        return videoDecoder->HasAvailableBuffer();
    } else {
        AudioDecoderNative* audioDecoder = static_cast<AudioDecoderNative*>(decoder_);
        return audioDecoder->HasAvailableBuffer();
    }
}
