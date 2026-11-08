// Runtime cost guard: per preset, measures the presented frame rate from
// page-flip timestamps (GPU-bound work escapes a CPU timer) and walks a
// ladder of levels (internal resolution x vblanks per frame) until the
// preset holds its level's minimum, or skips it past the last level.
//
// Levels, for ladder rungs r0 > r1 > ... and a start interval i0:
//   i0 == 1 (60 Hz capable): (r0,1) (r0,2) (r1,2) (r2,2) ...
//   i0 >= 2:                 (r0,i0) (r1,i0) ...
// `min_fps` is the frame rate a preset must hold (the user's minimum,
// 20 by default), capped at what the start interval can present
// (refresh / i0). A window passes at `min_fps - MIN_FPS_SLACK` or more:
// 20 fps = 3 vblanks at 60 Hz measures just under 20 with jitter (and at
// 59.94 Hz), so a minimum of 20 accepts 19. Levels at interval >= 2 must
// hold that floor; a level whose interval can't present it at all
// (refresh / interval below the floor) is passed over. The interval-1
// level must also hold 90 % of the refresh while an interval-2 level can
// still hold the floor (a steady half rate beats a jittery full one);
// otherwise only the floor.
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

// Slack under the minimum frame rate that still counts as holding it.
inline constexpr double MIN_FPS_SLACK = 1.0;

struct GuardLevel {
    size_t rung = 0;
    int interval = 2;
    double min_fps = 19.0;  // the floor a window must reach at this level
};

class CostGuard {
public:
    struct Config {
        size_t rungs = 1;
        int start_interval = 2;
        double refresh_hz = 60.0;
        double min_fps = 20.0;   // the frame rate a preset must hold
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

    // A new minimum frame rate (the current one changes nothing): level
    // floors follow, levels settled this session are forgotten (presets are
    // re-measured from their hint), and the current preset's next window is
    // judged against the new floor. Skip: its level's interval can't
    // present the new floor (nor can the levels below, which share it).
    // None: it stays at its level until its next window decides.
    Verdict set_min_fps(double min_fps);
    double min_fps() const { return config_.min_fps; }

    // The preset being measured, so a failed switch can hand the guard
    // back to it at its own level (resume()) after candidates began.
    struct Run {
        std::string file;
        size_t level = 0;
        bool detached = false;
    };
    Run run() const { return {file_, level_, detached_}; }
    // Measures `run` again from a settle period, at its level (never above
    // the thermal floor).
    void resume(const Run& run);

    // Restart the settle period (after a hold such as a warm-up).
    void resettle() { settle_left_ = config_.settle_frames; window_.clear(); }

    size_t level() const { return level_; }
    const GuardLevel& current() const { return levels_[level_]; }

    // Lowest rung allowed from now on (thermal). Returns true if the
    // current level moved.
    bool set_rung_floor(size_t rung);
    size_t rung_floor() const { return rung_floor_; }

    // `file`'s content changed (an upload replaced): what was learnt about
    // it (settled level, measured fps) goes, so its next begin() starts
    // from the hint. If it is the preset being measured, that keeps its
    // level and verdicts, but its windows no longer record for `file`
    // (they measure the old content).
    void forget(const std::string& file);

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
    bool detached_ = false;  // file_'s windows don't record (forget())
    size_t level_ = 0;
    size_t rung_floor_ = 0;
    int settle_left_ = 0;
    std::vector<int64_t> window_;
    double last_fps_ = -1;

    size_t clamp_to_floor(size_t level) const;
    void apply_floors();
    // Whether `level`'s interval can present its floor at all.
    bool reachable(size_t level) const;
    // `level` if reachable, else the next reachable one below; levels_.size()
    // if none.
    size_t reachable_from(size_t level) const;
};

}  // namespace md
