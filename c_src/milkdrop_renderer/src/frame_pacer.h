// Page-flip pacing for a pipelined renderer: frame N+1 is rendered while
// flip N is pending, and each flip is held back until the vblank before
// its slot so frames land every `interval` vblanks (30 fps on two vblanks
// at 60 Hz) rather than whenever they finish.
//
// A flip submitted between vblank k-1 and vblank k lands at vblank k once
// the GPU has finished the buffer (the kernel waits on its fence). So
// after a flip lands at T, the next one is submitted at
// T + (interval - 1) * period + margin and lands at T + interval * period,
// or a vblank later if the GPU is late.
//
// All times are CLOCK_MONOTONIC microseconds (DRM flip event timestamps).
// Pure logic, unit-tested on the host.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>

namespace md {

class FramePacer {
public:
    FramePacer(double refresh_hz, int interval);

    int64_t period_us() const { return period_us_; }
    int interval() const { return interval_; }
    void set_interval(int interval) { interval_ = interval < 1 ? 1 : interval; }

    // A flip landed (event timestamp). Returns the interval since the
    // previous one (0 for the first), and counts it late if it took more
    // vblanks than `interval`.
    int64_t on_flip(int64_t t_us);

    // Presenting started (or restarted) with a frame shown at `t_us`.
    void reset(int64_t t_us);

    // Earliest time to submit the next flip (none pending).
    int64_t earliest_submit() const;

    // When a frame that starts rendering at `now_us` will be on screen:
    // the slot after the pending flip's, or the next slot after now plus
    // the expected render time.
    int64_t predict_present(int64_t now_us, bool flip_pending, int64_t render_estimate_us) const;

    int64_t last_flip() const { return last_flip_us_; }
    uint64_t late() const { return late_; }

private:
    int64_t period_us_;
    int interval_;
    int64_t last_flip_us_ = 0;
    uint64_t late_ = 0;
    static constexpr int64_t SUBMIT_MARGIN_US = 2000;
};

}  // namespace md
