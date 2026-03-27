#ifndef TLS_ADB_CHANNEL_H
#define TLS_ADB_CHANNEL_H

#include "adb/core/AdbChannel.h"
#include "adb/pairing/TlsConnection.h"

#include <atomic>
#include <memory>

class TlsAdbChannel : public AdbChannel {
public:
    TlsAdbChannel(std::unique_ptr<scrcpy::pairing::TlsConnection> tlsConnection, int fd);
    ~TlsAdbChannel() override;

    void write(const uint8_t* data, size_t len) override;
    void read(uint8_t* buf, size_t len) override;
    void readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) override;
    void close() override;
    bool isClosed() const override;

private:
    std::unique_ptr<scrcpy::pairing::TlsConnection> tlsConnection_;
    int fd_;
    std::atomic<bool> closed_{false};
};

#endif // TLS_ADB_CHANNEL_H
