// The pack's manifest.json and the skip-list file (layout in README.md).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "options.h"

namespace md {

struct PresetEntry {
    std::string file;               // path under <pack>/presets/, the preset's id
    std::vector<std::string> tags;  // e.g. "high_frequency", "extreme"
    bool high_frequency = false;    // tagged, or under high_frequency/
    // rpi3 (GLES2) sweep result: the largest rung that held the budget, or
    // skip. Ignored by GLES3 builds.
    Resolution rpi3_rung;          // width 0 = no hint
    bool rpi3_skip = false;
    std::string rpi3_reason;
    double rpi3_frame_ms = -1;     // whole-frame vc4 time at that rung, if measured
    double compile_ms = -1;
    double eval_ms = -1;
};

struct Manifest {
    std::string version;
    int format = 1;
    std::vector<PresetEntry> presets;
    size_t rejected = 0;  // entries dropped as malformed
};

// Parses manifest.json text. Malformed entries are dropped (and counted);
// a malformed document or an unknown format fails.
bool parse_manifest(std::string_view text, Manifest& out, std::string& error);

// A valid preset id: relative, no "..", no control characters, ends in
// ".milk", at most MAX_PRESET_NAME_BYTES.
bool valid_preset_file(std::string_view file);

// The skip file: one preset id per line ("\n"-separated, "\r" stripped,
// blank lines ignored).
std::set<std::string, std::less<>> parse_skip_list(std::string_view text);

// Reads a whole file. False if it can't be opened or is over `max_bytes`.
bool read_file(const std::string& path, std::string& out, size_t max_bytes = 64u << 20);

}  // namespace md
