#include "exit_guard.h"

#include "json.h"
#include "pcm_feed.h"        // monotonic_us
#include "protocol.h"
#include "stderr_capture.h"  // log_msg

#include <chrono>
#include <unistd.h>

namespace md {

ExitGuard::ExitGuard(const std::atomic<int>* signal_flag, int budget_ms)
    : signal_flag_(signal_flag), budget_ms_(budget_ms) {}

ExitGuard::~ExitGuard() { stop(); }

void ExitGuard::start() {
    if (thread_.joinable()) return;
    thread_ = std::thread([this] { run(); });
}

void ExitGuard::arm_locked(const std::string& reason, int code) {
    if (deadline_us_ == 0) deadline_us_ = monotonic_us() + int64_t{budget_ms_} * 1000;
    reason_ = reason;
    code_ = code;
}

void ExitGuard::arm(const std::string& reason, int code) {
    std::lock_guard<std::mutex> lock(mutex_);
    arm_locked(reason, code);
    cv_.notify_all();
}

void ExitGuard::exiting_sent() { exiting_sent_.store(true); }

void ExitGuard::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        cv_.notify_all();
    }
    if (thread_.joinable()) thread_.join();
}

void ExitGuard::run() {
    std::unique_lock<std::mutex> lock(mutex_);
    while (!stopping_) {
        // Polled: a signal handler can only set the flag.
        cv_.wait_for(lock, std::chrono::milliseconds(20));
        if (stopping_) return;
        if (deadline_us_ == 0 && signal_flag_ != nullptr && signal_flag_->load() != 0) arm_locked("signal", 0);
        if (deadline_us_ == 0 || monotonic_us() < deadline_us_) continue;

        const std::string reason = reason_;
        const int code = code_;
        lock.unlock();
        log_msg("shutdown (%s) still running after %d ms: exiting now", reason.c_str(), budget_ms_);
        // A main thread stuck inside a stdout write holds the writer; don't
        // wait on it for long.
        if (!exiting_sent_.load()) emit_line_within(event_exiting(reason), 100);
        ::_exit(code);
    }
}

}  // namespace md
