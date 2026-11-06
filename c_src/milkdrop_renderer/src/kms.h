// KMS output on the HDMI connector: GBM scanout surface, framebuffers,
// DRM master handover and page flips. Everything but take() works without
// DRM master, so all setup happens while Emerge still owns the display.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "options.h"

#include <cstdint>
#include <string>

#include <gbm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

namespace md {

class Kms {
public:
    Kms() = default;
    ~Kms() { close(); }
    Kms(const Kms&) = delete;
    Kms& operator=(const Kms&) = delete;

    // Opens the card, picks the connected HDMI connector, its CRTC and the
    // mode closest to `mode` (same size, non-interlaced, within 0.5 Hz),
    // and creates the GBM device and a scanout surface of that size.
    bool open(const std::string& card, const DisplayMode& mode, std::string& err);
    // Off-screen: a rendering-only GBM surface of `mode`'s size on `card`
    // (a render node is enough). No connector, CRTC or master.
    bool open_headless(const std::string& card, const DisplayMode& mode, std::string& err);

    int fd() const { return fd_; }
    gbm_device* gbm() const { return gbm_; }
    gbm_surface* surface() const { return surface_; }
    int width() const { return mode_.hdisplay; }
    int height() const { return mode_.vdisplay; }
    // The chosen mode's exact refresh rate.
    double refresh_hz() const;

    // The framebuffer for a locked BO (AddFB2 on first use, cached on the
    // BO). 0 on failure.
    uint32_t framebuffer(gbm_bo* bo);

    // Polls drmSetMaster up to `timeout_ms`, then shows `bo` with
    // SetCrtc. The current CRTC mode is reused when it is the chosen one,
    // which the kernel commits without a modeset.
    bool take(gbm_bo* bo, int timeout_ms, double& master_ms, bool& modeset, std::string& err);

    // Queues a flip to `bo` with a completion event. EBUSY means a flip is
    // still pending (try later).
    int page_flip(gbm_bo* bo);

    // Dispatches pending DRM events. Returns true if a flip completed;
    // `t_us` is its CLOCK_MONOTONIC timestamp.
    bool dispatch(int64_t& t_us);

    // Drops our handle to `bo`'s framebuffer without disabling the plane
    // (drmModeCloseFB): the frame stays on screen for the next owner.
    // Never RmFB the scanout framebuffer.
    void close_fb_keep_scanout(gbm_bo* bo);

    void drop_master();
    bool is_master() const;

    // Destroys the surface and device and closes the card.
    void close();

private:
    int fd_ = -1;
    gbm_device* gbm_ = nullptr;
    gbm_surface* surface_ = nullptr;
    uint32_t connector_id_ = 0;
    uint32_t crtc_id_ = 0;
    drmModeModeInfo mode_{};
    double headless_hz_ = 0;
    bool flip_done_ = false;
    int64_t flip_t_us_ = 0;

    static void on_page_flip(int fd, unsigned int frame, unsigned int sec, unsigned int usec, void* data);
};

}  // namespace md
