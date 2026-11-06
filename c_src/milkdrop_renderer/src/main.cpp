// milkdrop_renderer: full-screen projectM (MilkDrop presets) on the HDMI
// output, driven by the HDMI Sendspin player's PCM tap. A port binary
// owned by UniversalProxy.Display.MilkDrop; CLI, protocol and pack layout
// are in README.md.
//
// Shape of a run:
//   prepare  open card0 (not master), GBM/EGL/projectM, load and warm the
//            first preset, render a frame         -> {"event":"prepared"}
//   take     DRM master (polled, <= 2 s), SetCrtc with that frame
//                                                  -> {"event":"presenting"}
//   present  pipelined: frame N+1 renders while flip N is pending, flips
//            are paced to every `interval` vblanks; presets rotate with a
//            warm-up (preload: compile + draw off-screen, then a sentinel
//            frame) before each blend
//   release  stop flipping, CloseFB (the last frame stays scanned out),
//            drop master, keep card0 open         -> {"event":"released"}
//   exit     tear down                              -> {"event":"exiting"}
//
// Licensed under the Apache License, Version 2.0.

#include "cost_guard.h"
#include "exit_guard.h"
#include "frame_pacer.h"
#include "gl_output.h"
#include "json.h"
#include "kms.h"
#include "manifest.h"
#include "options.h"
#include "pcm_feed.h"
#include "poll_round.h"
#include "preset_manager.h"
#include "preset_selection.h"
#include "protocol.h"
#include "stderr_capture.h"
#include "test_tone.h"
#include "thermal.h"
#include "visualizer.h"

#include <algorithm>
#include <atomic>
#include <bit>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <poll.h>
#include <random>
#include <unistd.h>
#include <vector>

namespace md {
namespace {

#ifdef MILKDROP_GLES2
constexpr bool GLES2 = true;
#else
constexpr bool GLES2 = false;
#endif

std::atomic<int> g_signal{0};
static_assert(std::atomic<int>::is_always_lock_free);  // async-signal-safe
void on_signal(int) { g_signal.store(1); }

// An incoming preset this heavy is cut to, not blended: a blend renders
// both presets at once.
constexpr double CUT_ABOVE_FRAME_MS = 25.0;
constexpr double CUT_BELOW_FPS = 25.0;
// Failed warm-ups tried in one go before the loop runs again (frames,
// commands); selection resumes after.
constexpr int SWITCH_BATCH = 8;
constexpr int64_t FLIP_TIMEOUT_US = 1000000;

struct InFlight {
    gbm_bo* bo = nullptr;
    bool measurable = false;  // reflects the current preset alone
};

class App {
public:
    explicit App(Options opt)
        : opt_(std::move(opt)),
          pcm_(opt_.pcm_ring, int64_t{opt_.av_offset_ms} * 1000) {}

    int run();

private:
    enum class Phase { Prepared, Presenting, Released };

    Options opt_;
    ExitGuard exit_guard_{&g_signal};
    StderrCapture capture_;
    Manifest manifest_;
    std::unique_ptr<PresetManager> presets_;
    std::unique_ptr<CostGuard> guard_;
    std::unique_ptr<FramePacer> pacer_;
    ThermalGuard thermal_;
    PcmFeed pcm_;
    TestTone tone_;
    Kms kms_;
    GlOutput gl_;
    Visualizer vis_;
    LineBuffer stdin_lines_;
    bool stdin_eof_ = false;

    Phase phase_ = Phase::Prepared;
    InFlight front_, pending_, queued_;
    // Buffers left to the display by `release` (framebuffers closed): the
    // one on screen, and a flip that never landed. They stay locked until a
    // new frame replaces them, so they are never redrawn.
    std::vector<gbm_bo*> scanout_left_;
    int64_t pending_since_us_ = 0;

    std::string exit_reason_;
    int exit_code_ = 0;

    // The renderer's clock (projectM time): advances by the predicted
    // presentation interval, excluding warm-up stalls.
    double vtime_ = 0;
    int64_t last_target_us_ = 0;
    int64_t stall_us_ = 0;
    double render_est_us_ = 15000;

    // The playing preset.
    const PresetEntry* current_ = nullptr;
    double blend_until_ = 0;     // vtime the blend into it ends
    bool first_frame_ = false;   // the next frame is its first shown
    int64_t shown_since_us_ = 0; // for rotation, warm-ups excluded

    enum class Switch { None, Rotate, Next, Prev, Eject, Retry };
    Switch requested_ = Switch::None;
    // A batch of candidates failed (Switch::Retry): the cause to report,
    // and whether a failed preset was activated (projectM shows it, so the
    // retry cuts and no frame is rendered until then).
    const char* retry_cause_ = "rotate";
    bool force_cut_ = false;
    int fps_ = 0;  // what projectM was told

    // Stats since the last `stats` event.
    int64_t stats_since_us_ = 0;
    uint64_t st_frames_ = 0, st_late_base_ = 0;
    double st_render_ms_ = 0, st_render_max_ = 0, st_flip_ms_ = 0;
    uint64_t st_flips_ = 0, st_warmups_ = 0, st_shader_stages_ = 0, st_cached_stages_ = 0;
    double st_warmup_max_ = 0;
    uint64_t pcm_ok_base_ = 0, pcm_silent_base_ = 0;
    int64_t last_thermal_us_ = 0;
    double last_temp_ = -1;
    size_t driver_errors_reported_ = 0;

    std::vector<int16_t> pcm_buf_ = std::vector<int16_t>(size_t{PcmFeed::FRAMES} * 2);

    bool prepare();
    void loop();
    void loop_headless();
    void finish();

    void read_stdin();
    void handle_command(const Command& c);
    void take();
    void release(bool announce);

    void present_step();
    void on_flip(int64_t t_us);
    bool render_frame(InFlight& out);
    void apply_switch();
    Selection switch_to(const PresetEntry* first, const char* cause, bool smooth);
    bool warm_up(const PresetEntry& entry, bool smooth, std::string& reason, std::string& message,
                 bool& activated);
    bool apply_level();
    void announce_preset(const char* cause, bool cut);
    void skip_current(const char* reason);

    void housekeeping(int64_t now);
    void report_driver_errors();
    void emit_stats(int64_t now);
    void fail(const char* reason, const std::string& message, int code = 1);
    // The first exit decision wins; it starts the exit guard's budget.
    void decide_exit(const char* reason, int code = 0);
    // The photosensitivity filter, before any frame is rendered.
    void guard_high_frequency();
    bool stdin_hung_up() const;

    std::string preset_path(const PresetEntry& e) const { return opt_.pack_dir + "/presets/" + e.file; }
    Resolution rung_size() const { return opt_.ladder[guard_->current().rung]; }
    size_t hint_rung(const PresetEntry& e) const;
    bool expensive(const PresetEntry& e) const;
};

void App::decide_exit(const char* reason, int code) {
    if (!exit_reason_.empty()) return;
    exit_reason_ = reason;
    exit_code_ = code;
    exit_guard_.arm(exit_reason_, exit_code_);
}

// Decided (and the guard armed) before the writes: a full stdout or
// stderr then can't keep the bounded shutdown from starting.
void App::fail(const char* reason, const std::string& message, int code) {
    decide_exit(reason, code);
    log_msg("%s: %s", reason, message.c_str());
    emit_line(event_error(reason, message));
}

size_t App::hint_rung(const PresetEntry& e) const {
    if (!GLES2 || e.rpi3_rung.width == 0) return 0;
    for (size_t r = 0; r < opt_.ladder.size(); r++)
        if (opt_.ladder[r].area() <= e.rpi3_rung.area()) return r;
    return opt_.ladder.size() - 1;
}

bool App::expensive(const PresetEntry& e) const {
    if (GLES2 && e.rpi3_frame_ms > CUT_ABOVE_FRAME_MS) return true;
    double fps = guard_->measured_fps(e.file);
    return fps > 0 && fps < CUT_BELOW_FPS;
}

// ------------------------------------------------------------- prepare

bool App::prepare() {
    std::string err, text;
    if (!read_file(opt_.pack_dir + "/manifest.json", text)) {
        fail("manifest", "cannot read " + opt_.pack_dir + "/manifest.json");
        return false;
    }
    if (!parse_manifest(text, manifest_, err)) {
        fail("manifest", err);
        return false;
    }
    std::string skip_text;
    std::set<std::string, std::less<>> skipped;
    if (read_file(opt_.skip_file, skip_text)) skipped = parse_skip_list(skip_text);

    PresetManager::Config pcfg;
    pcfg.gles2 = GLES2;
    pcfg.high_frequency = opt_.high_frequency;
    pcfg.seed = opt_.seed != 0 ? opt_.seed : std::random_device{}();
    presets_ = std::make_unique<PresetManager>(manifest_.presets, std::move(skipped), pcfg);
    if (presets_->eligible_count() == 0) {
        fail("no_presets", "no eligible presets in the pack");
        return false;
    }

    const bool opened = opt_.headless_frames > 0 ? kms_.open_headless(opt_.card, opt_.mode, err)
                        : opt_.simulate_kms      ? kms_.open_simulated(opt_.card, opt_.mode, err)
                                                 : kms_.open(opt_.card, opt_.mode, err);
    if (!opened) {
        fail("output", err);
        return false;
    }
    const double refresh = kms_.refresh_hz();
    CostGuard::Config gcfg;
    gcfg.rungs = opt_.ladder.size();
    gcfg.start_interval = opt_.interval > 0 ? opt_.interval : (GLES2 ? 2 : 1);
    gcfg.refresh_hz = refresh;
    gcfg.min_fps = opt_.min_fps;
    guard_ = std::make_unique<CostGuard>(gcfg);
    pacer_ = std::make_unique<FramePacer>(refresh, gcfg.start_interval);

    if (!gl_.init(kms_.gbm(), kms_.surface(), kms_.width(), kms_.height(), GLES2, err)) {
        fail("gl", err);
        return false;
    }
    if (!gl_.set_internal_size(opt_.ladder[0])) {
        fail("gl", "internal framebuffer incomplete");
        return false;
    }
    if (!vis_.create(err)) {
        fail("projectm", err);
        return false;
    }
    fps_ = static_cast<int>(refresh / gcfg.start_interval + 0.5);
    vis_.configure(opt_.ladder[0], opt_.mesh_width, opt_.mesh_height, fps_, opt_.blend_s);
    vis_.set_texture_dir(opt_.pack_dir + "/textures");
    vis_.set_shader_cache_dir(opt_.pack_dir + "/shaders");

    pcm_.maintain(monotonic_us());

    const PresetEntry* first = presets_->start(opt_.locked);
    if (!presets_->refused_lock().empty()) {
        // Not a `skip`: the preset isn't broken, just not eligible here.
        log_msg("--locked %s refused (%s); starting unlocked", opt_.locked.c_str(),
                presets_->refused_lock().c_str());
        emit_line(event_error("locked_refused", presets_->refused_lock() + ": " + opt_.locked));
    }
    Selection sel;
    while ((sel = switch_to(first, "start", false)) == Selection::Deferred) {
        // Nothing reads commands yet; only an exit can interrupt.
        if (g_signal.load() != 0 || stdin_hung_up()) {
            decide_exit(g_signal.load() != 0 ? "signal" : "eof");
            return false;
        }
        first = presets_->rotate();
    }
    if (sel != Selection::Switched) {
        if (exit_reason_.empty()) fail("no_presets", "no preset could be loaded");
        return false;
    }
    // The frame `take` puts on screen.
    if (!render_frame(queued_)) return false;

    log_msg("prepared %s (CRTC at open: %s)", kms_.mode_str().c_str(),
            kms_.crtc_mode_valid() ? kms_.crtc_mode_str().c_str() : "off");
    emit_line(event_prepared(kms_.mode_str(), gl_.renderer(), gl_.version(), GLES2,
                             static_cast<int>(presets_->eligible_count()), kms_.crtc_mode_valid(),
                             kms_.crtc_mode_str()));
    return true;
}

// ------------------------------------------------------------- presets

bool App::apply_level() {
    const int interval = guard_->current().interval;
    pacer_->set_interval(interval);
    const int fps = static_cast<int>(kms_.refresh_hz() / interval + 0.5);
    if (fps != fps_) {
        fps_ = fps;
        vis_.set_fps(fps);
    }
    const Resolution size = rung_size();
    if (gl_.internal_size() != size) {
        if (!gl_.set_internal_size(size)) {
            fail("gl", "internal framebuffer incomplete at " + size.str());
            return false;
        }
        vis_.set_size(size);
    }
    return true;
}

void App::announce_preset(const char* cause, bool cut) {
    if (current_ == nullptr) return;
    emit_line(event_preset(current_->file, presets_->locked(), rung_size().str(), cause, cut));
}

// The P8 warm-up. projectM preloads `entry` (parse, translate or read the
// shader cache, compile, one draw clipped to a pixel so vc4's draw-time
// backend compile happens now) while the last presented frame stays on
// screen and the playing preset and any blend run on untouched. A clean
// preload is activated (blend or cut) and drawn once off-screen at a
// frozen clock over a sentinel; the 1-pixel readback waits for the GPU.
// Driver stderr is synced after each step, so a failure is pinned to this
// preset. `activated` tells the caller a failed preset now holds
// projectM's transition slot.
bool App::warm_up(const PresetEntry& entry, bool smooth, std::string& reason, std::string& message,
                  bool& activated) {
    const int64_t start = monotonic_us();
    activated = false;
    // Driver output of earlier frames is classified before the baseline is
    // taken, so it isn't pinned on this preset. A count change is only
    // attributed when both syncs around it completed.
    const bool synced_before = capture_.sync(300);
    uint64_t ra_base = capture_.register_allocate_failures();
    const uint64_t err0 = vis_.error_logs();
    auto ra_failed = [&](bool synced_after) {
        const uint64_t n = capture_.register_allocate_failures();
        if (n == ra_base) return false;
        if (synced_before && synced_after) return true;
        log_msg("warm-up %s: register allocation failure not attributable (stderr sync timed out)",
                entry.file.c_str());
        ra_base = n;
        return false;
    };

    const Visualizer::LoadResult lr = vis_.preload(preset_path(entry));
    const bool synced_preload = capture_.sync(300);
    const int64_t preloaded = monotonic_us();
    st_shader_stages_ += static_cast<uint64_t>(std::popcount(lr.shader_stages));
    st_cached_stages_ += static_cast<uint64_t>(std::popcount(lr.cached_stages));

    bool dropped = false;
    if (ra_failed(synced_preload)) {
        reason = "register_allocate";
    } else if (!lr.reason.empty()) {
        reason = lr.reason;
        message = lr.message;
    } else if (vis_.error_logs() != err0) {
        reason = "shader_error";
        message = vis_.last_error();
    } else {
        activated = vis_.activate(smooth);
        if (!activated) {
            reason = "load_failed";
        } else {
            gl_.clear_sentinel();
            vis_.render(gl_.internal_fbo(), vtime_ + 0.001);
            vtime_ += 0.001;
            dropped = gl_.sentinel_untouched();
            if (ra_failed(capture_.sync(300))) {
                reason = "register_allocate";
            } else if (vis_.error_logs() != err0) {
                reason = "shader_error";
                message = vis_.last_error();
            } else if (dropped) {
                reason = "draw_dropped";
            }
        }
    }
    if (!activated) vis_.discard();

    const int64_t end = monotonic_us();
    const int64_t took = end - start;
    stall_us_ += took;
    st_warmups_++;
    st_warmup_max_ = std::max(st_warmup_max_, static_cast<double>(took) / 1000.0);
    log_msg("warm-up %s: preload %.0f ms (stages %u, cached %u), activate + frame %.0f ms%s%s",
            entry.file.c_str(), static_cast<double>(preloaded - start) / 1000.0,
            static_cast<unsigned>(std::popcount(lr.shader_stages)),
            static_cast<unsigned>(std::popcount(lr.cached_stages)), static_cast<double>(end - preloaded) / 1000.0,
            reason.empty() ? "" : ", ", reason.c_str());
    return reason.empty();
}

Selection App::switch_to(const PresetEntry* first, const char* cause, bool smooth) {
    bool activated_failure = false;
    const Selection sel = select_preset(*presets_, first, SWITCH_BATCH, [&](const PresetEntry& entry) {
        // The manager never picks one while they are off; this is the last
        // gate before projectM.
        if (entry.high_frequency && !presets_->high_frequency()) {
            log_msg("refusing %s: high_frequency presets are off", entry.file.c_str());
            return Attempt::Failed;
        }
        guard_->begin(entry.file, hint_rung(entry));
        if (!apply_level()) return Attempt::Abort;
        const bool blend = smooth && !activated_failure && opt_.blend_s > 0 && !expensive(entry);
        std::string reason, message;
        bool activated = false;
        if (warm_up(entry, blend, reason, message, activated)) {
            current_ = &entry;
            presets_->on_shown(entry, blend);
            blend_until_ = blend ? vtime_ + opt_.blend_s : vtime_;
            first_frame_ = true;
            shown_since_us_ = monotonic_us();
            announce_preset(cause, !blend);
            return Attempt::Loaded;
        }
        log_msg("skipping %s: %s %s", entry.file.c_str(), reason.c_str(), message.c_str());
        emit_line(event_skip(entry.file, reason, message));
        // An activated failure holds projectM's transition slot: cut past
        // it. A failed preload left the playing preset alone.
        if (activated) activated_failure = true;
        return Attempt::Failed;
    });
    if (sel == Selection::Deferred) {
        force_cut_ = force_cut_ || activated_failure;
        // Until the retry, the playing preset runs at its own level.
        if (current_ != nullptr) {
            guard_->begin(current_->file, hint_rung(*current_));
            if (!apply_level()) return Selection::Aborted;
        }
    } else if (sel == Selection::Switched) {
        force_cut_ = false;
    }
    return sel;
}

void App::skip_current(const char* reason) {
    if (current_ == nullptr) return;
    emit_line(event_skip(current_->file, reason));
    presets_->skip(current_->file);
    requested_ = Switch::Eject;
}

// Photosensitivity: while high_frequency presets are off, a switch away
// from one still rendered (playing or blending out) is always a cut, and
// there is always one: a `prev` with nothing earlier cuts to cut_target().
void App::guard_high_frequency() {
    if (!presets_->high_frequency_on_screen()) return;
    // A frame rendered with it is never shown.
    if (queued_.bo != nullptr) {
        gbm_surface_release_buffer(kms_.surface(), queued_.bo);
        queued_ = {};
    }
    if (requested_ == Switch::None) requested_ = Switch::Eject;
}

void App::apply_switch() {
    const Switch s = requested_;
    requested_ = Switch::None;
    const bool hf = presets_->high_frequency_on_screen();
    const PresetEntry* next = nullptr;
    const char* cause = "rotate";
    switch (s) {
        case Switch::None: break;
        case Switch::Rotate: next = presets_->rotate(); break;
        case Switch::Next: next = presets_->next(); cause = "next"; break;
        case Switch::Prev: next = presets_->prev(); cause = "prev"; break;
        case Switch::Eject: next = hf ? presets_->cut_target() : presets_->rotate(); cause = "eject"; break;
        case Switch::Retry: next = presets_->rotate(); cause = retry_cause_; break;
    }
    if (next == nullptr) {
        if (!hf && (s == Switch::None || s == Switch::Prev)) return;  // nothing earlier
        if (hf) {
            next = presets_->cut_target();
            cause = "eject";
        }
    }
    switch (switch_to(next, cause, !force_cut_ && !hf)) {
        case Selection::Switched: break;
        case Selection::Deferred:
            log_msg("%d presets failed to load; retrying after this frame", SWITCH_BATCH);
            requested_ = Switch::Retry;
            retry_cause_ = cause;
            break;
        case Selection::Exhausted: fail("no_presets", "no eligible presets left"); break;
        case Selection::Aborted:
            if (exit_reason_.empty()) fail("no_presets", "preset selection aborted");
            break;
    }
}

// ------------------------------------------------------------- frames

bool App::render_frame(InFlight& out) {
    const int64_t now = monotonic_us();
    const int64_t target = pacer_->predict_present(now, pending_.bo != nullptr,
                                                   static_cast<int64_t>(render_est_us_));
    if (last_target_us_ != 0) {
        double dt = static_cast<double>(target - last_target_us_ - stall_us_) / 1e6;
        vtime_ += std::clamp(dt, 0.001, 0.1);
    }
    stall_us_ = 0;
    last_target_us_ = target;
    // projectM drops the outgoing preset once its clock passes the blend.
    if (vtime_ >= blend_until_) presets_->on_blend_done();

    if (pcm_.read(target, pcm_buf_.data()) == PcmFeed::Result::Silent && opt_.test_tone)
        tone_.fill(target, PcmFeed::FRAMES, pcm_buf_.data());
    vis_.add_pcm(pcm_buf_.data(), PcmFeed::FRAMES);

    gl_.gpu_begin();
    vis_.render(gl_.internal_fbo(), vtime_);
    const bool swapped = gl_.present_internal();
    gl_.gpu_end();
    if (!swapped) {
        fail("gl", "eglSwapBuffers failed");
        return false;
    }
    gbm_bo* bo = gbm_surface_lock_front_buffer(kms_.surface());
    if (bo == nullptr || (opt_.headless_frames == 0 && kms_.framebuffer(bo) == 0)) {
        if (bo != nullptr) gbm_surface_release_buffer(kms_.surface(), bo);
        fail("kms", std::string("framebuffer for a frame: ") + std::strerror(errno));
        return false;
    }
    out.bo = bo;
    out.measurable = !first_frame_ && vtime_ >= blend_until_;
    first_frame_ = false;

    const double ms = static_cast<double>(monotonic_us() - now) / 1000.0;
    render_est_us_ = 0.9 * render_est_us_ + 0.1 * ms * 1000.0;
    st_render_ms_ += ms;
    st_render_max_ = std::max(st_render_max_, ms);
    st_frames_++;
    return true;
}

void App::on_flip(int64_t t_us) {
    const int64_t dt = pacer_->on_flip(t_us);
    if (front_.bo != nullptr) gbm_surface_release_buffer(kms_.surface(), front_.bo);
    front_ = pending_;
    pending_ = {};
    if (dt > 0) {
        st_flip_ms_ += static_cast<double>(dt) / 1000.0;
        st_flips_++;
    }
    if (current_ == nullptr) return;
    switch (guard_->on_flip(dt, front_.measurable)) {
        case CostGuard::Verdict::StepDown:
            log_msg("%s: %.1f fps, stepping down to %s every %d vblanks", current_->file.c_str(),
                    guard_->last_fps(), rung_size().str().c_str(), guard_->current().interval);
            if (!apply_level()) return;
            first_frame_ = true;
            announce_preset("step_down", false);
            break;
        case CostGuard::Verdict::Skip:
            log_msg("%s: %.1f fps at the last level", current_->file.c_str(), guard_->last_fps());
            skip_current("budget");
            break;
        default: break;
    }
}

void App::present_step() {
    const int64_t now = monotonic_us();
    if (pending_.bo != nullptr && now - pending_since_us_ > FLIP_TIMEOUT_US) {
        fail("output_lost", "page flip did not complete");
        return;
    }
    guard_high_frequency();
    if (pending_.bo == nullptr && queued_.bo != nullptr && now >= pacer_->earliest_submit()) {
        int r = kms_.page_flip(queued_.bo);
        if (r == 0) {
            pending_ = queued_;
            queued_ = {};
            pending_since_us_ = now;
        } else if (r != -EBUSY) {
            fail("output_lost", std::string("page flip: ") + std::strerror(-r));
            return;
        }
    }
    if (queued_.bo == nullptr && gbm_surface_has_free_buffers(kms_.surface())) {
        if (!presets_->locked() && current_ != nullptr && requested_ == Switch::None &&
            now - shown_since_us_ >= int64_t{opt_.rotate_s} * 1000000)
            requested_ = Switch::Rotate;
        if (requested_ != Switch::None) apply_switch();
        if (!exit_reason_.empty()) return;
        // projectM shows a failed preset until the retry: don't present it.
        if (requested_ == Switch::Retry && force_cut_) return;
        // The cut away from a high_frequency preset failed this round: no
        // frame until the retry.
        if (presets_->high_frequency_on_screen()) return;
        render_frame(queued_);
    }
}

// ------------------------------------------------------------- handover

void App::take() {
    if (phase_ == Phase::Presenting) return;
    // A high_frequency preset turned off before the take: cut first (each
    // failed batch skips its candidates, so this ends).
    while (presets_->high_frequency_on_screen() && exit_reason_.empty() && g_signal.load() == 0) {
        guard_high_frequency();
        apply_switch();
    }
    if (!exit_reason_.empty() || presets_->high_frequency_on_screen()) return;
    if (queued_.bo == nullptr && !render_frame(queued_)) return;
    Kms::TakeResult tr;
    std::string err;
    if (!kms_.take(queued_.bo, opt_.master_timeout_ms, tr, err)) {
        log_msg("take failed: %s", err.c_str());
        emit_line(event_error(err.rfind("no DRM master", 0) == 0 ? "master_timeout" : "take_failed", err));
        return;
    }
    front_ = queued_;
    queued_ = {};
    for (gbm_bo* bo : scanout_left_) gbm_surface_release_buffer(kms_.surface(), bo);
    scanout_left_.clear();
    pacer_->reset(monotonic_us());
    guard_->resettle();
    shown_since_us_ = monotonic_us();
    phase_ = Phase::Presenting;
    log_msg("presenting %s (%s, CRTC %s at take), internal %s, master after %.0f ms", kms_.mode_str().c_str(),
            tr.modeset ? "new mode" : "same mode", tr.crtc_lit ? "lit" : "off", rung_size().str().c_str(),
            tr.master_ms);
    emit_line(event_presenting(tr.modeset, tr.master_ms, tr.crtc_lit));
    announce_preset("take", true);
}

void App::release(bool announce) {
    if (phase_ == Phase::Presenting) {
        // Let a queued flip land so the frame left on screen is a whole one.
        const int64_t deadline = monotonic_us() + 200000;
        while (pending_.bo != nullptr && monotonic_us() < deadline) {
            pollfd p{kms_.event_fd(), POLLIN, 0};
            if (poll(&p, 1, 50) > 0) {
                int64_t t = 0;
                if (kms_.dispatch(t)) {
                    if (front_.bo != nullptr) gbm_surface_release_buffer(kms_.surface(), front_.bo);
                    front_ = pending_;
                    pending_ = {};
                }
            }
        }
        if (queued_.bo != nullptr) gbm_surface_release_buffer(kms_.surface(), queued_.bo);
        queued_ = {};
        for (InFlight* f : {&front_, &pending_}) {
            if (f->bo == nullptr) continue;
            kms_.close_fb_keep_scanout(f->bo);
            scanout_left_.push_back(f->bo);
            *f = {};
        }
        kms_.drop_master();
        phase_ = Phase::Released;
        log_msg("released");
    }
    if (announce) emit_line(event_simple("released"));
}

// ------------------------------------------------------------- commands

void App::handle_command(const Command& c) {
    switch (c.type) {
        case Command::Type::Take: take(); break;
        case Command::Type::Release: release(true); break;
        case Command::Type::Exit: decide_exit("requested"); break;
        case Command::Type::Next: requested_ = Switch::Next; break;
        case Command::Type::Prev: requested_ = Switch::Prev; break;
        case Command::Type::Lock:
        case Command::Type::Unlock: {
            const bool lock = c.type == Command::Type::Lock;
            if (presets_->locked() != lock) {
                presets_->set_locked(lock);
                shown_since_us_ = monotonic_us();
                announce_preset(lock ? "lock" : "unlock", false);
            }
            break;
        }
        case Command::Type::SetRotate: opt_.rotate_s = c.int_value; break;
        case Command::Type::SetHighFrequency:
            if (presets_->set_high_frequency(c.bool_value)) guard_high_frequency();
            break;
    }
}

void App::read_stdin() {
    const DrainEnd end = drain_lines(
        stdin_lines_, [](char* buf, size_t cap) { return ::read(STDIN_FILENO, buf, cap); },
        [&](std::string_view line) {
            if (line.empty()) return;
            std::string err;
            if (auto cmd = parse_command(line, err)) {
                handle_command(*cmd);
            } else {
                emit_line(event_error("bad_command", err));
            }
        },
        [&] { return !exit_reason_.empty(); });
    if (end == DrainEnd::Eof) {
        stdin_eof_ = true;
        decide_exit("eof");
    }
}

// ------------------------------------------------------------- loop

void App::report_driver_errors() {
    for (const auto& f : capture_.take_findings()) {
        // Bounded: a broken driver must not flood the BEAM.
        if (driver_errors_reported_ >= 20) continue;
        driver_errors_reported_++;
        emit_line(event_error(f.kind == StderrFinding::Kind::RegisterAllocate ? "register_allocate" : "driver",
                              f.text));
    }
}

void App::emit_stats(int64_t now) {
    const double secs = static_cast<double>(now - stats_since_us_) / 1e6;
    StatsSnapshot s;
    s.fps = secs > 0 && (phase_ == Phase::Presenting || opt_.headless_frames > 0) ? static_cast<double>(st_flips_) / secs : 0;
    s.frames = st_flips_;
    s.frame_ms = st_frames_ > 0 ? st_render_ms_ / static_cast<double>(st_frames_) : 0;
    s.frame_ms_max = st_render_max_;
    s.flip_ms = st_flips_ > 0 ? st_flip_ms_ / static_cast<double>(st_flips_) : 0;
    s.late = pacer_->late() - st_late_base_;
    s.rung = rung_size().str();
    s.interval = pacer_->interval();
    s.temp_c = last_temp_;
    s.arm_mhz = read_cpu_mhz().value_or(-1);
    s.gpu_ms = gl_.take_gpu_ms();
    s.preset = current_ != nullptr ? current_->file : "";
    s.pcm_ok = pcm_.ok - pcm_ok_base_;
    s.pcm_silent = pcm_.silent - pcm_silent_base_;
    s.warmups = st_warmups_;
    s.warmup_ms_max = st_warmup_max_;
    s.shader_stages = st_shader_stages_;
    s.cached_stages = st_cached_stages_;
    s.stderr_discarded = capture_.discarded_bytes();
    emit_line(event_stats(s));

    stats_since_us_ = now;
    st_frames_ = st_flips_ = st_warmups_ = st_shader_stages_ = st_cached_stages_ = 0;
    st_render_ms_ = st_render_max_ = st_flip_ms_ = st_warmup_max_ = 0;
    st_late_base_ = pacer_->late();
    pcm_ok_base_ = pcm_.ok;
    pcm_silent_base_ = pcm_.silent;
}

void App::housekeeping(int64_t now) {
    report_driver_errors();
    if (now - last_thermal_us_ >= 1000000) {
        last_thermal_us_ = now;
        pcm_.maintain(now);
        if (auto t = read_temp_c()) {
            last_temp_ = *t;
            switch (thermal_.update(static_cast<double>(now) / 1e6, *t)) {
                case ThermalGuard::Action::DropRung:
                    if (guard_->set_rung_floor(guard_->rung_floor() + 1)) {
                        if (!apply_level()) break;
                        first_frame_ = true;
                    }
                    log_msg("%.1f C for 10 s: rung floor %s", *t, rung_size().str().c_str());
                    emit_line(event_error("thermal_drop", rung_size().str()));
                    break;
                case ThermalGuard::Action::Exit: decide_exit("thermal"); break;
                case ThermalGuard::Action::None: break;
            }
        }
    }
    if (now - stats_since_us_ >= int64_t{opt_.stats_s} * 1000000) emit_stats(now);
}

void App::loop() {
    stats_since_us_ = monotonic_us();
    while (exit_reason_.empty()) {
        if (g_signal.load() != 0) {
            decide_exit("signal");
            break;
        }
        const int64_t now = monotonic_us();
        int timeout_ms = 200;
        if (phase_ == Phase::Presenting) {
            if (pending_.bo != nullptr) {
                timeout_ms = 50;
            } else if (queued_.bo != nullptr) {
                timeout_ms = static_cast<int>(std::max<int64_t>(0, (pacer_->earliest_submit() - now + 999) / 1000));
            } else {
                timeout_ms = 0;
            }
        }
        auto flip_awaited = [this] { return phase_ == Phase::Presenting && pending_.bo != nullptr; };
        pollfd fds[2];
        nfds_t n = 0;
        int stdin_i = -1, drm_i = -1;
        if (!stdin_eof_) {
            stdin_i = static_cast<int>(n);
            fds[n++] = {STDIN_FILENO, POLLIN, 0};
        }
        if (flip_awaited()) {
            drm_i = static_cast<int>(n);
            fds[n++] = {kms_.event_fd(), POLLIN, 0};
        }
        int r = poll(fds, n, timeout_ms);
        if (r < 0 && errno != EINTR) {
            fail("poll", std::strerror(errno));
            break;
        }
        PollReady ready;
        if (r > 0) {
            ready.flip = drm_i >= 0 && fds[drm_i].revents != 0;
            ready.commands = stdin_i >= 0 && fds[stdin_i].revents != 0;
        }
        handle_poll_round(
            ready, flip_awaited,
            [this] {
                int64_t t = 0;
                if (kms_.dispatch(t)) on_flip(t);
            },
            [this] { read_stdin(); });
        if (!exit_reason_.empty()) break;
        housekeeping(monotonic_us());
        if (phase_ == Phase::Presenting) present_step();
    }
}

// The check mode: frames back to back with a GPU wait each, so the
// "flip" cadence is the real render throughput (no vblank quantisation).
// Rotation, warm-ups, the cost guard and the skip paths all run.
void App::loop_headless() {
    stats_since_us_ = monotonic_us();
    phase_ = Phase::Prepared;
    for (int i = 0; i < opt_.headless_frames && exit_reason_.empty(); i++) {
        if (g_signal.load() != 0) {
            decide_exit("signal");
            break;
        }
        if (!stdin_eof_) {
            pollfd p{STDIN_FILENO, POLLIN, 0};
            if (poll(&p, 1, 0) > 0) read_stdin();
        }
        const int64_t now = monotonic_us();
        housekeeping(now);
        if (!presets_->locked() && requested_ == Switch::None &&
            now - shown_since_us_ >= int64_t{opt_.rotate_s} * 1000000)
            requested_ = Switch::Rotate;
        guard_high_frequency();
        if (requested_ != Switch::None) apply_switch();
        if (!exit_reason_.empty()) break;
        if (presets_->high_frequency_on_screen()) continue;
        if (queued_.bo == nullptr && !render_frame(queued_)) break;
        gl_.sentinel_untouched();  // waits for the GPU
        pending_ = queued_;
        queued_ = {};
        on_flip(monotonic_us());
    }
    emit_stats(monotonic_us());
    decide_exit("headless_done");
}

bool App::stdin_hung_up() const {
    if (stdin_eof_) return true;
    pollfd p{STDIN_FILENO, POLLIN, 0};
    return poll(&p, 1, 0) > 0 && (p.revents & (POLLHUP | POLLERR)) != 0;
}

// From here the exit guard bounds the rest: `exiting` within the budget
// and a prompt exit even if a release or teardown step hangs.
void App::finish() {
    exit_guard_.arm(exit_reason_, exit_code_);
    release(false);
    log_msg("exiting: %s", exit_reason_.c_str());
    emit_line(event_exiting(exit_reason_));
    exit_guard_.exiting_sent();
}

int App::run() {
    if (!capture_.start()) log_msg("stderr capture unavailable; driver errors go to stderr");
    std::signal(SIGPIPE, SIG_IGN);
    // No SA_RESTART: a signal interrupts a blocking call instead of
    // resuming it.
    struct sigaction sa {};
    sa.sa_handler = &on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    exit_guard_.start();
    int fl = fcntl(STDIN_FILENO, F_GETFL);
    if (fl >= 0) fcntl(STDIN_FILENO, F_SETFL, fl | O_NONBLOCK);

    if (prepare()) {
        if (opt_.headless_frames > 0) loop_headless();
        else loop();
    }
    finish();
    const int code = exit_code_;
    // Teardown order: projectM and GL before the surface and the card.
    for (gbm_bo* bo : {queued_.bo, opt_.headless_frames > 0 ? front_.bo : nullptr})
        if (bo != nullptr) gbm_surface_release_buffer(kms_.surface(), bo);
    for (gbm_bo* bo : scanout_left_) gbm_surface_release_buffer(kms_.surface(), bo);
    queued_ = {};
    scanout_left_.clear();
    vis_.destroy();
    gl_.destroy();
    kms_.close();
    capture_.stop();
    exit_guard_.stop();
    return code;
}

}  // namespace
}  // namespace md

int main(int argc, char** argv) {
    std::vector<std::string> args(argv + 1, argv + argc);
    md::Options opt;
    std::string err;
    if (!md::parse_options(args, opt, err)) {
        md::emit_line(md::event_error("usage", err));
        md::emit_line(md::event_exiting("usage"));
        std::fputs(md::USAGE, stderr);
        return 2;
    }
    return md::App(std::move(opt)).run();
}
