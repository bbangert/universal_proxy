// projectM behind a small interface, with the failure signals the
// renderer turns into skips: per-preset load results (the fork's es2/1d
// API) and error-level log messages since a mark.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "options.h"

#include <projectM-4/projectM.h>

#include <cstdint>
#include <string>

namespace md {

class Visualizer {
public:
    Visualizer() = default;
    ~Visualizer() { destroy(); }
    Visualizer(const Visualizer&) = delete;
    Visualizer& operator=(const Visualizer&) = delete;

    bool create(std::string& err);
    void destroy();

    // Fixed settings: projectM never switches presets on its own (the
    // renderer drives rotation), and time comes from set_frame_time.
    void configure(Resolution size, int mesh_w, int mesh_h, int fps, double blend_s);
    void set_size(Resolution size);
    // The frame rate preset expressions assume (projectM advances per-frame
    // state by 1/fps): the presented rate, refresh / interval.
    void set_fps(int fps);
    void set_texture_dir(const std::string& dir);
    // The pack's pre-translated shaders (keys include the GLSL target, so
    // another target's files just miss).
    void set_shader_cache_dir(const std::string& dir);

    struct LoadResult {
        // "" when the preset loaded cleanly; else the skip reason:
        // translate_error, compile_error, link_error (shader failures:
        // projectM fell back to its default shaders) or load_failed.
        std::string reason;
        std::string message;  // "<stage>: <first line>", bounded
        uint32_t shader_stages = 0;  // projectm_preset_shader_stage bits
        uint32_t cached_stages = 0;  // of those, read from the shader cache
    };

    // Loads a preset without switching to it: parses it, translates and
    // compiles its shaders and draws it once off-screen (clipped to one
    // pixel, so vc4's draw-time backend compile happens here). The playing
    // preset, a running blend and the screen are untouched.
    LoadResult preload(const std::string& path);
    // Starts a blend (or a cut) to the preloaded preset.
    bool activate(bool smooth);
    void discard();

    void add_pcm(const int16_t* stereo, uint32_t frames);
    // Renders one frame at `time_s` (seconds on the renderer's clock) into
    // `fbo`.
    void render(uint32_t fbo, double time_s);

    // Error-level log messages, compared before and after a warm-up.
    uint64_t error_logs() const { return error_logs_; }
    const std::string& last_error() const { return last_error_; }

private:
    projectm_handle pm_ = nullptr;
    uint64_t error_logs_ = 0;
    std::string last_error_;
    LoadResult last_load_;
    bool load_reported_ = false;

    static void on_log(const char* message, projectm_log_level level, void* user);
    static void on_load_result(const projectm_preset_load_result* result, void* user);
};

}  // namespace md
