// GPU reset detection from the kernel log. On rpi3 some presets hang the
// vc4 GPU; the kernel logs "[drm] Resetting GPU." and usually recovers, but
// a reset can also take the whole device down a few seconds later. The
// renderer follows /dev/kmsg to skip the preset at the first reset, before
// a fatal one. GL-free.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <set>
#include <string>
#include <string_view>

namespace md {

// True when a kernel log line reports a GPU reset: vc4's "[drm] Resetting
// GPU." or v3d's "[drm] Resetting GPU for hang.".
bool is_gpu_reset(std::string_view line);

// The message part of a /dev/kmsg record line ("6,1234,5678,-;text" ->
// "text"); other lines are returned as they are.
std::string_view kmsg_message(std::string_view line);

// Follows a kernel log device (or, in tests, a file) without blocking.
// Opened at its end, so only records logged from then on are seen.
class KmsgWatch {
public:
    KmsgWatch() = default;
    KmsgWatch(const KmsgWatch&) = delete;
    KmsgWatch& operator=(const KmsgWatch&) = delete;
    ~KmsgWatch();

    bool open(const std::string& path, std::string& err);
    bool active() const { return fd_ >= 0; }
    void close();

    // Reads what was logged since the last call (bounded per call) and
    // returns how many GPU reset lines it held; `message` gets the last
    // one's text. /dev/kmsg gives one record per read; a file may give
    // partial lines, which are kept for the next call.
    int poll_resets(std::string* message = nullptr);

private:
    int fd_ = -1;
    std::string partial_;
};

// One `gpu_hang` skip per preset per run, and resets closer together than
// `window_us` (counted from the last one seen) are taken as the same hang.
class GpuResetThrottle {
public:
    explicit GpuResetThrottle(int64_t window_us = 3000000) : window_us_(window_us) {}

    // A reset seen at `now_us`, blamed on `preset`: true when it should be
    // reported (skipped).
    bool report(std::string_view preset, int64_t now_us);

private:
    int64_t window_us_;
    bool seen_ = false;
    int64_t last_us_ = 0;
    std::set<std::string, std::less<>> reported_;
};

}  // namespace md
