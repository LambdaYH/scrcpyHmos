#ifndef SCRCPY_STREAM_STATS_H
#define SCRCPY_STREAM_STATS_H

#include <chrono>
#include <cstddef>
#include <cstdint>

struct ThroughputStats {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    size_t bytes = 0;
    uint32_t frames = 0;
};

struct FrameStats {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    uint32_t frames = 0;
    size_t totalBytes = 0;
    size_t maxBytes = 0;
};

struct DurationStats {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    double totalMs = 0.0;
    double minMs = 0.0;
    double maxMs = 0.0;
    uint32_t samples = 0;
    uint32_t over5Ms = 0;
    uint32_t over16Ms = 0;
};

struct JitterStats {
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point last;
    double totalMs = 0.0;
    double minMs = 0.0;
    double maxMs = 0.0;
    uint32_t samples = 0;
    uint32_t over25Ms = 0;
    uint32_t over33Ms = 0;
    bool hasLast = false;
};

double elapsedMs(const std::chrono::steady_clock::time_point& start,
                 const std::chrono::steady_clock::time_point& end);
bool shouldFlushWindow(const std::chrono::steady_clock::time_point& start,
                       const std::chrono::steady_clock::time_point& now);
void recordDuration(DurationStats& stats, double ms);
void maybeLogDurationStats(const char* tag, DurationStats& stats);
void recordJitter(JitterStats& stats, const std::chrono::steady_clock::time_point& now);
void maybeLogJitterStats(const char* tag, JitterStats& stats);
void maybeLogThroughput(const char* tag, ThroughputStats& stats);
void maybeLogDecoderRate(const char* tag, ThroughputStats& stats);
void maybeLogFrameStats(FrameStats& stats);

#endif // SCRCPY_STREAM_STATS_H
