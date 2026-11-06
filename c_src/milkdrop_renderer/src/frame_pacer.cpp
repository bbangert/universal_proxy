#include "frame_pacer.h"

#include <cmath>

namespace md {

FramePacer::FramePacer(double refresh_hz, int interval)
    : period_us_(static_cast<int64_t>(std::llround(1e6 / (refresh_hz > 1 ? refresh_hz : 60.0)))),
      interval_(interval < 1 ? 1 : interval) {}

void FramePacer::reset(int64_t t_us) { last_flip_us_ = t_us; }

int64_t FramePacer::on_flip(int64_t t_us) {
    int64_t dt = last_flip_us_ > 0 ? t_us - last_flip_us_ : 0;
    last_flip_us_ = t_us;
    // Late: at least half a vblank past the slot.
    if (dt > 0 && dt > interval_ * period_us_ + period_us_ / 2) late_++;
    return dt;
}

int64_t FramePacer::earliest_submit() const {
    if (last_flip_us_ == 0) return 0;
    if (interval_ <= 1) return last_flip_us_;
    return last_flip_us_ + (interval_ - 1) * period_us_ + SUBMIT_MARGIN_US;
}

int64_t FramePacer::predict_present(int64_t now_us, bool flip_pending,
                                    int64_t render_estimate_us) const {
    const int64_t slot = interval_ * period_us_;
    if (last_flip_us_ == 0) return now_us + render_estimate_us + slot;
    int64_t t = last_flip_us_ + slot;
    if (flip_pending) t += slot;
    // Not before the frame can be finished: move along the vblank grid.
    const int64_t ready = now_us + render_estimate_us;
    if (t < ready) {
        const int64_t behind = ready - t;
        t += ((behind + period_us_ - 1) / period_us_) * period_us_;
    }
    return t;
}

}  // namespace md
