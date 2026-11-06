// md_bright: render one preset off-screen and report how bright it gets.
//
//   md_bright --preset FILE [--texture-path DIR] [--size 640x360] [--frames 600]
//             [--from 150] [--fps 30] [--mesh 48x36] [--png-at N]... [--png-prefix P]
//             [--tsv FILE]
//
// Renders FILE (projectM, desktop GL 3.3 core on an EGL surfaceless context)
// for --frames frames of deterministic music-like PCM at --fps, reads every
// frame back and prints one JSON line:
//
//   {"frames":600,"from":150,"luma":..., "sat":..., "r":..,"g":..,"b":..,
//    "load_status":0,"load_message":"..."}
//
// luma is the mean Rec.601 luma (0..255) and sat the mean fraction of pixels
// with any channel >= 250, both over frames --from..--frames. --png-at
// writes <prefix>.<N>.png snapshots; --tsv the per-frame values.
// Exits 0 on success, 2 on usage, 1 if GL or projectM can't start or the
// preset doesn't load as written: it can't be loaded at all
// ({"error":"load_failed"}) or a shader stage failed and projectM fell back
// to its default shaders ({"error":"shader_failed"}), which would measure the
// fallback instead of the preset. Both print one JSON line and draw nothing.

#include <projectM-4/projectM.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

namespace {

// Just the GL entry points this tool calls itself (projectM loads its own).
using GLuint = unsigned int;
using GLenum = unsigned int;
using GLint = int;
using GLsizei = int;
constexpr GLenum kTexture2D = 0x0DE1, kRGBA = 0x1908, kUnsignedByte = 0x1401, kFramebuffer = 0x8D40,
                 kColorAttachment0 = 0x8CE0, kTexMinFilter = 0x2801, kLinear = 0x2601;
struct Gl {
    void (*GenTextures)(GLsizei, GLuint*);
    void (*BindTexture)(GLenum, GLuint);
    void (*TexParameteri)(GLenum, GLenum, GLint);
    void (*TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*);
    void (*GenFramebuffers)(GLsizei, GLuint*);
    void (*BindFramebuffer)(GLenum, GLuint);
    void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
    void (*ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*);
    GLenum (*GetError)();
};

template <typename T>
bool load(T& fn, const char* name) {
    fn = reinterpret_cast<T>(eglGetProcAddress(name));
    return fn != nullptr;
}

void* load_proc(const char* name, void*) { return reinterpret_cast<void*>(eglGetProcAddress(name)); }

void log_cb(const char* message, projectm_log_level level, void*) {
    if (level >= PROJECTM_LOG_LEVEL_ERROR) std::fprintf(stderr, "[projectM] %s\n", message);
}

struct LoadResult {
    int status = -1;  // -1: projectM never reported a load result
    int stage = 0;
    std::string message;
    bool failed = false;
};

void load_result_cb(const projectm_preset_load_result* r, void* user) {
    auto* out = static_cast<LoadResult*>(user);
    out->status = static_cast<int>(r->status);
    out->stage = static_cast<int>(r->stage);
    out->message = r->message != nullptr ? r->message : "";
}

void switch_failed_cb(const char*, const char* message, void* user) {
    auto* out = static_cast<LoadResult*>(user);
    out->failed = true;
    if (out->message.empty() && message != nullptr) out->message = message;
}

std::string json_escape(const std::string& s) {
    std::string o;
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') {
            o += '\\';
            o += static_cast<char>(c);
        } else if (c < 0x20 || c > 0x7E) {
            char b[8];
            std::snprintf(b, sizeof b, "\\u%04x", c);
            o += b;
        } else {
            o += static_cast<char>(c);
        }
    }
    return o;
}

// Deterministic music-like stereo PCM: a 120 BPM kick (pitch sweep, fast
// decay), an off-beat snare of noise, 8th-note hats, a 4-note bass line, a pad
// chord and a pink-ish noise floor.
struct Music {
    unsigned s = 12345;
    double lp = 0, hp_prev = 0;
    double rnd() {
        s = s * 1664525u + 1013904223u;
        return ((s >> 8) & 0xffff) / 32768.0 - 1.0;
    }
    void gen(double t0, int rate, std::vector<float>& pcm) {
        for (size_t i = 0; i < pcm.size() / 2; i++) {
            const double t = t0 + static_cast<double>(i) / rate;
            const double beat = std::fmod(t, 0.5), b8 = std::fmod(t, 0.25), bar = std::fmod(t, 2.0);
            const double kick =
                std::sin(2 * M_PI * (45 * beat + 110 * (1 - std::exp(-beat * 30)) / 30)) * std::exp(-beat * 9) * 0.8;
            const double n = rnd();
            const double hp = n - hp_prev;
            hp_prev = n;
            const double off = std::fmod(t + 0.5, 1.0);
            const double snare = (off < 0.25 ? 1 : 0) * std::exp(-off * 14) * n * 0.45;
            const double hat = hp * std::exp(-b8 * 40) * 0.30;
            const int step = static_cast<int>(bar * 2) % 4;
            const double note = 55.0 * std::pow(2.0, (step == 3 ? 5 : (step == 1 ? 3 : 0)) / 12.0);
            const double bass = std::sin(2 * M_PI * note * t) * 0.25 * (0.6 + 0.4 * std::sin(2 * M_PI * 0.25 * t));
            const double pad =
                (std::sin(2 * M_PI * 220 * t) + std::sin(2 * M_PI * 277.2 * t) + std::sin(2 * M_PI * 329.6 * t)) * 0.06;
            lp += 0.12 * (rnd() - lp);
            const double pink = lp * 0.6;
            const double l = kick + snare + hat + bass + pad + pink + rnd() * 0.06;
            const double r = kick + snare * 0.8 + hat * 1.1 + bass + pad * 0.9 + pink * 0.9 + rnd() * 0.06;
            pcm[2 * i] = static_cast<float>(std::fmax(-0.95, std::fmin(0.95, l)));
            pcm[2 * i + 1] = static_cast<float>(std::fmax(-0.95, std::fmin(0.95, r)));
        }
    }
};

int usage() {
    std::fprintf(stderr,
                 "usage: md_bright --preset FILE [--texture-path DIR] [--size WxH] [--frames N] [--from N]\n"
                 "                 [--fps N] [--mesh WxH] [--png-at N]... [--png-prefix P] [--tsv FILE]\n");
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    int w = 640, h = 360, frames = 600, from = 150, fps = 30, mesh_w = 48, mesh_h = 36;
    std::string preset, textures, png_prefix, tsv;
    std::set<int> png_at;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        const bool has = i + 1 < argc;
        if (a == "--preset" && has) preset = argv[++i];
        else if (a == "--texture-path" && has) textures = argv[++i];
        else if (a == "--size" && has) { if (std::sscanf(argv[++i], "%dx%d", &w, &h) != 2) return usage(); }
        else if (a == "--mesh" && has) { if (std::sscanf(argv[++i], "%dx%d", &mesh_w, &mesh_h) != 2) return usage(); }
        else if (a == "--frames" && has) frames = std::atoi(argv[++i]);
        else if (a == "--from" && has) from = std::atoi(argv[++i]);
        else if (a == "--fps" && has) fps = std::atoi(argv[++i]);
        else if (a == "--png-at" && has) png_at.insert(std::atoi(argv[++i]));
        else if (a == "--png-prefix" && has) png_prefix = argv[++i];
        else if (a == "--tsv" && has) tsv = argv[++i];
        else return usage();
    }
    if (preset.empty() || w < 16 || h < 16 || w > 4096 || h > 4096 || frames < 1 || from < 1 || from > frames ||
        fps < 1 || fps > 240 || mesh_w < 8 || mesh_h < 8)
        return usage();

    auto get_display = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (get_display == nullptr) { std::fprintf(stderr, "no eglGetPlatformDisplayEXT\n"); return 1; }
    EGLDisplay dpy = get_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, nullptr);
    EGLint major = 0, minor = 0;
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &major, &minor) || !eglBindAPI(EGL_OPENGL_API)) {
        std::fprintf(stderr, "EGL surfaceless init failed\n");
        return 1;
    }
    const EGLint ctx_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 3,
                                EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attrs);
    if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        std::fprintf(stderr, "GL 3.3 core context failed\n");
        return 1;
    }
    Gl gl{};
    if (!load(gl.GenTextures, "glGenTextures") || !load(gl.BindTexture, "glBindTexture") ||
        !load(gl.TexParameteri, "glTexParameteri") || !load(gl.TexImage2D, "glTexImage2D") ||
        !load(gl.GenFramebuffers, "glGenFramebuffers") || !load(gl.BindFramebuffer, "glBindFramebuffer") ||
        !load(gl.FramebufferTexture2D, "glFramebufferTexture2D") || !load(gl.ReadPixels, "glReadPixels") ||
        !load(gl.GetError, "glGetError")) {
        std::fprintf(stderr, "GL entry points missing\n");
        return 1;
    }
    GLuint tex = 0, fbo = 0;
    gl.GenTextures(1, &tex);
    gl.BindTexture(kTexture2D, tex);
    gl.TexParameteri(kTexture2D, kTexMinFilter, kLinear);
    gl.TexImage2D(kTexture2D, 0, kRGBA, w, h, 0, kRGBA, kUnsignedByte, nullptr);
    gl.GenFramebuffers(1, &fbo);
    gl.BindFramebuffer(kFramebuffer, fbo);
    gl.FramebufferTexture2D(kFramebuffer, kColorAttachment0, kTexture2D, tex, 0);
    gl.BindFramebuffer(kFramebuffer, 0);

    projectm_set_log_callback(&log_cb, false, nullptr);
    projectm_handle pm = projectm_create_with_opengl_load_proc(&load_proc, nullptr);
    if (pm == nullptr) { std::fprintf(stderr, "projectm_create failed\n"); return 1; }
    LoadResult result;
    projectm_set_preset_load_result_event_callback(pm, &load_result_cb, &result);
    projectm_set_preset_switch_failed_event_callback(pm, &switch_failed_cb, &result);
    projectm_set_window_size(pm, static_cast<size_t>(w), static_cast<size_t>(h));
    projectm_set_mesh_size(pm, static_cast<size_t>(mesh_w), static_cast<size_t>(mesh_h));
    projectm_set_fps(pm, fps);
    projectm_set_preset_locked(pm, true);
    if (!textures.empty()) {
        const char* paths[] = {textures.c_str()};
        projectm_set_texture_search_paths(pm, paths, 1);
    }
    projectm_load_preset_file(pm, preset.c_str(), false);
    if (result.failed) {
        std::printf("{\"error\":\"load_failed\",\"message\":\"%s\"}\n", json_escape(result.message).c_str());
        projectm_destroy(pm);
        return 1;
    }
    if (result.status != PROJECTM_PRESET_LOAD_OK) {
        const bool shader = result.status == PROJECTM_PRESET_LOAD_TRANSLATE_ERROR ||
                            result.status == PROJECTM_PRESET_LOAD_COMPILE_ERROR ||
                            result.status == PROJECTM_PRESET_LOAD_LINK_ERROR;
        std::printf("{\"error\":\"%s\",\"load_status\":%d,\"stage\":%d,\"message\":\"%s\"}\n",
                    shader ? "shader_failed" : "load_status", result.status, result.stage,
                    json_escape(result.message.substr(0, 2000)).c_str());
        projectm_destroy(pm);
        return 1;
    }

    FILE* tf = tsv.empty() ? nullptr : std::fopen(tsv.c_str(), "w");
    if (tf != nullptr) std::fprintf(tf, "frame\tr\tg\tb\tluma\tsat\n");
    const int rate = 44100;
    std::vector<float> pcm(2 * static_cast<size_t>(rate / fps));
    std::vector<unsigned char> px(static_cast<size_t>(w) * h * 4), rgb;
    Music music;
    double t = 0, sum_r = 0, sum_g = 0, sum_b = 0, sum_sat = 0;
    int counted = 0;
    const size_t np = static_cast<size_t>(w) * h;
    for (int f = 1; f <= frames; f++) {
        music.gen(t, rate, pcm);
        projectm_pcm_add_float(pm, pcm.data(), static_cast<unsigned int>(pcm.size() / 2), PROJECTM_STEREO);
        projectm_set_frame_time(pm, t);
        t += 1.0 / fps;
        projectm_opengl_render_frame_fbo(pm, fbo);
        gl.BindFramebuffer(kFramebuffer, fbo);
        gl.ReadPixels(0, 0, w, h, kRGBA, kUnsignedByte, px.data());
        gl.BindFramebuffer(kFramebuffer, 0);
        double r = 0, g = 0, b = 0;
        size_t sat = 0;
        for (size_t i = 0; i < np; i++) {
            const unsigned char* p = &px[i * 4];
            r += p[0];
            g += p[1];
            b += p[2];
            sat += (p[0] >= 250 || p[1] >= 250 || p[2] >= 250) ? 1 : 0;
        }
        r /= static_cast<double>(np);
        g /= static_cast<double>(np);
        b /= static_cast<double>(np);
        const double frac = static_cast<double>(sat) / static_cast<double>(np);
        if (f >= from) {
            sum_r += r;
            sum_g += g;
            sum_b += b;
            sum_sat += frac;
            counted++;
        }
        if (tf != nullptr)
            std::fprintf(tf, "%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.5f\n", f, r, g, b, 0.299 * r + 0.587 * g + 0.114 * b,
                         frac);
        if (!png_prefix.empty() && png_at.count(f) != 0) {
            rgb.resize(np * 3);
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    for (int k = 0; k < 3; k++)
                        rgb[(static_cast<size_t>(h - 1 - y) * w + x) * 3 + k] = px[(static_cast<size_t>(y) * w + x) * 4 + k];
            const std::string name = png_prefix + "." + std::to_string(f) + ".png";
            stbi_write_png(name.c_str(), w, h, 3, rgb.data(), w * 3);
        }
    }
    if (tf != nullptr) std::fclose(tf);
    const GLenum err = gl.GetError();
    const double mr = sum_r / counted, mg = sum_g / counted, mb = sum_b / counted;
    std::printf(
        "{\"frames\":%d,\"from\":%d,\"luma\":%.3f,\"sat\":%.5f,\"r\":%.3f,\"g\":%.3f,\"b\":%.3f,"
        "\"load_status\":%d,\"load_message\":\"%s\",\"gl_error\":%u}\n",
        frames, from, 0.299 * mr + 0.587 * mg + 0.114 * mb, sum_sat / counted, mr, mg, mb, result.status,
        json_escape(result.message.substr(0, 200)).c_str(), err);
    projectm_destroy(pm);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    return 0;
}
