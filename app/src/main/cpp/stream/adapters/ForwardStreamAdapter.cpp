#include "stream/adapters/ForwardStreamAdapter.h"

#include <stdexcept>

namespace {
class ForwardByteStreamAdapter final : public IByteStream {
public:
    ForwardByteStreamAdapter(Adb* adb, AdbStream* stream, const char* debugName)
        : adb_(adb), stream_(stream), debugName_(debugName) {}

    void readExact(uint8_t* dest, size_t size, int32_t timeoutMs) override {
        if (!adb_ || !stream_) {
            throw std::runtime_error("byte stream adb unavailable");
        }
        size_t readSize = adb_->streamReadToBuffer(stream_, dest, size, timeoutMs, true);
        if (readSize < size) {
            throw std::runtime_error("Stream closed or read incomplete");
        }
    }

    bool isClosed() const override {
        return adb_ == nullptr || stream_ == nullptr || stream_->closed.load();
    }

    const char* debugName() const override {
        return debugName_;
    }

private:
    Adb* adb_;
    AdbStream* stream_;
    const char* debugName_;
};

class ForwardByteSinkAdapter final : public IByteSink {
public:
    ForwardByteSinkAdapter(Adb* adb, AdbStream* stream, const char* debugName)
        : adb_(adb), stream_(stream), debugName_(debugName) {}

    void write(const uint8_t* data, size_t len) override {
        if (!adb_ || !stream_) {
            throw std::runtime_error("byte sink adb unavailable");
        }
        adb_->streamWrite(stream_, data, len);
    }

    bool isClosed() const override {
        return adb_ == nullptr || stream_ == nullptr || stream_->closed.load();
    }

    const char* debugName() const override {
        return debugName_;
    }

private:
    Adb* adb_;
    AdbStream* stream_;
    const char* debugName_;
};
}

namespace forward_stream {

std::unique_ptr<IByteStream> makeByteStream(Adb* adb, AdbStream* stream, const char* debugName) {
    if (!adb || !stream) {
        return std::unique_ptr<IByteStream>();
    }
    return std::make_unique<ForwardByteStreamAdapter>(adb, stream, debugName);
}

std::unique_ptr<IByteSink> makeByteSink(Adb* adb, AdbStream* stream, const char* debugName) {
    if (!adb || !stream) {
        return std::unique_ptr<IByteSink>();
    }
    return std::make_unique<ForwardByteSinkAdapter>(adb, stream, debugName);
}

}
