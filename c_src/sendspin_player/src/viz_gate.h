// Orders visualizer frames (drain thread) against stream boundaries and
// viz_enable (main thread), all under one mutex together with the write:
// once a `viz_clear` or a `viz_enable:false` ack is written, no frame that
// belongs before it can follow.
//
// The listener API carries no stream id, so a frame is bound to its stream
// by its delivery time (display time minus display_offset_ms, client
// clock). At the pinned sendspin-cpp the drain thread's last stale check
// passes a frame no earlier than 1 ms before that delivery time, and the
// library marks a stream end/clear stale before it queues the matching
// listener callback to the main loop. A frame that was current at the
// check is therefore due before the boundary callback runs + 1 ms, so any
// frame due within BOUNDARY_MARGIN_US of the latest boundary is dropped —
// however late its callback reaches us. The cost is that a new stream's
// frames due within that margin of its start are dropped too.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <limits>
#include <mutex>
#include <string>

class VizGate {
public:
    using Emit = std::function<void(const std::string&)>;

    static constexpr int64_t BOUNDARY_MARGIN_US = 2000;

    explicit VizGate(Emit emit) : emit_(std::move(emit)) {}

    // Lock-free hint for skipping frame construction; emit_frame re-checks.
    bool enabled() const { return enabled_.load(std::memory_order_relaxed); }

    // Drain thread: writes `line` if frames are enabled and the frame, due
    // at `deliver_at_us`, is from after the latest boundary.
    bool emit_frame(int64_t deliver_at_us, const std::string& line) {
        std::lock_guard<std::mutex> lock(mtx_);
        if (!enabled_.load(std::memory_order_relaxed)) return false;
        if (boundary_us_ != NO_BOUNDARY && deliver_at_us <= boundary_us_ + BOUNDARY_MARGIN_US) {
            return false;
        }
        emit_(line);
        return true;
    }

    // Main thread: a stream start, end or clear at `now_us`; `line` (if
    // any) is written in the same critical section.
    void boundary(int64_t now_us, const std::string& line = {}) {
        std::lock_guard<std::mutex> lock(mtx_);
        boundary_us_ = now_us;
        if (!line.empty()) emit_(line);
    }

    // Main thread: viz_enable, with its ack written in the same critical
    // section.
    void set_enabled(bool enabled, const std::string& ack_line) {
        std::lock_guard<std::mutex> lock(mtx_);
        enabled_.store(enabled, std::memory_order_relaxed);
        emit_(ack_line);
    }

private:
    static constexpr int64_t NO_BOUNDARY = std::numeric_limits<int64_t>::min();

    Emit emit_;
    std::mutex mtx_;
    std::atomic<bool> enabled_{false};
    int64_t boundary_us_ = NO_BOUNDARY;
};
