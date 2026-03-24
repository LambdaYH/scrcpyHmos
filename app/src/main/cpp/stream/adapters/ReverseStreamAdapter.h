#ifndef SCRCPY_REVERSE_STREAM_ADAPTER_H
#define SCRCPY_REVERSE_STREAM_ADAPTER_H

#include "stream/StreamIO.h"

#include <memory>

namespace reverse_stream {
std::unique_ptr<IByteStream> makeByteStream(AdbChannel* channel, const char* debugName);
std::unique_ptr<IByteSink> makeByteSink(AdbChannel* channel, const char* debugName);
}

#endif // SCRCPY_REVERSE_STREAM_ADAPTER_H
