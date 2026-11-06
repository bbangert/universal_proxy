#include "visualizer.h"

#include "json.h"

#include <EGL/egl.h>

namespace md {

namespace {

void* load_proc(const char* name, void*) { return reinterpret_cast<void*>(eglGetProcAddress(name)); }

// The first line, bounded: projectM's translator errors carry the whole
// shader source after a newline.
std::string first_line(const char* s) {
    std::string_view v(s ? s : "");
    return sanitize_text(v.substr(0, v.find('\n')), 256);
}

}  // namespace

void Visualizer::on_log(const char* message, projectm_log_level level, void* user) {
    if (level < PROJECTM_LOG_LEVEL_ERROR) return;
    auto* self = static_cast<Visualizer*>(user);
    self->error_logs_++;
    self->last_error_ = first_line(message);
}

void Visualizer::on_switch_failed(const char*, const char* message, void* user) {
    auto* self = static_cast<Visualizer*>(user);
    self->load_failures_++;
    self->last_error_ = first_line(message);
}

bool Visualizer::create(std::string& err) {
    projectm_set_log_callback(&Visualizer::on_log, false, this);
    projectm_set_log_level(PROJECTM_LOG_LEVEL_ERROR, false);
    pm_ = projectm_create_with_opengl_load_proc(&load_proc, nullptr);
    if (pm_ == nullptr) {
        err = "projectm_create failed";
        return false;
    }
    projectm_set_preset_switch_failed_event_callback(pm_, &Visualizer::on_switch_failed, this);
    return true;
}

void Visualizer::destroy() {
    if (pm_ != nullptr) projectm_destroy(pm_);
    pm_ = nullptr;
    projectm_set_log_callback(nullptr, false, nullptr);
}

void Visualizer::configure(Resolution size, int mesh_w, int mesh_h, int fps, double blend_s) {
    projectm_set_window_size(pm_, static_cast<size_t>(size.width), static_cast<size_t>(size.height));
    projectm_set_mesh_size(pm_, static_cast<size_t>(mesh_w), static_cast<size_t>(mesh_h));
    projectm_set_fps(pm_, fps);
    projectm_set_preset_locked(pm_, true);
    projectm_set_preset_duration(pm_, 1e9);
    projectm_set_hard_cut_enabled(pm_, false);
    projectm_set_soft_cut_duration(pm_, blend_s > 0 ? blend_s : 0.001);
}

void Visualizer::set_size(Resolution size) {
    projectm_set_window_size(pm_, static_cast<size_t>(size.width), static_cast<size_t>(size.height));
}

void Visualizer::set_texture_dir(const std::string& dir) {
    const char* paths[] = {dir.c_str()};
    projectm_set_texture_search_paths(pm_, paths, 1);
}

bool Visualizer::set_shader_cache_dir(const std::string& dir) {
#ifdef MILKDROP_HAVE_SHADER_CACHE
    projectm_set_shader_cache_dir(pm_, dir.c_str());
    return true;
#else
    (void)dir;
    return false;
#endif
}

bool Visualizer::preload(const std::string& path) {
#ifdef MILKDROP_HAVE_PRELOAD
    // The es2/1d API; align the call here if its final signature differs.
    return projectm_preload_preset_file(pm_, path.c_str());
#else
    (void)path;
    return false;
#endif
}

void Visualizer::load(const std::string& path, bool smooth) {
    projectm_load_preset_file(pm_, path.c_str(), smooth);
}

void Visualizer::add_pcm(const int16_t* stereo, uint32_t frames) {
    projectm_pcm_add_int16(pm_, stereo, frames, PROJECTM_STEREO);
}

void Visualizer::render(uint32_t fbo, double time_s) {
    projectm_set_frame_time(pm_, time_s);
    projectm_opengl_render_frame_fbo(pm_, fbo);
}

}  // namespace md
