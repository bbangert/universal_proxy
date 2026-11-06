// KMS output on the HDMI connector: GBM scanout surface, framebuffers,
// DRM master handover and page flips. Everything but take() works without
// DRM master, so all setup happens while Emerge still owns the display.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "options.h"
#include "output_select.h"

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

    // Opens the card, picks `connector` (or, empty, the first connected
    // HDMI one) and its CRTC, and records the mode the CRTC scans out now
    // (Emerge's, while it runs). The mode is chosen by choose_mode
    // (output_select.h), so the CRTC's is kept when it fits. Creates the
    // GBM device and a scanout surface of that size.
    bool open(const std::string& card, const std::string& connector, const DisplayMode& mode,
              std::string& err);
    // Off-screen: a rendering-only GBM surface of `mode`'s size on `card`
    // (a render node is enough). No connector, CRTC or master.
    bool open_headless(const std::string& card, const DisplayMode& mode, std::string& err);
    // A check mode: open_headless plus a simulated display. take() and
    // drop_master() only flip a flag, framebuffers are dummies, and a flip
    // "lands" at the next vblank of `mode`'s refresh (60 Hz without one)
    // through a timer fd. `connector` is only reported back.
    bool open_simulated(const std::string& card, const std::string& connector, const DisplayMode& mode,
                        std::string& err);

    int fd() const { return fd_; }
    // The fd that becomes readable when a flip completes (non-blocking).
    int event_fd() const { return sim_timer_fd_ >= 0 ? sim_timer_fd_ : fd_; }
    gbm_device* gbm() const { return gbm_; }
    gbm_surface* surface() const { return surface_; }
    int width() const { return mode_.hdisplay; }
    int height() const { return mode_.vdisplay; }
    // The chosen mode's exact refresh rate.
    double refresh_hz() const;
    // "WxH@Hz" of the chosen mode.
    std::string mode_str() const;
    // Where the chosen mode came from: mode_source_name(), "" when no
    // display was asked (headless, simulated).
    std::string mode_source_name() const { return has_mode_source_ ? md::mode_source_name(mode_source_) : ""; }
    // The connector presented on ("" without one: headless, simulated).
    const std::string& connector_name() const { return connector_name_; }
    // The CRTC's mode when the card was opened ("" when it had none).
    bool crtc_mode_valid() const { return crtc_mode_valid_; }
    std::string crtc_mode_str() const;

    // The framebuffer for a locked BO (AddFB2 on first use, cached on the
    // BO). 0 on failure.
    uint32_t framebuffer(gbm_bo* bo);

    struct TakeResult {
        double master_ms = 0;
        // The mode set differs from the last one scanned out before the
        // handover: the CRTC's at take time if it still had one, else the
        // one recorded at open.
        bool modeset = true;
        // The CRTC still had a mode at take time. Emerge's stop detaches it
        // (ACTIVE=0, MODE_ID=0), so SetCrtc re-enables it; with `modeset`
        // false that is at the same timing (pixel clock unchanged).
        bool crtc_lit = false;
    };

    // Polls drmSetMaster up to `timeout_ms`, then shows `bo` with SetCrtc
    // in the chosen mode.
    bool take(gbm_bo* bo, int timeout_ms, TakeResult& out, std::string& err);

    // Queues a flip to `bo` with a completion event. EBUSY means a flip is
    // still pending (try later).
    int page_flip(gbm_bo* bo);

    // Dispatches pending DRM events without blocking (the card fd is
    // O_NONBLOCK). Returns true if a flip completed; `t_us` is its
    // CLOCK_MONOTONIC timestamp.
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
    std::string connector_name_;
    ModeSource mode_source_ = ModeSource::Crtc;
    bool has_mode_source_ = false;
    uint32_t crtc_id_ = 0;
    drmModeModeInfo mode_{};
    drmModeModeInfo crtc_mode_{};
    bool crtc_mode_valid_ = false;
    double headless_hz_ = 0;
    bool flip_done_ = false;
    int64_t flip_t_us_ = 0;

    // open_simulated.
    int sim_timer_fd_ = -1;
    bool sim_master_ = false;
    bool sim_flip_pending_ = false;
    int64_t sim_epoch_us_ = 0;
    int64_t sim_flip_us_ = 0;

    static void on_page_flip(int fd, unsigned int frame, unsigned int sec, unsigned int usec, void* data);
};

}  // namespace md
