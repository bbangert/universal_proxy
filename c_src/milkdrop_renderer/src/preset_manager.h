// Which preset plays: filtering (skip list, high_frequency/, the rpi3
// manifest verdict), random rotation without repeats, prev/next history
// and lock. Pure logic; the caller loads what it returns.
//
// high_frequency/ presets are a photosensitivity filter: while they are
// excluded, no pick (start, rotate, next, prev, the locked one) returns
// one, and the caller reports what projectM renders (on_shown,
// on_blend_done) so a high_frequency preset still playing or blending out
// when the filter turns on is cut away at once.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "manifest.h"

#include <cstdint>
#include <random>
#include <set>
#include <string>
#include <vector>

namespace md {

class PresetManager {
public:
    struct Config {
        bool gles2 = false;           // honour the manifest's rpi3 verdicts
        bool high_frequency = false;  // include high_frequency/ presets
        uint64_t seed = 1;
        size_t history_limit = 64;
        double expensive_compile_ms = 600;  // presets over this rotate at half weight
    };

    PresetManager(std::vector<PresetEntry> entries, std::set<std::string, std::less<>> skipped,
                  Config config);

    size_t eligible_count() const;
    bool eligible(size_t index) const;

    // The preset to start on: `locked_file` (locked) if it is eligible,
    // else a random one (refused_lock() then says why). Null when nothing
    // is eligible.
    const PresetEntry* start(const std::string& locked_file);
    // Why start() didn't lock on its `locked_file` ("" if it did or none
    // was given): "high_frequency", "skipped", "rpi3_skip" or "unknown".
    const std::string& refused_lock() const { return refused_lock_; }

    // The timer's pick: the next one from the shuffle bag (new history).
    const PresetEntry* rotate();
    // Forward in history, or a new pick at its end.
    const PresetEntry* next();
    // Back in history to the newest eligible earlier preset; null (and no
    // change) if there is none.
    const PresetEntry* prev();

    const PresetEntry* current() const;
    bool locked() const { return locked_; }
    void set_locked(bool locked) { locked_ = locked; }

    // Never play `file` again this session. True if it is the current one
    // (the caller switches away).
    bool skip(const std::string& file);

    // True if a high_frequency preset is now on screen while excluded:
    // the caller must cut away (high_frequency_on_screen()).
    bool set_high_frequency(bool include);
    bool high_frequency() const { return config_.high_frequency; }

    // What projectM renders, as the caller reports it. A switch to `entry`
    // took effect, blended (the preset shown so far blends out) or cut
    // (nothing blends out). As in projectM, a switch during a blend first
    // completes it: only the latest outgoing preset remains.
    void on_shown(const PresetEntry& entry, bool blend);
    // The blend is over: the outgoing preset is no longer rendered.
    void on_blend_done();
    const PresetEntry* showing() const;
    const PresetEntry* outgoing() const;
    // high_frequency presets are excluded and one is still rendered,
    // playing or blending out: the caller must not render another frame
    // before a cut (never a blend) to cut_target().
    bool high_frequency_on_screen() const;
    // Where that cut goes: the playing preset when it is eligible (its
    // blend in completes at once), else a rotate() pick. Null when nothing
    // is eligible.
    const PresetEntry* cut_target();

    const std::vector<PresetEntry>& entries() const { return entries_; }

private:
    std::vector<PresetEntry> entries_;
    std::set<std::string, std::less<>> skipped_;
    Config config_;
    std::mt19937_64 rng_;
    std::vector<size_t> bag_;      // remaining picks, back = next
    std::vector<size_t> history_;  // played, oldest first
    size_t cursor_ = 0;            // index into history_ of the current preset
    bool has_current_ = false;
    bool locked_ = false;
    std::string refused_lock_;
    static constexpr size_t NONE = static_cast<size_t>(-1);
    size_t showing_ = NONE;   // entries_ index projectM plays
    size_t outgoing_ = NONE;  // and the one blending out

    bool excluded_high_frequency(size_t index) const;

    size_t draw();
    void refill_bag();
    void push_history(size_t index);
};

}  // namespace md
