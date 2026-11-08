// Which preset plays: filtering (skip list, high_frequency/, the rpi3
// manifest verdict), the user's selection (hidden, playlist, favourites),
// random rotation without repeats, prev/next history, lock and explicit
// picks (play). Pure logic; the caller loads what it returns.
//
// Entries never move: user presets reloaded mid-session are appended, and
// removed ones are tombstoned (never picked again, passed over in
// history) rather than erased, so the PresetEntry pointers the caller
// holds stay valid for the session. An id that comes back revives its
// entry, refreshed in place.
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
#include <deque>
#include <map>
#include <random>
#include <set>
#include <string>
#include <string_view>
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
        size_t favourite_tickets = 3;       // a favourite plays this many times per deal
    };

    PresetManager(std::vector<PresetEntry> entries, std::set<std::string, std::less<>> skipped,
                  Config config);

    // Eligible: playable at all (not removed, skipped, filtered out). An
    // explicit pick (play, --locked) may be any eligible preset; rotation
    // further honours the selection (rotation_pool()).
    size_t eligible_count() const;
    bool eligible(size_t index) const;

    // What rotation picks from, the first non-empty of: the eligible,
    // unhidden presets on the playlist (while it is enabled); the
    // eligible, unhidden ones; every eligible one. A selection never
    // empties rotation while anything is eligible.
    enum class Pool { Playlist, Unhidden, Eligible };
    struct PoolInfo {
        Pool pool = Pool::Eligible;
        size_t size = 0;
        bool playlist_fallback = false;  // the playlist is on but has nothing to rotate
        bool hidden_fallback = false;    // everything eligible is hidden
    };
    PoolInfo rotation_pool() const;

    // Replaces the selection; rotation re-deals. The playing preset is
    // left alone (it rotates away at the next switch).
    PoolInfo set_selection(UserSelection selection);
    const UserSelection& selection() const { return selection_; }

    struct UserReload {
        size_t presets = 0;  // live user presets after it
        size_t added = 0;    // new or revived ids
        size_t removed = 0;  // tombstoned
        bool cut = false;    // as set_high_frequency(): cut away now
    };
    // The user presets (ids under USER_PREFIX; others are ignored) become
    // `user`: new ids are appended, present ones refreshed in place, ones
    // no longer listed tombstoned. Rotation re-deals.
    UserReload set_user_presets(std::vector<PresetEntry> user);

    // The preset to start on: `locked_file` (locked) if it is eligible,
    // else a random one (refused_lock() then says why). Null when nothing
    // is eligible.
    const PresetEntry* start(const std::string& locked_file);
    // Why start() didn't lock on its `locked_file` ("" if it did or none
    // was given): "high_frequency", "skipped", "rpi3_skip" or "unknown".
    const std::string& refused_lock() const { return refused_lock_; }

    // The timer's pick: the next one from the shuffle bag (new history).
    const PresetEntry* rotate();
    // Forward in history, or a new pick at its end. History passes over
    // presets that are no longer eligible or are hidden.
    const PresetEntry* next();
    // Back in history to the newest such earlier preset; null (and no
    // change) if there is none.
    const PresetEntry* prev();

    // An explicit pick by id: any eligible preset, hidden or off the
    // playlist included. Null with `reason` ("unknown", "skipped",
    // "high_frequency", "rpi3_skip") when it can't play.
    const PresetEntry* find_playable(std::string_view id, std::string& reason) const;
    // `entry` (find_playable's) loaded: it becomes the current preset, in
    // history as a rotate pick would be, locked or not.
    void played(const PresetEntry& entry, bool lock);

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

    // Tickets left in the current deal (tests: it stays bounded).
    size_t bag_size() const { return bag_.size(); }

    // Tombstoned ones included.
    const std::deque<PresetEntry>& entries() const { return entries_; }
    bool removed(size_t index) const { return index < gone_.size() && gone_[index] != 0; }

private:
    std::deque<PresetEntry> entries_;  // never erased or reordered
    std::vector<uint8_t> gone_;        // per entry: tombstoned
    std::map<std::string, size_t, std::less<>> by_id_;
    std::set<std::string, std::less<>> skipped_;
    UserSelection selection_;
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
    Pool bag_pool_ = Pool::Eligible;  // the pool bag_ was dealt from

    bool excluded_high_frequency(size_t index) const;
    bool hidden(size_t index) const;
    bool in_pool(size_t index, Pool pool) const;
    bool in_history_walk(size_t index) const;
    // Why entry `index` isn't eligible ("" if it is).
    const char* refusal(size_t index) const;
    size_t index_of(const PresetEntry& entry) const;

    size_t draw();
    void refill_bag();
    void push_history(size_t index);
};

}  // namespace md
