// The pack's and the user dir's manifest.json, the skip-list file and the
// selection file (layouts in README.md).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "options.h"

namespace md {

struct PresetEntry {
    // The preset's id: its path under <pack>/presets/, or "user/" + its
    // path under <user>/presets/.
    std::string file;
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

enum class FileStatus {
    Ok,
    Missing,  // no such file (or directory on its path)
    Invalid,  // unreadable, over the cap, or malformed (`error` says which)
};

// Reads a whole file, telling a missing one from an unreadable one.
FileStatus read_file_status(const std::string& path, std::string& out, size_t max_bytes, std::string& error);

// User presets (uploads) live under their own reserved id namespace: a
// pack id never starts with it.
inline constexpr std::string_view USER_PREFIX = "user/";
bool is_user_id(std::string_view id);

// Drops pack entries whose id is in the user namespace (counted as
// rejected). Returns how many.
size_t drop_user_ids(Manifest& pack);

// `<dir>/manifest.json`, the BEAM-generated user manifest, through
// parse_manifest; each entry's id becomes USER_PREFIX + its file (one too
// long for an id is rejected). An empty `dir` or a missing file is no
// user presets (Missing).
inline constexpr size_t MAX_USER_MANIFEST_BYTES = 4u << 20;
FileStatus load_user_manifest(const std::string& dir, Manifest& out, std::string& error);

// Where a preset id's file is: <pack>/presets/<id>, or for a user id
// <user>/presets/<id without "user/"> ("" without a user dir).
std::string preset_file_path(std::string_view pack_dir, std::string_view user_dir, std::string_view id);

// projectM's texture search path, in lookup order: the pack's textures
// win a name clash with the user's.
std::vector<std::string> texture_search_paths(std::string_view pack_dir, std::string_view user_dir);

// The selection file (BEAM-written): favourites, hidden presets and the
// playlist. Ids that aren't valid preset ids are dropped; unknown ones are
// kept (a later reload_user may add them).
struct UserSelection {
    int64_t gen = 0;
    std::set<std::string, std::less<>> favourites;
    std::set<std::string, std::less<>> hidden;
    std::set<std::string, std::less<>> playlist;
    bool playlist_enabled = false;
};

inline constexpr size_t MAX_SELECTION_BYTES = 1u << 20;
bool parse_selection(std::string_view text, UserSelection& out, std::string& error);
// An empty `path` or a missing file is the empty selection (Missing, `out`
// reset). Invalid leaves `out` untouched.
FileStatus load_selection(const std::string& path, UserSelection& out, std::string& error);

}  // namespace md
