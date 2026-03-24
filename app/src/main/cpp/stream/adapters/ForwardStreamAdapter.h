#ifndef SCRCPY_FORWARD_STREAM_ADAPTER_H
#define SCRCPY_FORWARD_STREAM_ADAPTER_H

#include "stream/StreamIO.h"

#include <memory>

namespace forward_stream {
std::unique_ptr<IByteStream> makeByteStream(Adb* adb, AdbStream* stream, const char* debugName);
std::unique_ptr<IByteSink> makeByteSink(Adb* adb, AdbStream* stream, const char* debugName);
}

#endif // SCRCPY_FORWARD_STREAM_ADAPTER_H
