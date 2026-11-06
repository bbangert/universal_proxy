// A synthetic beat for checks without a playing stream (--test-tone):
// a 120 BPM kick, an off-beat hi-hat and a 110 Hz-1.76 kHz sine sweep
// over 8 s, at 44.1 kHz, as the KMS demo used.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <random>
#include <vector>

namespace md {

class TestTone {
public:
    static constexpr int RATE = 44100;

    // Fills `out` (frames * 2 interleaved S16) with the newest `frames`
    // frames up to `t_us` (any monotonic clock), generating what time has
    // passed since the last call.
    void fill(int64_t t_us, uint32_t frames, int16_t* out);

private:
    uint64_t sample_ = 0;
    double sweep_phase_ = 0;
    int64_t last_us_ = 0;
    std::mt19937 rng_{12345};
    std::uniform_real_distribution<double> noise_{-1.0, 1.0};
    std::vector<int16_t> history_;  // the newest frames, interleaved

    void generate(uint32_t n);
};

}  // namespace md
