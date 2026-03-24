#include "stream/StreamStats.h"

#include <algorithm>
#include <hilog/log.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

double elapsedMs(const std::chrono::steady_clock::time_point& start,
                 const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}

bool shouldFlushWindow(const std::chrono::steady_clock::time_point& start,
                       const std::chrono::steady_clock::time_point& now) {
    return elapsedMs(start, now) >= 1000.0;
}

void recordDuration(DurationStats& stats, double ms) {
    if (stats.samples == 0) {
        stats.minMs = ms;
        stats.maxMs = ms;
    } else {
        stats.minMs = std::min(stats.minMs, ms);
        stats.maxMs = std::max(stats.maxMs, ms);
    }
    stats.totalMs += ms;
    ++stats.samples;
    if (ms > 5.0) {
        ++stats.over5Ms;
    }
    if (ms > 16.0) {
        ++stats.over16Ms;
    }
}

void maybeLogDurationStats(const char* tag, DurationStats& stats) {
    auto now = std::chrono::steady_clock::now();
    if (!shouldFlushWindow(stats.start, now) || stats.samples == 0) {
        return;
    }
    OH_LOG_INFO(LOG_APP,
                "[%{public}s] avg=%{public}.2f ms, min=%{public}.2f ms, max=%{public}.2f ms, >5ms=%{public}u, >16ms=%{public}u, samples=%{public}u",
                tag, stats.totalMs / stats.samples, stats.minMs, stats.maxMs, stats.over5Ms, stats.over16Ms,
                stats.samples);
    stats = {};
    stats.start = now;
}

void recordJitter(JitterStats& stats, const std::chrono::steady_clock::time_point& now) {
    if (!stats.hasLast) {
        stats.last = now;
        stats.hasLast = true;
        return;
    }
    double ms = elapsedMs(stats.last, now);
    stats.last = now;
    if (stats.samples == 0) {
        stats.minMs = ms;
        stats.maxMs = ms;
    } else {
        stats.minMs = std::min(stats.minMs, ms);
        stats.maxMs = std::max(stats.maxMs, ms);
    }
    stats.totalMs += ms;
    ++stats.samples;
    if (ms > 25.0) {
        ++stats.over25Ms;
    }
    if (ms > 33.0) {
        ++stats.over33Ms;
    }
}

void maybeLogJitterStats(const char* tag, JitterStats& stats) {
    auto now = std::chrono::steady_clock::now();
    if (!shouldFlushWindow(stats.start, now) || stats.samples == 0) {
        return;
    }
    OH_LOG_INFO(LOG_APP,
                "[%{public}s] avg=%{public}.2f ms, min=%{public}.2f ms, max=%{public}.2f ms, >25ms=%{public}u, >33ms=%{public}u",
                tag, stats.totalMs / stats.samples, stats.minMs, stats.maxMs, stats.over25Ms, stats.over33Ms);
    auto last = stats.last;
    auto hasLast = stats.hasLast;
    stats = {};
    stats.start = now;
    stats.last = last;
    stats.hasLast = hasLast;
}

void maybeLogThroughput(const char* tag, ThroughputStats& stats) {
    auto now = std::chrono::steady_clock::now();
    double ms = elapsedMs(stats.start, now);
    if (ms < 1000.0) {
        return;
    }
    double mib = static_cast<double>(stats.bytes) / (1024.0 * 1024.0);
    double mibPerSec = mib * 1000.0 / ms;
    double mbps = mibPerSec * 8.0;
    OH_LOG_INFO(LOG_APP, "[%{public}s] Throughput: %{public}.2f MiB/s (%{public}.2f Mbps), bytes=%{public}zu",
                tag, mibPerSec, mbps, stats.bytes);
    stats = {};
    stats.start = now;
}

void maybeLogDecoderRate(const char* tag, ThroughputStats& stats) {
    auto now = std::chrono::steady_clock::now();
    double ms = elapsedMs(stats.start, now);
    if (ms < 1000.0) {
        return;
    }
    double mib = static_cast<double>(stats.bytes) / (1024.0 * 1024.0);
    double mibPerSec = mib * 1000.0 / ms;
    double fps = stats.frames * 1000.0 / ms;
    OH_LOG_INFO(LOG_APP, "[%{public}s] Rate: %{public}.2f MiB/s, %{public}.2f fps, bytes=%{public}zu, frames=%{public}u",
                tag, mibPerSec, fps, stats.bytes, stats.frames);
    stats = {};
    stats.start = now;
}

void maybeLogFrameStats(FrameStats& stats) {
    auto now = std::chrono::steady_clock::now();
    double ms = elapsedMs(stats.start, now);
    if (ms < 1000.0 || stats.frames == 0) {
        return;
    }
    double fps = stats.frames * 1000.0 / ms;
    double avgKiB = static_cast<double>(stats.totalBytes) / stats.frames / 1024.0;
    double rateMiB = (static_cast<double>(stats.totalBytes) / (1024.0 * 1024.0)) * 1000.0 / ms;
    OH_LOG_INFO(LOG_APP,
                "[VideoFrames] fps=%{public}.2f, avg=%{public}.2f KiB, max=%{public}zu B, rate=%{public}.2f MiB/s",
                fps, avgKiB, stats.maxBytes, rateMiB);
    stats = {};
    stats.start = now;
}
