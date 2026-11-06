// projectM behind a small interface, with the failure signals the
// renderer turns into skips: preset load failures and error-level log
// messages (shader translate / compile errors) since a mark.
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
    void set_texture_dir(const std::string& dir);
    // The pack's pre-translated shader cache, when the fork has the API.
    bool set_shader_cache_dir(const std::string& dir);

    // Compiles a preset ahead of load() where the fork offers it (es2/1d);
    // false when it doesn't, and load() pays the compile instead.
    bool preload(const std::string& path);

    // Loads a preset (translating and compiling its shaders) and starts a
    // blend to it, or a cut.
    void load(const std::string& path, bool smooth);

    void add_pcm(const int16_t* stereo, uint32_t frames);
    // Renders one frame at `time_s` (seconds on the renderer's clock) into
    // `fbo`.
    void render(uint32_t fbo, double time_s);

    // Failure counters, compared before and after a load + warm-up frame.
    uint64_t load_failures() const { return load_failures_; }
    uint64_t error_logs() const { return error_logs_; }
    const std::string& last_error() const { return last_error_; }

private:
    projectm_handle pm_ = nullptr;
    uint64_t load_failures_ = 0;
    uint64_t error_logs_ = 0;
    std::string last_error_;

    static void on_log(const char* message, projectm_log_level level, void* user);
    static void on_switch_failed(const char* file, const char* message, void* user);
};

}  // namespace md
