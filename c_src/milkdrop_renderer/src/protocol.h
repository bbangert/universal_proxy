// The line-JSON protocol: stdin commands and stdout events (README.md).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

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
    };
    Type type = Type::Exit;
    int int_value = 0;
    bool bool_value = false;
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

// Event lines. Every string field is sanitized and bounded so a line stays
// well under MAX_EMIT_LINE_BYTES; preset file names (at most
// MAX_PRESET_NAME_BYTES, enforced at manifest load) are echoed exactly.
inline constexpr size_t MAX_PRESET_NAME_BYTES = 1024;

std::string event_simple(std::string_view name);
std::string event_prepared(std::string_view mode, std::string_view gl_renderer,
                           std::string_view gl_version, bool gles2, int presets);
std::string event_presenting(bool modeset, double master_ms);
std::string event_preset(std::string_view file, bool locked, std::string_view rung,
                         std::string_view cause, bool cut);
std::string event_skip(std::string_view file, std::string_view reason);
std::string event_error(std::string_view reason, std::string_view message = {});
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
    uint64_t stderr_discarded = 0;  // driver stderr bytes dropped
};

std::string event_stats(const StatsSnapshot& s);

}  // namespace md
