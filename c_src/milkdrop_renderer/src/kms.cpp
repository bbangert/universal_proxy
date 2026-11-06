#include "kms.h"

#include "pcm_feed.h"  // monotonic_us

#include <cerrno>
#include <cmath>
#include <cstring>
#include <drm_fourcc.h>
#include <fcntl.h>
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

bool same_timing(const drmModeModeInfo& a, const drmModeModeInfo& b) {
    return a.clock == b.clock && a.hdisplay == b.hdisplay && a.hsync_start == b.hsync_start &&
           a.hsync_end == b.hsync_end && a.htotal == b.htotal && a.vdisplay == b.vdisplay &&
           a.vsync_start == b.vsync_start && a.vsync_end == b.vsync_end && a.vtotal == b.vtotal &&
           a.flags == b.flags;
}

void destroy_fb(gbm_bo* bo, void* data) {
    const auto id = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(data));
    if (id != 0) drmModeRmFB(gbm_device_get_fd(gbm_bo_get_device(bo)), id);
}

}  // namespace

double Kms::refresh_hz() const { return headless_hz_ > 0 ? headless_hz_ : exact_refresh(mode_); }

bool Kms::open_headless(const std::string& card, const DisplayMode& want, std::string& err) {
    fd_ = ::open(card.c_str(), O_RDWR | O_CLOEXEC);
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

bool Kms::open(const std::string& card, const DisplayMode& want, std::string& err) {
    fd_ = ::open(card.c_str(), O_RDWR | O_CLOEXEC);
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

    // The closest offered mode. Our systems' EDIDs flag none as preferred,
    // and 1280x720 comes at 60 and 59.94 (both vrefresh 60 in KMS).
    double best = 1e9;
    for (int i = 0; i < conn->count_modes; i++) {
        const drmModeModeInfo& m = conn->modes[i];
        if (m.hdisplay != want.size.width || m.vdisplay != want.size.height) continue;
        if (m.flags & DRM_MODE_FLAG_INTERLACE) continue;
        double d = std::fabs(exact_refresh(m) - want.refresh);
        if (d < best) {
            best = d;
            mode_ = m;
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

bool Kms::take(gbm_bo* bo, int timeout_ms, double& master_ms, bool& modeset, std::string& err) {
    const int64_t start = monotonic_us();
    while (!drmIsMaster(fd_) && drmSetMaster(fd_) != 0) {
        if (monotonic_us() - start > int64_t{timeout_ms} * 1000) {
            err = std::string("no DRM master: ") + std::strerror(errno);
            return false;
        }
        usleep(2000);
    }
    master_ms = static_cast<double>(monotonic_us() - start) / 1000.0;

    uint32_t fb = framebuffer(bo);
    if (fb == 0) {
        err = std::string("AddFB2: ") + std::strerror(errno);
        drmDropMaster(fd_);
        return false;
    }
    drmModeModeInfo mode = mode_;
    modeset = true;
    if (drmModeCrtc* c = drmModeGetCrtc(fd_, crtc_id_)) {
        if (c->mode_valid && same_timing(c->mode, mode_)) {
            mode = c->mode;
            modeset = false;
        }
        drmModeFreeCrtc(c);
    }
    if (drmModeSetCrtc(fd_, crtc_id_, fb, 0, 0, &connector_id_, 1, &mode) != 0) {
        err = std::string("SetCrtc: ") + std::strerror(errno);
        drmDropMaster(fd_);
        return false;
    }
    return true;
}

int Kms::page_flip(gbm_bo* bo) {
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
    const auto id = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(gbm_bo_get_user_data(bo)));
    if (id != 0 && drmModeCloseFB(fd_, id) == 0) gbm_bo_set_user_data(bo, nullptr, nullptr);
}

void Kms::drop_master() {
    if (fd_ >= 0) drmDropMaster(fd_);
}

bool Kms::is_master() const { return fd_ >= 0 && drmIsMaster(fd_); }

void Kms::close() {
    if (surface_ != nullptr) gbm_surface_destroy(surface_);
    surface_ = nullptr;
    if (gbm_ != nullptr) gbm_device_destroy(gbm_);
    gbm_ = nullptr;
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
}

}  // namespace md
