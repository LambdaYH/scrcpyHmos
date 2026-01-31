#include "video_stream_processor.h"
#include "video_decoder_native.h"
#include "audio_decoder_native.h"
#include <hilog/log.h>
#include <thread>

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

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Started");
    return 0;
}

int32_t VideoStreamProcessor::Stop() {
    if (!running_.load()) {
        return 0;
    }

    running_ = false;

    // Notify waiting threads
    if (ringBuffer_) {
        std::unique_lock<std::mutex> lock(frameQueueMutex_);
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

    ringBuffer_.reset();
    decoder_ = nullptr;
    processedFrameCount_ = 0;
    droppedFrameCount_ = 0;

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Released");
    return 0;
}

int32_t VideoStreamProcessor::PushData(const uint8_t* data, int32_t size, int64_t pts, uint32_t flags) {
    if (!running_.load() || !ringBuffer_) {
        return -1;
    }

    if (size <= 0) {
        return 0;
    }

    // Write to ring buffer
    size_t written = ringBuffer_->Write(data, static_cast<size_t>(size));

    if (written < static_cast<size_t>(size)) {
        OH_LOG_WARN(LOG_APP, "[StreamProcessor] Ring buffer full, dropped %{public}zu bytes",
                    size - written);
        droppedFrameCount_++;
        return -2;  // Queue full
    }

    return 0;
}

void VideoStreamProcessor::ProcessingThread(VideoStreamProcessor* self) {
    if (!self) return;

    OH_LOG_INFO(LOG_APP, "[StreamProcessor] Processing thread started");

    while (self->running_.load()) {
        int32_t result = self->ParseAndPushFrame();

        if (result == -1) {
            // Error, wait a bit before retry
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        // If result == 0 (success) or -2 (need more data), continue immediately
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
        std::this_thread::sleep_for(std::chrono::microseconds(500));
        return -2;
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

    // Validate frame size
    if (frameSize <= 0 || frameSize > static_cast<int32_t>(MAX_FRAME_SIZE)) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Invalid audio frame size: %{public}d", frameSize);
        ringBuffer_->AdvanceRead(AUDIO_HEADER_SIZE);
        droppedFrameCount_++;
        return 0;
    }

    // Check if we have the complete frame
    size_t totalFrameSize = AUDIO_HEADER_SIZE + frameSize;
    if (available < totalFrameSize) {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
        return -2;
    }

    // Allocate frame buffer
    ParsedFrame frame;
    frame.data = std::make_unique<uint8_t[]>(frameSize);
    frame.size = frameSize;
    frame.pts = 0;  // Audio uses decoder's internal clock
    frame.flags = 0;

    if (!frame.data) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Failed to allocate audio frame buffer");
        droppedFrameCount_++;
        ringBuffer_->AdvanceRead(totalFrameSize);
        return 0;
    }

    // Read frame data
    ringBuffer_->AdvanceRead(AUDIO_HEADER_SIZE);
    size_t read = ringBuffer_->Read(frame.data.get(), frameSize);

    if (read < static_cast<size_t>(frameSize)) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Failed to read complete audio frame");
        droppedFrameCount_++;
        return 0;
    }

    // Push to decoder
    int32_t pushResult = PushToDecoder(frame);
    if (pushResult == 0) {
        processedFrameCount_++;
    }

    return pushResult;
}

int32_t VideoStreamProcessor::ParseVideoFrame(size_t available) {
    if (available < MIN_READ_SIZE) {
        std::this_thread::sleep_for(std::chrono::microseconds(500));
        return -2;
    }

    // Peek the header
    uint8_t header[MIN_READ_SIZE];
    size_t peeked = ringBuffer_->Peek(header, MIN_READ_SIZE);

    if (peeked < MIN_READ_SIZE) {
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

    // Validate frame size
    if (frameSize <= 0 || frameSize > static_cast<int32_t>(MAX_FRAME_SIZE)) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Invalid frame size: %{public}d", frameSize);
        ringBuffer_->AdvanceRead(MIN_READ_SIZE);
        droppedFrameCount_++;
        return 0;
    }

    // Check if we have the complete frame
    size_t totalFrameSize = MIN_READ_SIZE + frameSize;
    if (available < totalFrameSize) {
        std::this_thread::sleep_for(std::chrono::microseconds(200));
        return -2;
    }

    // Check config flag (bit 63 of PTS)
    static constexpr int64_t PACKET_FLAG_CONFIG = 1LL << 63;
    uint32_t flags = 0;
    if (pts & PACKET_FLAG_CONFIG) {
        flags = 8;  // AVCODEC_BUFFER_FLAGS_CODEC_DATA
        pts = pts & ~PACKET_FLAG_CONFIG;
    }

    // Allocate frame buffer
    ParsedFrame frame;
    frame.data = std::make_unique<uint8_t[]>(frameSize);
    frame.size = frameSize;
    frame.pts = pts;
    frame.flags = flags;

    if (!frame.data) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Failed to allocate frame buffer");
        droppedFrameCount_++;
        ringBuffer_->AdvanceRead(totalFrameSize);
        return 0;
    }

    // Read frame data
    ringBuffer_->AdvanceRead(MIN_READ_SIZE);
    size_t read = ringBuffer_->Read(frame.data.get(), frameSize);

    if (read < static_cast<size_t>(frameSize)) {
        OH_LOG_ERROR(LOG_APP, "[StreamProcessor] Failed to read complete frame");
        droppedFrameCount_++;
        return 0;
    }

    // Push to decoder
    int32_t pushResult = PushToDecoder(frame);
    if (pushResult == 0) {
        processedFrameCount_++;
    }

    return pushResult;
}

int32_t VideoStreamProcessor::PushToDecoder(const ParsedFrame& frame) {
    if (!decoder_) return -1;

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
