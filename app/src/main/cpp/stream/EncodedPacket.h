#ifndef SCRCPY_ENCODED_PACKET_H
#define SCRCPY_ENCODED_PACKET_H

#include <cstdint>
#include <vector>

struct EncodedVideoPacket {
    std::vector<uint8_t> data;
    int64_t pts = 0;
    uint32_t submitFlags = 0;
    bool isKeyFrame = false;
};

struct EncodedAudioPacket {
    std::vector<uint8_t> data;
    int64_t pts = 0;
    uint32_t submitFlags = 0;
};

#endif // SCRCPY_ENCODED_PACKET_H
