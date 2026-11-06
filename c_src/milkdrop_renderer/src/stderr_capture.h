// fd 2 capture. Mesa reports a vc4 register-allocation failure only on
// stderr ("MESA: error: Failed to register allocate:"), followed by a
// ~420 KB QIR dump per failing shader. stderr is redirected into a pipe
// that a thread drains (Mesa writes from the render thread, so an
// undrained pipe would deadlock it); the classifier keeps the first line
// of each driver error and discards everything else, dumps included.
//
// The renderer's own log lines go to the original stderr (log_fd()).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace md {

struct StderrFinding {
    enum class Kind { RegisterAllocate, DriverError, Marker };
    Kind kind;
    std::string text;     // the first line, bounded (DriverError)
    uint64_t marker = 0;  // Marker
};

// Splits a byte stream into lines and classifies them. Lines are bounded:
// only the first MAX_LINE bytes of a line are looked at.
class StderrClassifier {
public:
    static constexpr size_t MAX_LINE = 512;

    void feed(const char* data, size_t n, std::vector<StderrFinding>& out);

    uint64_t discarded_bytes() const { return discarded_; }

    // The line a marker is written as (see StderrCapture::sync).
    static std::string marker_line(uint64_t n);

private:
    std::string line_;
    uint64_t discarded_ = 0;

    void finish_line(std::vector<StderrFinding>& out);
};

class StderrCapture {
public:
    StderrCapture() = default;
    ~StderrCapture() { stop(); }
    StderrCapture(const StderrCapture&) = delete;
    StderrCapture& operator=(const StderrCapture&) = delete;

    // Redirects fd 2 into the pipe and starts the reader. False (stderr
    // left alone) if the pipe can't be made.
    bool start();
    // Restores fd 2 and joins the reader.
    void stop();

    // The original stderr (or 2 when not capturing).
    int log_fd() const { return log_fd_ >= 0 ? log_fd_ : 2; }

    // Waits until everything written to fd 2 so far has been classified,
    // up to `timeout_ms`. False on timeout.
    bool sync(int timeout_ms);

    // Driver findings since the last call (markers excluded).
    std::vector<StderrFinding> take_findings();

    uint64_t register_allocate_failures() const { return ra_failures_.load(); }
    uint64_t discarded_bytes() const { return discarded_.load(); }

private:
    int read_fd_ = -1;
    int log_fd_ = -1;
    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<StderrFinding> findings_;
    uint64_t marker_sent_ = 0;
    uint64_t marker_seen_ = 0;
    std::atomic<uint64_t> ra_failures_{0};
    std::atomic<uint64_t> discarded_{0};

    void run();
};

// Writes a printf-style line to the original stderr.
void log_msg(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void set_log_fd(int fd);

}  // namespace md
