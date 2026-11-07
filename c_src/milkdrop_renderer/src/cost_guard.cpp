#include "cost_guard.h"

#include <algorithm>

namespace md {

CostGuard::CostGuard(Config config) : config_(config) {
    if (config_.rungs == 0) config_.rungs = 1;
    if (config_.start_interval < 1) config_.start_interval = 1;
    if (config_.window_frames < 2) config_.window_frames = 2;
    const int i0 = config_.start_interval;
    if (i0 == 1) levels_.push_back({0, 1, 0});
    for (size_t r = 0; r < config_.rungs; r++) levels_.push_back({r, i0 == 1 ? 2 : i0, 0});
    apply_floors();
}

void CostGuard::apply_floors() {
    double target = config_.min_fps;
    if (config_.refresh_hz > 0)
        target = std::min(target, config_.refresh_hz / config_.start_interval);
    const double floor = target - MIN_FPS_SLACK;
    const bool half_rate_holds = config_.refresh_hz / 2 >= floor;
    for (GuardLevel& l : levels_) {
        if (l.interval == 1)
            l.min_fps = half_rate_holds ? std::max(0.9 * config_.refresh_hz, floor) : floor;
        else
            l.min_fps = floor;
    }
}

bool CostGuard::reachable(size_t level) const {
    const GuardLevel& l = levels_[level];
    return l.interval == 1 || config_.refresh_hz <= 0 || config_.refresh_hz / l.interval >= l.min_fps;
}

size_t CostGuard::reachable_from(size_t level) const {
    while (level < levels_.size() && !reachable(level)) level++;
    return level;
}

size_t CostGuard::clamp_to_floor(size_t level) const {
    while (level + 1 < levels_.size() && levels_[level].rung < rung_floor_) level++;
    return level;
}

size_t CostGuard::begin(const std::string& file, size_t hint_rung) {
    file_ = file;
    window_.clear();
    settle_left_ = config_.settle_frames;
    last_fps_ = -1;
    auto it = settled_.find(file);
    size_t level = 0;
    if (it != settled_.end()) {
        level = it->second;
    } else {
        while (level + 1 < levels_.size() && levels_[level].rung < hint_rung) level++;
    }
    level = clamp_to_floor(level);
    // No reachable level from here: keep it, its first window skips.
    const size_t usable = reachable_from(level);
    level_ = usable < levels_.size() ? usable : level;
    return level_;
}

CostGuard::Verdict CostGuard::on_flip(int64_t interval_us, bool measurable) {
    if (file_.empty()) return Verdict::None;
    if (!measurable) {
        // A blend in progress: the clean measurement restarts after it.
        settle_left_ = config_.settle_frames;
        window_.clear();
        return Verdict::None;
    }
    if (settle_left_ > 0) {
        settle_left_--;
        return Verdict::None;
    }
    if (interval_us <= 0) return Verdict::None;
    window_.push_back(interval_us);
    if (window_.size() < static_cast<size_t>(config_.window_frames)) return Verdict::None;

    // Mean interval with the single worst one dropped (one hitch is not a
    // trend; the window is long enough for the rest).
    int64_t sum = 0, worst = 0;
    for (int64_t v : window_) {
        sum += v;
        worst = std::max(worst, v);
    }
    const double mean_us =
        static_cast<double>(sum - worst) / static_cast<double>(window_.size() - 1);
    window_.clear();
    const double fps = mean_us > 0 ? 1e6 / mean_us : 0;
    last_fps_ = fps;
    fps_[file_] = fps;

    if (fps >= levels_[level_].min_fps) {
        settled_[file_] = level_;
        return Verdict::Accept;
    }
    const size_t next = reachable_from(level_ + 1);
    if (next >= levels_.size()) {
        settled_.erase(file_);
        file_.clear();
        return Verdict::Skip;
    }
    level_ = next;
    settled_[file_] = level_;
    settle_left_ = config_.settle_frames;
    return Verdict::StepDown;
}

CostGuard::Verdict CostGuard::set_min_fps(double min_fps) {
    if (min_fps == config_.min_fps) return Verdict::None;
    config_.min_fps = min_fps;
    apply_floors();
    settled_.clear();
    if (file_.empty()) return Verdict::None;
    settle_left_ = config_.settle_frames;
    window_.clear();
    if (reachable(level_)) return Verdict::None;
    // The levels below share its interval: none of them can either.
    file_.clear();
    return Verdict::Skip;
}

bool CostGuard::set_rung_floor(size_t rung) {
    rung_floor_ = std::min(rung, config_.rungs - 1);
    size_t clamped = clamp_to_floor(level_);
    if (clamped == level_) return false;
    level_ = clamped;
    if (!file_.empty()) settled_[file_] = level_;
    settle_left_ = config_.settle_frames;
    window_.clear();
    return true;
}

double CostGuard::measured_fps(const std::string& file) const {
    auto it = fps_.find(file);
    return it == fps_.end() ? -1 : it->second;
}

}  // namespace md
