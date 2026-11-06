// Bounds shutdown. Once an exit is decided (arm) or a signal is seen, a
// watchdog thread gives the main thread `budget_ms` to finish; past that it
// emits `exiting` (unless the main thread already did), logs and _exit()s.
// The owner relies on `exiting` and a prompt exit: a teardown stuck in a
// driver, a DRM read or a thread join must not turn into a SIGKILL.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace md {

class ExitGuard {
public:
    // `signal_flag`, when set non-zero (by a signal handler), arms the guard
    // with reason "signal" and exit code 0.
    explicit ExitGuard(const std::atomic<int>* signal_flag, int budget_ms = 1000);
    ~ExitGuard();
    ExitGuard(const ExitGuard&) = delete;
    ExitGuard& operator=(const ExitGuard&) = delete;

    void start();
    // Starts the budget (the first arm wins; later calls only update the
    // reason and code reported if it fires).
    void arm(const std::string& reason, int code);
    // The main thread emitted `exiting`: the guard won't emit another.
    void exiting_sent();
    // Stops the watchdog without firing (normal end of teardown).
    void stop();

private:
    const std::atomic<int>* signal_flag_;
    const int budget_ms_;
    std::thread thread_;
    std::mutex mutex_;
    std::condition_variable cv_;
    bool stopping_ = false;
    int64_t deadline_us_ = 0;  // 0 = not armed
    std::string reason_;
    int code_ = 0;
    std::atomic<bool> exiting_sent_{false};

    void run();
    void arm_locked(const std::string& reason, int code);
};

}  // namespace md
