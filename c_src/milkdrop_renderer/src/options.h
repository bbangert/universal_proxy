// Command-line options (see README.md for the contract).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace md {

struct Resolution {
    int width = 0;
    int height = 0;

    long area() const { return static_cast<long>(width) * height; }
    std::string str() const { return std::to_string(width) + "x" + std::to_string(height); }
    bool operator==(const Resolution&) const = default;
};

// "WxH" with 1..16384 each.
std::optional<Resolution> parse_resolution(std::string_view s);

struct DisplayMode {
    Resolution size;
    // Hz; none ("WxH") means whatever the output runs at that size (see
    // choose_mode in output_select.h).
    std::optional<double> refresh;

    // The refresh to pace at when there is no display to ask (the
    // headless and simulated check modes).
    double refresh_or_default() const { return refresh.value_or(60.0); }
    std::string str() const;
};

// "WxH@Hz" or "WxH" (no refresh).
std::optional<DisplayMode> parse_mode(std::string_view s);

// A DRM connector name as the kernel builds it ("HDMI-A-1"): 1..32 of
// [A-Za-z0-9-].
bool valid_connector_name(std::string_view s);

// "WxH,WxH,..." highest first, 1..8 rungs, each strictly smaller in area
// than the one before.
std::optional<std::vector<Resolution>> parse_ladder(std::string_view s);

struct Options {
    // Contract (Display.MilkDrop builds these).
    DisplayMode mode;
    std::string pack_dir;
    std::vector<Resolution> ladder;
    int rotate_s = 20;
    std::string skip_file;
    bool high_frequency = false;
    std::string locked;
    std::string pcm_ring;
    // The connector to present on ("" = the first connected HDMI one).
    std::string connector;
    // Uploaded presets: <user_dir>/manifest.json, presets/, textures/
    // ("" = none).
    std::string user_dir;
    // Favourites, hidden presets and the playlist ("" = none).
    std::string selection_file;

    // Tuning and test knobs, not passed by the BEAM.
    std::string card = "/dev/dri/card0";
    double blend_s = 0.5;
    double min_fps = 20.0;   // the frame rate a preset must hold (see CostGuard)
    int interval = 0;        // vblanks per frame; 0 = 2 on GLES2 builds, else 1
    uint64_t seed = 0;       // 0 = random
    int av_offset_ms = 0;    // added to the PCM target time
    int master_timeout_ms = 2000;
    int mesh_width = 48;
    int mesh_height = 36;
    int stats_s = 10;
    // Off-screen check mode: render this many frames on `card` (a render
    // node is enough) without KMS, flips or master, then exit.
    int headless_frames = 0;
    // Check mode: the normal take/present/release protocol on `card` (a
    // render node is enough), with master, SetCrtc and flips simulated
    // (flip events from a vblank timer). Never touches a display.
    bool simulate_kms = false;
    // Feed a synthetic beat whenever the ring has no audio.
    bool test_tone = false;
};

// Parses argv. On failure returns false with `error` set (a short reason
// for the `error` event).
bool parse_options(const std::vector<std::string>& args, Options& out, std::string& error);

extern const char* const USAGE;

}  // namespace md
