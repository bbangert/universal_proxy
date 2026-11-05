// Orders visualizer frames against stream clear/end. The drain thread
// builds a frame outside any lock; if the main thread clears the stream
// meanwhile, writing that frame after the clear would redraw stale bars.
// A generation counter, bumped and checked under one mutex together with
// the write, drops any frame begun before the latest clear.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

class VizGate {
public:
    using Emit = std::function<void(const std::string&)>;

    explicit VizGate(Emit emit) : emit_(std::move(emit)) {}

    // Drain thread, before building a frame.
    uint64_t begin() const {
        std::lock_guard<std::mutex> lock(mtx_);
        return generation_;
    }

    // Drain thread: writes the frame unless the stream was cleared, ended or
    // restarted since begin(). Returns whether it was written.
    bool emit_if_current(uint64_t generation, const std::string& line) {
        std::lock_guard<std::mutex> lock(mtx_);
        if (generation != generation_) return false;
        emit_(line);
        return true;
    }

    // Main thread: a stream boundary. Every frame begun before it is
    // dropped; `line` (if not empty) is written in the same critical section.
    void boundary(const std::string& line = {}) {
        std::lock_guard<std::mutex> lock(mtx_);
        ++generation_;
        if (!line.empty()) emit_(line);
    }

private:
    Emit emit_;
    mutable std::mutex mtx_;
    uint64_t generation_ = 0;
};
