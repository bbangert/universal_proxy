// Runtime cost guard: per preset, measures the presented frame rate from
// page-flip timestamps (GPU-bound work escapes a CPU timer) and walks a
// ladder of levels (internal resolution x vblanks per frame) until the
// preset holds its level's minimum, or skips it past the last level.
//
// Levels, for ladder rungs r0 > r1 > ... and a start interval i0:
//   i0 == 1 (60 Hz capable): (r0,1) (r0,2) (r1,2) (r2,2) ...
//   i0 >= 2:                 (r0,i0) (r1,i0) ...
// A level at interval 1 must hold 90 % of the refresh rate; any other
// level must hold `min_fps` (the acceptable floor, e.g. 19 fps for 20 fps
// = 3 vblanks at 60 Hz with some jitter).
//
// Pure logic; the caller feeds it flip intervals and applies verdicts.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace md {

struct GuardLevel {
    size_t rung = 0;
    int interval = 2;
    double min_fps = 19.0;
};

class CostGuard {
public:
    struct Config {
        size_t rungs = 1;
        int start_interval = 2;
        double refresh_hz = 60.0;
        double min_fps = 19.0;
        int settle_frames = 15;  // after a preset start, blend or level change
        int window_frames = 60;  // frames per verdict
    };

    enum class Verdict { None, Accept, StepDown, Skip };

    explicit CostGuard(Config config);

    const std::vector<GuardLevel>& levels() const { return levels_; }

    // Starts measuring `file`. Returns the level to render it at: the one
    // it settled on earlier this session, else the first level at or below
    // `hint_rung` (the manifest's verdict), never above the thermal floor.
    size_t begin(const std::string& file, size_t hint_rung = 0);

    // A flip landed `interval_us` after the previous one. `measurable` is
    // false for frames that don't reflect the preset alone (blends). The
    // verdict refers to the current preset: StepDown means level() moved
    // one down (re-render at it), Skip means no level holds.
    Verdict on_flip(int64_t interval_us, bool measurable);

    // Restart the settle period (after a hold such as a warm-up).
    void resettle() { settle_left_ = config_.settle_frames; window_.clear(); }

    size_t level() const { return level_; }
    const GuardLevel& current() const { return levels_[level_]; }

    // Lowest rung allowed from now on (thermal). Returns true if the
    // current level moved.
    bool set_rung_floor(size_t rung);
    size_t rung_floor() const { return rung_floor_; }

    // The measured fps of the last full window for `file`, or < 0.
    double measured_fps(const std::string& file) const;
    // The fps of the last full window of the current preset, or < 0.
    double last_fps() const { return last_fps_; }

private:
    Config config_;
    std::vector<GuardLevel> levels_;
    std::map<std::string, size_t> settled_;  // file -> level
    std::map<std::string, double> fps_;      // file -> last window fps
    std::string file_;
    size_t level_ = 0;
    size_t rung_floor_ = 0;
    int settle_left_ = 0;
    std::vector<int64_t> window_;
    double last_fps_ = -1;

    size_t clamp_to_floor(size_t level) const;
};

}  // namespace md
