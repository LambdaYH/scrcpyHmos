#include "stream/StreamIO.h"
#include "stream/adapters/ForwardStreamAdapter.h"
#include "stream/adapters/ReverseStreamAdapter.h"

int32_t readInt32BEValue(const uint8_t* data) {
    return (static_cast<int32_t>(data[0]) << 24) |
           (static_cast<int32_t>(data[1]) << 16) |
           (static_cast<int32_t>(data[2]) << 8) |
           (static_cast<int32_t>(data[3]));
}

int64_t readInt64BEValue(const uint8_t* data) {
    return (static_cast<int64_t>(data[0]) << 56) |
           (static_cast<int64_t>(data[1]) << 48) |
           (static_cast<int64_t>(data[2]) << 40) |
           (static_cast<int64_t>(data[3]) << 32) |
           (static_cast<int64_t>(data[4]) << 24) |
           (static_cast<int64_t>(data[5]) << 16) |
           (static_cast<int64_t>(data[6]) << 8) |
           (static_cast<int64_t>(data[7]));
}

std::unique_ptr<IByteStream> createByteStream(Adb* adb, AdbChannel* channel, AdbStream* stream, const char* debugName) {
    if (channel) {
        return reverse_stream::makeByteStream(channel, debugName);
    }
    if (stream) {
        return forward_stream::makeByteStream(adb, stream, debugName);
    }
    return nullptr;
}

std::unique_ptr<IByteSink> createByteSink(Adb* adb, AdbChannel* channel, AdbStream* stream, const char* debugName) {
    if (channel) {
        return reverse_stream::makeByteSink(channel, debugName);
    }
    if (stream) {
        return forward_stream::makeByteSink(adb, stream, debugName);
    }
    return nullptr;
}

void applyPacketMeta(EncodedVideoPacket* packet, const ScrcpyPacketMeta& meta) {
    if (!packet) {
        return;
    }
    packet->pts = meta.pts;
    packet->submitFlags = meta.submitFlags;
    packet->isKeyFrame = meta.isKeyFrame;
}

void applyPacketMeta(EncodedAudioPacket* packet, const ScrcpyPacketMeta& meta) {
    if (!packet) {
        return;
    }
    packet->pts = meta.pts;
    packet->submitFlags = meta.submitFlags;
}
