#include "test_tone.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace md {

void TestTone::generate(uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        const double t = static_cast<double>(sample_++) / RATE;
        const double beat = std::fmod(t, 0.5);
        const double off_beat = std::fmod(t + 0.25, 0.5);
        // Kick: a sine with a pitch drop from ~170 Hz to 50 Hz.
        const double kick_phase = 2.0 * M_PI * (50.0 * beat + 4.0 * (1.0 - std::exp(-beat * 30.0)));
        const double kick = std::exp(-beat * 9.0) * std::sin(kick_phase);
        const double hat = std::exp(-off_beat * 60.0) * noise_(rng_) * 0.35;
        const double sweep_hz = 110.0 * std::pow(16.0, std::fmod(t, 8.0) / 8.0);
        sweep_phase_ += 2.0 * M_PI * sweep_hz / RATE;
        const double sweep = 0.25 * std::sin(sweep_phase_);
        const double l = std::clamp(0.8 * kick + hat + sweep, -1.0, 1.0);
        const double r = std::clamp(0.8 * kick + 0.7 * hat + sweep, -1.0, 1.0);
        history_.push_back(static_cast<int16_t>(l * 32767));
        history_.push_back(static_cast<int16_t>(r * 32767));
    }
}

void TestTone::fill(int64_t t_us, uint32_t frames, int16_t* out) {
    uint64_t n = frames;
    if (last_us_ != 0 && t_us > last_us_)
        n = std::min<uint64_t>(frames, static_cast<uint64_t>((t_us - last_us_) * RATE / 1000000));
    else if (last_us_ != 0)
        n = 0;
    last_us_ = t_us;
    generate(static_cast<uint32_t>(n));
    const size_t want = size_t{frames} * 2;
    if (history_.size() > want) history_.erase(history_.begin(), history_.end() - static_cast<long>(want));
    const size_t have = history_.size();
    std::memset(out, 0, want * sizeof(int16_t));
    std::memcpy(out + (want - have), history_.data(), have * sizeof(int16_t));
}

}  // namespace md
