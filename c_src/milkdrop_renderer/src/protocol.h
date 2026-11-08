// The line-JSON protocol: stdin commands and stdout events (README.md).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cerrno>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <sys/types.h>

namespace md {

struct Command {
    enum class Type {
        Take,
        Release,
        Exit,
        Next,
        Prev,
        Lock,
        Unlock,
        SetRotate,         // int_value: seconds
        SetHighFrequency,  // bool_value
        SetMinFps,         // number_value: frames per second
        Play,              // string_value: preset id; bool_value: lock
        ReloadUser,
        ReloadSelection,
    };
    Type type = Type::Exit;
    int int_value = 0;
    bool bool_value = false;
    double number_value = 0;
    std::string string_value;
};

// One stdin line. Unknown commands, bad values and non-JSON give nullopt
// with `error` set to a short reason.
std::optional<Command> parse_command(std::string_view line, std::string& error);

// Collects stdin bytes into lines. A line longer than `max_line` is dropped
// whole (the `overflowed` count goes up).
class LineBuffer {
public:
    explicit LineBuffer(size_t max_line = 4096) : max_(max_line) {}

    // Appends bytes; complete lines go to `on_line`.
    template <typename F>
    void feed(const char* data, size_t n, F&& on_line) {
        for (size_t i = 0; i < n; i++) {
            char c = data[i];
            if (c == '\n') {
                if (!discarding_) on_line(std::string_view(buf_));
                buf_.clear();
                discarding_ = false;
                continue;
            }
            if (discarding_) continue;
            if (buf_.size() >= max_) {
                buf_.clear();
                discarding_ = true;
                overflowed++;
                continue;
            }
            buf_ += c;
        }
    }

    uint64_t overflowed = 0;

private:
    size_t max_;
    std::string buf_;
    bool discarding_ = false;
};

enum class DrainEnd {
    Drained,  // the input would block
    Eof,      // end of input, or a read error
    Stopped,  // `stop()` turned true: an exit was decided
    Budget,   // `max_reads` reads in a row had data; call again later
};

// Reads commands through `read_chunk(buf, cap)` (read(2) semantics, non-
// blocking) into `lines`, handing each complete line to `on_line`. Once
// `stop()` is true (checked before every line), the remaining lines of that
// read are dropped and the drain returns: nothing after an `exit` runs, and
// input that keeps arriving can't hold up the shutdown.
template <typename Read, typename OnLine, typename Stop>
DrainEnd drain_lines(LineBuffer& lines, Read&& read_chunk, OnLine&& on_line, Stop&& stop, int max_reads = 16) {
    char buf[4096];
    for (int reads = 0; reads < max_reads; reads++) {
        if (stop()) return DrainEnd::Stopped;
        const ssize_t n = read_chunk(buf, sizeof(buf));
        if (n > 0) {
            lines.feed(buf, static_cast<size_t>(n), [&](std::string_view line) {
                if (!stop()) on_line(line);
            });
            continue;
        }
        if (n == 0) return DrainEnd::Eof;
        if (errno == EINTR) continue;
        return errno == EAGAIN || errno == EWOULDBLOCK ? DrainEnd::Drained : DrainEnd::Eof;
    }
    return stop() ? DrainEnd::Stopped : DrainEnd::Budget;
}

// Event lines. Every string field is sanitized and bounded so a line stays
// well under MAX_EMIT_LINE_BYTES; preset file names (at most
// MAX_PRESET_NAME_BYTES, enforced at manifest load) are echoed exactly.
inline constexpr size_t MAX_PRESET_NAME_BYTES = 1024;

std::string event_simple(std::string_view name);
// `crtc_mode` is the CRTC's mode when the card was opened, sent only when
// `crtc_mode_valid`.
struct PreparedInfo {
    std::string mode;         // "WxH@Hz" chosen
    std::string connector;    // "HDMI-A-1"; omitted when empty
    std::string mode_source;  // mode_source_name(); omitted when empty
    std::string gl_renderer;
    std::string gl_version;
    bool gles2 = false;
    int presets = 0;
    bool crtc_mode_valid = false;
    std::string crtc_mode;    // only with crtc_mode_valid
};

std::string event_prepared(const PreparedInfo& info);
std::string event_presenting(bool modeset, double master_ms, bool crtc_lit);
std::string event_preset(std::string_view file, bool locked, std::string_view rung,
                         std::string_view cause, bool cut);
// Sent before any GPU work for preset `file` (its level, preload, warm-up
// frame), so the BEAM can persist what was loading if the GPU hangs and
// takes the device down with it.
std::string event_loading(std::string_view file);
// `message` (optional) is the first line of the error behind it; `fps`
// (sent when >= 0) the frame rate measured before a `budget` skip, rounded
// down to one decimal.
std::string event_skip(std::string_view file, std::string_view reason, std::string_view message = {},
                       double fps = -1);
std::string event_error(std::string_view reason, std::string_view message = {});
// A `play` that can't happen: `reason` is "unknown", "skipped",
// "high_frequency", "rpi3_skip" or "load_failed".
std::string event_play_refused(std::string_view preset, std::string_view reason);
// `reload_user` done: live user presets, ids added (new or back), ids
// removed, manifest entries rejected.
std::string event_user_reloaded(size_t presets, size_t added, size_t removed, size_t rejected);
// The selection in force: its generation, the size of the rotation pool
// and whether the playlist (or the hidden set) emptied it, so rotation
// fell back.
std::string event_selection(int64_t gen, size_t eligible, bool playlist_fallback, bool hidden_fallback);
std::string event_exiting(std::string_view reason);

struct StatsSnapshot {
    double fps = 0;          // presented frames per second over the period
    double frame_ms = 0;     // mean CPU render+submit time
    double frame_ms_max = 0;
    double flip_ms = 0;      // mean flip-to-flip interval
    uint64_t frames = 0;
    uint64_t late = 0;       // flips later than the frame interval
    std::string rung;
    int interval = 0;
    double temp_c = -1;      // < 0: unknown
    int arm_mhz = -1;        // < 0: unknown
    double gpu_ms = -1;      // < 0: no timer query
    std::string preset;
    uint64_t pcm_ok = 0;
    uint64_t pcm_silent = 0;
    uint64_t warmups = 0;
    double warmup_ms_max = 0;
    uint64_t shader_stages = 0;  // translated stages warmed up (warp, composite)
    uint64_t cached_stages = 0;  // of those, read from the pack's shader cache
    uint64_t stderr_discarded = 0;  // driver stderr bytes dropped
};

std::string event_stats(const StatsSnapshot& s);

}  // namespace md
