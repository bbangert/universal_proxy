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

const char* skip_reason(projectm_preset_load_status status) {
    switch (status) {
        case PROJECTM_PRESET_LOAD_OK: return "";
        case PROJECTM_PRESET_LOAD_TRANSLATE_ERROR: return "translate_error";
        case PROJECTM_PRESET_LOAD_COMPILE_ERROR: return "compile_error";
        case PROJECTM_PRESET_LOAD_LINK_ERROR: return "link_error";
        case PROJECTM_PRESET_LOAD_OTHER_ERROR: break;
    }
    return "load_failed";
}

const char* stage_name(projectm_preset_shader_stage stage) {
    switch (stage) {
        case PROJECTM_PRESET_SHADER_WARP: return "warp";
        case PROJECTM_PRESET_SHADER_COMPOSITE: return "composite";
        case PROJECTM_PRESET_SHADER_NONE: break;
    }
    return "";
}

}  // namespace

void Visualizer::on_load_result(const projectm_preset_load_result* r, void* user) {
    auto* self = static_cast<Visualizer*>(user);
    LoadResult& out = self->last_load_;
    out = {};
    out.reason = skip_reason(r->status);
    const std::string stage = stage_name(r->stage);
    const std::string line = first_line(r->message);
    out.message = stage.empty() || line.empty() ? line : stage + ": " + line;
    out.shader_stages = r->shader_stages;
    out.cached_stages = r->cached_stages;
    self->load_reported_ = true;
}

void Visualizer::on_log(const char* message, projectm_log_level level, void* user) {
    if (level < PROJECTM_LOG_LEVEL_ERROR) return;
    auto* self = static_cast<Visualizer*>(user);
    self->error_logs_++;
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
    projectm_set_preset_load_result_event_callback(pm_, &Visualizer::on_load_result, this);
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

void Visualizer::set_fps(int fps) { projectm_set_fps(pm_, fps); }

void Visualizer::set_texture_dirs(const std::vector<std::string>& dirs) {
    std::vector<const char*> paths;
    for (const std::string& d : dirs) paths.push_back(d.c_str());
    projectm_set_texture_search_paths(pm_, paths.data(), paths.size());
}

void Visualizer::set_shader_cache_dir(const std::string& dir) { projectm_set_shader_cache_dir(pm_, dir.c_str()); }

Visualizer::LoadResult Visualizer::preload(const std::string& path) {
    load_reported_ = false;
    const projectm_preset_load_status status = projectm_preload_preset_file(pm_, path.c_str());
    LoadResult r = load_reported_ ? last_load_ : LoadResult{};
    // The return value has the last word: a preset that loaded but failed
    // its warm-up draw is reported OK to the callback, OTHER_ERROR here.
    const std::string reason = skip_reason(status);
    if (r.reason != reason) {
        r.reason = reason;
        if (r.message.empty() && !reason.empty()) r.message = last_error_;
    }
    return r;
}

bool Visualizer::activate(bool smooth, std::string& message) {
    load_reported_ = false;
    const bool activated = projectm_activate_preloaded_preset(pm_, smooth);
    message = !activated && load_reported_ ? last_load_.message : std::string();
    return activated;
}

void Visualizer::discard() { projectm_discard_preloaded_preset(pm_); }

void Visualizer::add_pcm(const int16_t* stereo, uint32_t frames) {
    projectm_pcm_add_int16(pm_, stereo, frames, PROJECTM_STEREO);
}

void Visualizer::render(uint32_t fbo, double time_s) {
    projectm_set_frame_time(pm_, time_s);
    projectm_opengl_render_frame_fbo(pm_, fbo);
}

}  // namespace md
