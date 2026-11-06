// EGL on the GBM surface, the internal-resolution render target projectM
// draws into, the upscale to the scanout size, the sentinel-pixel check
// and an optional GPU timer (GL_EXT_disjoint_timer_query, absent on vc4).
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "options.h"

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <gbm.h>

#include <string>

namespace md {

class GlOutput {
public:
    GlOutput() = default;
    ~GlOutput() { destroy(); }
    GlOutput(const GlOutput&) = delete;
    GlOutput& operator=(const GlOutput&) = delete;

    bool init(gbm_device* gbm, gbm_surface* surface, int width, int height, bool gles2, std::string& err);
    void destroy();

    // (Re)creates the internal render target at `size`. False (the old
    // target and size kept) if the new one is incomplete.
    bool set_internal_size(Resolution size);
    Resolution internal_size() const { return internal_; }
    GLuint internal_fbo() const { return fbo_; }

    // Clears the internal target to the sentinel (magenta, alpha 0), which
    // no preset output equals.
    void clear_sentinel();
    // Reads the target's centre pixel back (waiting for the GPU) and
    // returns true if it still holds the sentinel: the frame's draws were
    // dropped.
    bool sentinel_untouched();

    // Draws the internal target onto the scanout surface and swaps.
    bool present_internal();

    // GPU time of recent frames (ms, mean since the last call), or < 0
    // without the extension.
    void gpu_begin();
    void gpu_end();
    double take_gpu_ms();

    const std::string& renderer() const { return renderer_; }
    const std::string& version() const { return version_; }
    bool has_extension(const char* name) const;

private:
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLSurface surface_ = EGL_NO_SURFACE;
    int width_ = 0, height_ = 0;
    Resolution internal_;
    GLuint texture_ = 0, fbo_ = 0, program_ = 0, quad_ = 0;
    GLint image_uniform_ = -1;
    std::string renderer_, version_, extensions_;

    // Optional state resets after projectM (it leaves its VAO / sampler
    // bindings in place).
    void (*bind_vertex_array_)(GLuint) = nullptr;
    void (*bind_sampler_)(GLuint, GLuint) = nullptr;

    // GL_EXT_disjoint_timer_query.
    static constexpr int QUERIES = 4;
    GLuint queries_[QUERIES] = {};
    bool query_active_[QUERIES] = {};
    int query_next_ = 0;
    bool timer_ = false;
    double gpu_ms_sum_ = 0;
    int gpu_samples_ = 0;
    void (*gen_queries_)(GLsizei, GLuint*) = nullptr;
    void (*delete_queries_)(GLsizei, const GLuint*) = nullptr;
    void (*begin_query_)(GLenum, GLuint) = nullptr;
    void (*end_query_)(GLenum) = nullptr;
    void (*get_query_uiv_)(GLuint, GLenum, GLuint*) = nullptr;
    void (*get_query_ui64v_)(GLuint, GLenum, uint64_t*) = nullptr;
    void collect_queries();
};

}  // namespace md
