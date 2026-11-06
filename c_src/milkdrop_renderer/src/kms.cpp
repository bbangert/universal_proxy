#include "kms.h"

#include "pcm_feed.h"  // monotonic_us
#include "stderr_capture.h"  // log_msg

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <drm_fourcc.h>
#include <fcntl.h>
#include <sys/timerfd.h>
#include <unistd.h>

namespace md {

namespace {

double exact_refresh(const drmModeModeInfo& m) {
    if (m.htotal == 0 || m.vtotal == 0) return 0;
    double hz = static_cast<double>(m.clock) * 1000.0 / (static_cast<double>(m.htotal) * m.vtotal);
    if (m.flags & DRM_MODE_FLAG_DBLSCAN) hz /= 2;
    if (m.vscan > 1) hz /= m.vscan;
    return hz;
}

// The fields the kernel's drm_mode_equal() compares (not name or type).
bool same_timing(const drmModeModeInfo& a, const drmModeModeInfo& b) {
    return a.clock == b.clock && a.hdisplay == b.hdisplay && a.hsync_start == b.hsync_start &&
           a.hsync_end == b.hsync_end && a.htotal == b.htotal && a.hskew == b.hskew &&
           a.vdisplay == b.vdisplay && a.vsync_start == b.vsync_start && a.vsync_end == b.vsync_end &&
           a.vtotal == b.vtotal && a.vscan == b.vscan && a.flags == b.flags;
}

// A mode `want` can use: same size, progressive, within 0.5 Hz.
bool fits(const drmModeModeInfo& m, const DisplayMode& want, double& off_hz) {
    if (m.hdisplay != want.size.width || m.vdisplay != want.size.height) return false;
    if (m.flags & DRM_MODE_FLAG_INTERLACE) return false;
    off_hz = std::fabs(exact_refresh(m) - want.refresh);
    return off_hz <= 0.5;
}

std::string describe(const drmModeModeInfo& m) {
    char hz[32];
    std::snprintf(hz, sizeof(hz), "%.2f", exact_refresh(m));
    std::string r = hz;
    while (!r.empty() && r.back() == '0') r.pop_back();
    if (!r.empty() && r.back() == '.') r.pop_back();
    return std::to_string(m.hdisplay) + "x" + std::to_string(m.vdisplay) + "@" + r;
}

void destroy_fb(gbm_bo* bo, void* data) {
    const auto id = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(data));
    if (id != 0) drmModeRmFB(gbm_device_get_fd(gbm_bo_get_device(bo)), id);
}

}  // namespace

double Kms::refresh_hz() const { return headless_hz_ > 0 ? headless_hz_ : exact_refresh(mode_); }

std::string Kms::mode_str() const {
    if (headless_hz_ > 0) return DisplayMode{{mode_.hdisplay, mode_.vdisplay}, headless_hz_}.str();
    return describe(mode_);
}

std::string Kms::crtc_mode_str() const { return crtc_mode_valid_ ? describe(crtc_mode_) : std::string(); }

bool Kms::open_headless(const std::string& card, const DisplayMode& want, std::string& err) {
    fd_ = ::open(card.c_str(), O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd_ < 0) {
        err = "open " + card + ": " + std::strerror(errno);
        return false;
    }
    if (drmIsMaster(fd_)) drmDropMaster(fd_);
    mode_ = {};
    mode_.hdisplay = static_cast<uint16_t>(want.size.width);
    mode_.vdisplay = static_cast<uint16_t>(want.size.height);
    headless_hz_ = want.refresh;
    gbm_ = gbm_create_device(fd_);
    surface_ = gbm_ ? gbm_surface_create(gbm_, mode_.hdisplay, mode_.vdisplay, GBM_FORMAT_XRGB8888,
                                         GBM_BO_USE_RENDERING)
                    : nullptr;
    if (surface_ == nullptr) {
        err = "GBM surface creation failed";
        return false;
    }
    return true;
}

bool Kms::open_simulated(const std::string& card, const DisplayMode& want, std::string& err) {
    if (!open_headless(card, want, err)) return false;
    sim_timer_fd_ = ::timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (sim_timer_fd_ < 0) {
        err = std::string("timerfd_create: ") + std::strerror(errno);
        return false;
    }
    return true;
}

bool Kms::open(const std::string& card, const DisplayMode& want, std::string& err) {
    // Non-blocking: a flip event read must never wait (see dispatch()).
    fd_ = ::open(card.c_str(), O_RDWR | O_CLOEXEC | O_NONBLOCK);
    if (fd_ < 0) {
        err = "open " + card + ": " + std::strerror(errno);
        return false;
    }
    // Opening card0 while nobody holds master makes us master implicitly;
    // stay off it until `take`, so the display's owner is never blocked.
    if (drmIsMaster(fd_)) drmDropMaster(fd_);

    drmModeRes* res = drmModeGetResources(fd_);
    if (res == nullptr) {
        err = std::string("drmModeGetResources: ") + std::strerror(errno);
        return false;
    }
    drmModeConnector* conn = nullptr;
    for (int i = 0; i < res->count_connectors && conn == nullptr; i++) {
        // Current state only: no EDID re-probe (~50 ms).
        drmModeConnector* c = drmModeGetConnectorCurrent(fd_, res->connectors[i]);
        if (c != nullptr && c->connector_type == DRM_MODE_CONNECTOR_HDMIA &&
            c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
            conn = c;
        } else if (c != nullptr) {
            drmModeFreeConnector(c);
        }
    }
    if (conn == nullptr) {
        drmModeFreeResources(res);
        err = "no connected HDMI connector";
        return false;
    }
    connector_id_ = conn->connector_id;

    uint32_t crtc = 0;
    if (conn->encoder_id != 0) {
        if (drmModeEncoder* enc = drmModeGetEncoder(fd_, conn->encoder_id)) {
            crtc = enc->crtc_id;
            drmModeFreeEncoder(enc);
        }
    }
    for (int i = 0; crtc == 0 && i < conn->count_encoders; i++) {
        drmModeEncoder* enc = drmModeGetEncoder(fd_, conn->encoders[i]);
        if (enc == nullptr) continue;
        for (int j = 0; j < res->count_crtcs; j++) {
            if (enc->possible_crtcs & (1u << j)) {
                crtc = res->crtcs[j];
                break;
            }
        }
        drmModeFreeEncoder(enc);
    }
    drmModeFreeResources(res);
    if (crtc == 0) {
        drmModeFreeConnector(conn);
        err = "no CRTC for the HDMI connector";
        return false;
    }
    crtc_id_ = crtc;

    // What the display's owner scans out now. Read here, not at take:
    // Emerge's stop detaches the CRTC (ACTIVE=0, MODE_ID=0), so by then it
    // reports no mode.
    if (drmModeCrtc* c = drmModeGetCrtc(fd_, crtc_id_)) {
        crtc_mode_valid_ = c->mode_valid != 0;
        if (crtc_mode_valid_) crtc_mode_ = c->mode;
        drmModeFreeCrtc(c);
    }

    // Keep the current mode when it fits: a different pixel clock under a
    // running HDMI audio stream leaves vc4's N/CTS stale. Otherwise the
    // closest offered mode. Our systems' EDIDs flag none as preferred, and
    // 1280x720 comes at 60 and 59.94 (both vrefresh 60 in KMS).
    double best = 1e9, off = 0;
    if (crtc_mode_valid_ && fits(crtc_mode_, want, off)) {
        mode_ = crtc_mode_;
        best = off;
    } else {
        for (int i = 0; i < conn->count_modes; i++) {
            if (fits(conn->modes[i], want, off) && off < best) {
                best = off;
                mode_ = conn->modes[i];
            }
        }
    }
    drmModeFreeConnector(conn);
    if (best > 0.5) {
        err = "mode " + want.str() + " not offered";
        return false;
    }

    gbm_ = gbm_create_device(fd_);
    if (gbm_ == nullptr) {
        err = "gbm_create_device failed";
        return false;
    }
    surface_ = gbm_surface_create(gbm_, mode_.hdisplay, mode_.vdisplay, GBM_FORMAT_XRGB8888,
                                  GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
    if (surface_ == nullptr) {
        err = "gbm_surface_create failed";
        return false;
    }
    return true;
}

uint32_t Kms::framebuffer(gbm_bo* bo) {
    if (sim_timer_fd_ >= 0) return 1;  // never handed to KMS
    if (auto cached = reinterpret_cast<uintptr_t>(gbm_bo_get_user_data(bo))) return static_cast<uint32_t>(cached);
    uint32_t handles[4] = {gbm_bo_get_handle(bo).u32};
    uint32_t strides[4] = {gbm_bo_get_stride(bo)};
    uint32_t offsets[4] = {0};
    uint64_t modifiers[4] = {gbm_bo_get_modifier(bo)};
    uint32_t id = 0;
    int r;
    if (modifiers[0] != DRM_FORMAT_MOD_INVALID) {
        r = drmModeAddFB2WithModifiers(fd_, gbm_bo_get_width(bo), gbm_bo_get_height(bo), gbm_bo_get_format(bo),
                                       handles, strides, offsets, modifiers, &id, DRM_MODE_FB_MODIFIERS);
    } else {
        r = drmModeAddFB2(fd_, gbm_bo_get_width(bo), gbm_bo_get_height(bo), gbm_bo_get_format(bo), handles,
                          strides, offsets, &id, 0);
    }
    if (r != 0) return 0;
    gbm_bo_set_user_data(bo, reinterpret_cast<void*>(static_cast<uintptr_t>(id)), &destroy_fb);
    return id;
}

bool Kms::take(gbm_bo* bo, int timeout_ms, TakeResult& out, std::string& err) {
    if (sim_timer_fd_ >= 0) {
        out = {};
        out.modeset = false;
        sim_master_ = true;
        sim_epoch_us_ = monotonic_us();
        return true;
    }
    const int64_t start = monotonic_us();
    while (!drmIsMaster(fd_) && drmSetMaster(fd_) != 0) {
        if (monotonic_us() - start > int64_t{timeout_ms} * 1000) {
            err = std::string("no DRM master: ") + std::strerror(errno);
            return false;
        }
        usleep(2000);
    }
    out.master_ms = static_cast<double>(monotonic_us() - start) / 1000.0;

    uint32_t fb = framebuffer(bo);
    if (fb == 0) {
        err = std::string("AddFB2: ") + std::strerror(errno);
        drmDropMaster(fd_);
        return false;
    }
    // The last mode on screen: the CRTC's now if something still drives it,
    // else the one recorded at open.
    out.crtc_lit = false;
    drmModeModeInfo last{};
    bool last_valid = crtc_mode_valid_;
    if (last_valid) last = crtc_mode_;
    if (drmModeCrtc* c = drmModeGetCrtc(fd_, crtc_id_)) {
        out.crtc_lit = c->mode_valid != 0;
        log_msg("take: CRTC %u %s at take, %s at open", crtc_id_,
                out.crtc_lit ? describe(c->mode).c_str() : "off",
                crtc_mode_valid_ ? describe(crtc_mode_).c_str() : "off");
        if (out.crtc_lit) {
            last = c->mode;
            last_valid = true;
        }
        drmModeFreeCrtc(c);
    }
    out.modeset = !(last_valid && same_timing(last, mode_));
    if (drmModeSetCrtc(fd_, crtc_id_, fb, 0, 0, &connector_id_, 1, &mode_) != 0) {
        err = std::string("SetCrtc: ") + std::strerror(errno);
        drmDropMaster(fd_);
        return false;
    }
    return true;
}

int Kms::page_flip(gbm_bo* bo) {
    if (sim_timer_fd_ >= 0) {
        if (!sim_master_) return -EACCES;
        if (sim_flip_pending_) return -EBUSY;
        const double hz = refresh_hz() > 0 ? refresh_hz() : 60.0;
        const auto period = static_cast<int64_t>(1e6 / hz);
        const int64_t now = monotonic_us();
        sim_flip_us_ = sim_epoch_us_ + ((now - sim_epoch_us_) / period + 1) * period;
        itimerspec its{};
        its.it_value.tv_sec = static_cast<time_t>(sim_flip_us_ / 1000000);
        its.it_value.tv_nsec = static_cast<long>(sim_flip_us_ % 1000000) * 1000;
        if (::timerfd_settime(sim_timer_fd_, TFD_TIMER_ABSTIME, &its, nullptr) != 0) return -errno;
        sim_flip_pending_ = true;
        return 0;
    }
    uint32_t fb = framebuffer(bo);
    if (fb == 0) return -EINVAL;
    flip_done_ = false;
    if (drmModePageFlip(fd_, crtc_id_, fb, DRM_MODE_PAGE_FLIP_EVENT, this) != 0) return -errno;
    return 0;
}

void Kms::on_page_flip(int, unsigned int, unsigned int sec, unsigned int usec, void* data) {
    auto* self = static_cast<Kms*>(data);
    self->flip_done_ = true;
    self->flip_t_us_ = static_cast<int64_t>(sec) * 1000000 + usec;
}

bool Kms::dispatch(int64_t& t_us) {
    if (sim_timer_fd_ >= 0) {
        uint64_t expirations = 0;
        if (::read(sim_timer_fd_, &expirations, sizeof(expirations)) != sizeof(expirations)) return false;
        sim_flip_pending_ = false;
        t_us = sim_flip_us_;
        return true;
    }
    drmEventContext ctx{};
    ctx.version = 2;
    ctx.page_flip_handler = &Kms::on_page_flip;
    flip_done_ = false;
    drmHandleEvent(fd_, &ctx);
    if (!flip_done_) return false;
    t_us = flip_t_us_;
    return true;
}

void Kms::close_fb_keep_scanout(gbm_bo* bo) {
    if (sim_timer_fd_ >= 0) return;
    const auto id = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(gbm_bo_get_user_data(bo)));
    if (id != 0 && drmModeCloseFB(fd_, id) == 0) gbm_bo_set_user_data(bo, nullptr, nullptr);
}

void Kms::drop_master() {
    if (sim_timer_fd_ >= 0) {
        sim_master_ = false;
        return;
    }
    if (fd_ >= 0) drmDropMaster(fd_);
}

bool Kms::is_master() const {
    if (sim_timer_fd_ >= 0) return sim_master_;
    return fd_ >= 0 && drmIsMaster(fd_);
}

void Kms::close() {
    if (sim_timer_fd_ >= 0) ::close(sim_timer_fd_);
    sim_timer_fd_ = -1;
    if (surface_ != nullptr) gbm_surface_destroy(surface_);
    surface_ = nullptr;
    if (gbm_ != nullptr) gbm_device_destroy(gbm_);
    gbm_ = nullptr;
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
}

}  // namespace md
