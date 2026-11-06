#include "test_tone.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace md {

namespace {

constexpr double SWEEP_S = 8.0;
constexpr double SWEEP_HZ = 110.0;
constexpr double SWEEP_SPAN = 16.0;  // 110 Hz -> 1.76 kHz

// Cycles of the sweep up to t, mod 1: the integral of
// 110 * 16^((t mod 8) / 8), so any sample is a function of its index alone.
double sweep_cycles(double t) {
    const double k = SWEEP_HZ * SWEEP_S / std::log(SWEEP_SPAN);
    const double per_sweep = std::fmod(k * (SWEEP_SPAN - 1.0), 1.0);
    const double sweeps = std::floor(t / SWEEP_S);
    const double x = t - sweeps * SWEEP_S;
    const double whole = std::fmod(sweeps * per_sweep, 1.0);
    return std::fmod(whole + k * (std::pow(SWEEP_SPAN, x / SWEEP_S) - 1.0), 1.0);
}

// Hi-hat noise in [-1, 1], hashed from the sample index (splitmix64).
double noise(uint64_t i) {
    uint64_t z = i + 0x9E3779B97F4A7C15ULL;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) / static_cast<double>(1ULL << 52) - 1.0;
}

}  // namespace

void TestTone::generate(uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        const uint64_t s = sample_++;
        const double t = static_cast<double>(s) / RATE;
        const double beat = std::fmod(t, 0.5);
        const double off_beat = std::fmod(t + 0.25, 0.5);
        // Kick: a sine with a pitch drop from ~170 Hz to 50 Hz.
        const double kick_phase = 2.0 * M_PI * (50.0 * beat + 4.0 * (1.0 - std::exp(-beat * 30.0)));
        const double kick = std::exp(-beat * 9.0) * std::sin(kick_phase);
        const double hat = std::exp(-off_beat * 60.0) * noise(s) * 0.35;
        const double sweep = 0.25 * std::sin(2.0 * M_PI * sweep_cycles(t));
        const double l = std::clamp(0.8 * kick + hat + sweep, -1.0, 1.0);
        const double r = std::clamp(0.8 * kick + 0.7 * hat + sweep, -1.0, 1.0);
        history_.push_back(static_cast<int16_t>(l * 32767));
        history_.push_back(static_cast<int16_t>(r * 32767));
    }
}

void TestTone::fill(int64_t t_us, uint32_t frames, int16_t* out) {
    uint64_t n = 0;
    if (!started_) {
        started_ = true;
        n = frames;
        base_us_ = t_us;
        base_sample_ = frames;
    } else if (t_us > base_us_) {
        // From the first call's time, so per-call rounding doesn't drift.
        const uint64_t end = base_sample_ + static_cast<uint64_t>((t_us - base_us_) * RATE / 1000000);
        if (end > sample_) n = end - sample_;
    }
    // Only the newest `frames` are kept: step over the rest.
    if (n > frames) {
        sample_ += n - frames;
        history_.clear();
        n = frames;
    }
    generate(static_cast<uint32_t>(n));
    const size_t want = size_t{frames} * 2;
    if (history_.size() > want) history_.erase(history_.begin(), history_.end() - static_cast<long>(want));
    const size_t have = history_.size();
    std::memset(out, 0, want * sizeof(int16_t));
    std::memcpy(out + (want - have), history_.data(), have * sizeof(int16_t));
}

}  // namespace md
