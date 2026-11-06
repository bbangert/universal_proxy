#include "gl_output.h"

#include <EGL/eglext.h>
#include <GLES2/gl2ext.h>

#include <cstring>

#ifndef EGL_PLATFORM_GBM_KHR
#define EGL_PLATFORM_GBM_KHR 0x31D7
#endif
#ifndef GL_TIME_ELAPSED_EXT
#define GL_TIME_ELAPSED_EXT 0x88BF
#endif
#ifndef GL_QUERY_RESULT_EXT
#define GL_QUERY_RESULT_EXT 0x8866
#endif
#ifndef GL_QUERY_RESULT_AVAILABLE_EXT
#define GL_QUERY_RESULT_AVAILABLE_EXT 0x8867
#endif
#ifndef GL_GPU_DISJOINT_EXT
#define GL_GPU_DISJOINT_EXT 0x8FBB
#endif

namespace md {

namespace {

constexpr const char* VERTEX_SHADER =
    "attribute vec2 position;\n"
    "varying vec2 uv;\n"
    "void main() { uv = position * 0.5 + 0.5; gl_Position = vec4(position, 0.0, 1.0); }\n";

constexpr const char* FRAGMENT_SHADER =
    "precision mediump float;\n"
    "varying vec2 uv;\n"
    "uniform sampler2D image;\n"
    "void main() { gl_FragColor = vec4(texture2D(image, uv).rgb, 1.0); }\n";

GLuint compile(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = GL_FALSE;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        glDeleteShader(s);
        return 0;
    }
    return s;
}

template <typename F>
F proc(const char* name) {
    return reinterpret_cast<F>(eglGetProcAddress(name));
}

}  // namespace

bool GlOutput::has_extension(const char* name) const {
    const size_t n = std::strlen(name);
    size_t pos = 0;
    while ((pos = extensions_.find(name, pos)) != std::string::npos) {
        const bool start = pos == 0 || extensions_[pos - 1] == ' ';
        const bool end = pos + n == extensions_.size() || extensions_[pos + n] == ' ';
        if (start && end) return true;
        pos += n;
    }
    return false;
}

bool GlOutput::init(gbm_device* gbm, gbm_surface* surface, int width, int height, bool gles2,
                    std::string& err) {
    width_ = width;
    height_ = height;
    auto get_display = proc<PFNEGLGETPLATFORMDISPLAYEXTPROC>("eglGetPlatformDisplayEXT");
    display_ = get_display ? get_display(EGL_PLATFORM_GBM_KHR, gbm, nullptr) : EGL_NO_DISPLAY;
    EGLint major = 0, minor = 0;
    if (display_ == EGL_NO_DISPLAY || !eglInitialize(display_, &major, &minor)) {
        err = "eglInitialize failed";
        return false;
    }
    eglBindAPI(EGL_OPENGL_ES_API);
    const EGLint config_attribs[] = {EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
                                     EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0,
                                     EGL_RENDERABLE_TYPE, gles2 ? EGL_OPENGL_ES2_BIT : EGL_OPENGL_ES3_BIT,
                                     EGL_NONE};
    EGLConfig configs[64];
    EGLint count = 0;
    eglChooseConfig(display_, config_attribs, configs, 64, &count);
    EGLConfig config = nullptr;
    for (int i = 0; i < count && config == nullptr; i++) {
        EGLint visual = 0;
        eglGetConfigAttrib(display_, configs[i], EGL_NATIVE_VISUAL_ID, &visual);
        if (visual == static_cast<EGLint>(GBM_FORMAT_XRGB8888)) config = configs[i];
    }
    if (config == nullptr) {
        err = "no XRGB8888 EGL config";
        return false;
    }
    const EGLint context_attribs[] = {EGL_CONTEXT_MAJOR_VERSION, gles2 ? 2 : 3, EGL_CONTEXT_MINOR_VERSION, 0,
                                      EGL_NONE};
    context_ = eglCreateContext(display_, config, EGL_NO_CONTEXT, context_attribs);
    if (context_ == EGL_NO_CONTEXT) {
        err = "eglCreateContext failed";
        return false;
    }
    surface_ = eglCreateWindowSurface(display_, config, reinterpret_cast<EGLNativeWindowType>(surface), nullptr);
    if (surface_ == EGL_NO_SURFACE || !eglMakeCurrent(display_, surface_, surface_, context_)) {
        err = "EGL surface creation failed";
        return false;
    }
    auto str = [](GLenum e) {
        const auto* s = reinterpret_cast<const char*>(glGetString(e));
        return std::string(s ? s : "");
    };
    renderer_ = str(GL_RENDERER);
    version_ = str(GL_VERSION);
    extensions_ = str(GL_EXTENSIONS);

    GLuint vs = compile(GL_VERTEX_SHADER, VERTEX_SHADER);
    GLuint fs = compile(GL_FRAGMENT_SHADER, FRAGMENT_SHADER);
    if (vs == 0 || fs == 0) {
        err = "upscale shader compile failed";
        return false;
    }
    program_ = glCreateProgram();
    glAttachShader(program_, vs);
    glAttachShader(program_, fs);
    glBindAttribLocation(program_, 0, "position");
    glLinkProgram(program_);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint linked = GL_FALSE;
    glGetProgramiv(program_, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        err = "upscale shader link failed";
        return false;
    }
    image_uniform_ = glGetUniformLocation(program_, "image");
    const GLfloat quad[] = {-1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f};
    glGenBuffers(1, &quad_);
    glBindBuffer(GL_ARRAY_BUFFER, quad_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    if (gles2) {
        if (has_extension("GL_OES_vertex_array_object"))
            bind_vertex_array_ = proc<void (*)(GLuint)>("glBindVertexArrayOES");
        if (has_extension("GL_MESA_sampler_objects"))
            bind_sampler_ = proc<void (*)(GLuint, GLuint)>("glBindSampler");
    } else {
        bind_vertex_array_ = proc<void (*)(GLuint)>("glBindVertexArray");
        bind_sampler_ = proc<void (*)(GLuint, GLuint)>("glBindSampler");
    }

    if (has_extension("GL_EXT_disjoint_timer_query")) {
        gen_queries_ = proc<decltype(gen_queries_)>("glGenQueriesEXT");
        delete_queries_ = proc<decltype(delete_queries_)>("glDeleteQueriesEXT");
        begin_query_ = proc<decltype(begin_query_)>("glBeginQueryEXT");
        end_query_ = proc<decltype(end_query_)>("glEndQueryEXT");
        get_query_uiv_ = proc<decltype(get_query_uiv_)>("glGetQueryObjectuivEXT");
        get_query_ui64v_ = proc<decltype(get_query_ui64v_)>("glGetQueryObjectui64vEXT");
        timer_ = gen_queries_ && delete_queries_ && begin_query_ && end_query_ && get_query_uiv_ &&
                 get_query_ui64v_;
        if (timer_) gen_queries_(QUERIES, queries_);
    }
    return true;
}

bool GlOutput::set_internal_size(Resolution size) {
    if (size == internal_ && fbo_ != 0) return true;
    if (fbo_ != 0) glDeleteFramebuffers(1, &fbo_);
    if (texture_ != 0) glDeleteTextures(1, &texture_);
    glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, size.width, size.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);
    glGenFramebuffers(1, &fbo_);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture_, 0);
    const bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    internal_ = size;
    return ok;
}

void GlOutput::clear_sentinel() {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glViewport(0, 0, internal_.width, internal_.height);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(1.0f, 0.0f, 1.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

bool GlOutput::sentinel_untouched() {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(internal_.width / 2, internal_.height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return px[0] == 255 && px[1] == 0 && px[2] == 255 && px[3] == 0;
}

bool GlOutput::present_internal() {
    if (bind_vertex_array_ != nullptr) bind_vertex_array_(0);
    if (bind_sampler_ != nullptr) bind_sampler_(0, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, width_, height_);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    glUseProgram(program_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glUniform1i(image_uniform_, 0);
    glBindBuffer(GL_ARRAY_BUFFER, quad_);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glEnableVertexAttribArray(0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    return eglSwapBuffers(display_, surface_) == EGL_TRUE;
}

void GlOutput::gpu_begin() {
    if (!timer_) return;
    collect_queries();
    if (query_active_[query_next_]) return;  // ring full: skip this frame
    begin_query_(GL_TIME_ELAPSED_EXT, queries_[query_next_]);
}

void GlOutput::gpu_end() {
    if (!timer_ || query_active_[query_next_]) return;
    end_query_(GL_TIME_ELAPSED_EXT);
    query_active_[query_next_] = true;
    query_next_ = (query_next_ + 1) % QUERIES;
}

void GlOutput::collect_queries() {
    GLint disjoint = 0;
    glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
    for (int i = 0; i < QUERIES; i++) {
        if (!query_active_[i]) continue;
        GLuint available = 0;
        get_query_uiv_(queries_[i], GL_QUERY_RESULT_AVAILABLE_EXT, &available);
        if (!available) continue;
        uint64_t ns = 0;
        get_query_ui64v_(queries_[i], GL_QUERY_RESULT_EXT, &ns);
        query_active_[i] = false;
        if (!disjoint) {
            gpu_ms_sum_ += static_cast<double>(ns) / 1e6;
            gpu_samples_++;
        }
    }
}

double GlOutput::take_gpu_ms() {
    if (!timer_) return -1;
    collect_queries();
    double ms = gpu_samples_ > 0 ? gpu_ms_sum_ / gpu_samples_ : -1;
    gpu_ms_sum_ = 0;
    gpu_samples_ = 0;
    return ms;
}

void GlOutput::destroy() {
    if (display_ == EGL_NO_DISPLAY) return;
    if (context_ != EGL_NO_CONTEXT) {
        if (timer_) delete_queries_(QUERIES, queries_);
        if (program_ != 0) glDeleteProgram(program_);
        if (quad_ != 0) glDeleteBuffers(1, &quad_);
        if (fbo_ != 0) glDeleteFramebuffers(1, &fbo_);
        if (texture_ != 0) glDeleteTextures(1, &texture_);
    }
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (surface_ != EGL_NO_SURFACE) eglDestroySurface(display_, surface_);
    if (context_ != EGL_NO_CONTEXT) eglDestroyContext(display_, context_);
    eglTerminate(display_);
    display_ = EGL_NO_DISPLAY;
    context_ = EGL_NO_CONTEXT;
    surface_ = EGL_NO_SURFACE;
    program_ = quad_ = fbo_ = texture_ = 0;
}

}  // namespace md
