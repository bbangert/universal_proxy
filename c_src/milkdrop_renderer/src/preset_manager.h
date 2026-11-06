// Which preset plays: filtering (skip list, high_frequency/, the rpi3
// manifest verdict), random rotation without repeats, prev/next history
// and lock. Pure logic; the caller loads what it returns.
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
    // else a random one. Null when nothing is eligible.
    const PresetEntry* start(const std::string& locked_file);

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

    // True if the current preset is no longer eligible (switch away).
    bool set_high_frequency(bool include);

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

    size_t draw();
    void refill_bag();
    void push_history(size_t index);
};

}  // namespace md
