// A synthetic beat for checks without a playing stream (--test-tone):
// a 120 BPM kick, an off-beat hi-hat and a 110 Hz-1.76 kHz sine sweep
// over 8 s, at 44.1 kHz, as the KMS demo used.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstdint>
#include <vector>

namespace md {

class TestTone {
public:
    static constexpr int RATE = 44100;

    // Fills `out` (frames * 2 interleaved S16) with the newest `frames`
    // frames up to `t_us` (any monotonic clock). The tone advances by all
    // the time passed since the first call, however few frames are asked
    // for, so the beat keeps its tempo at any call rate.
    void fill(int64_t t_us, uint32_t frames, int16_t* out);

    // Frames generated or stepped over since the first call.
    uint64_t position() const { return sample_; }

private:
    uint64_t sample_ = 0;
    int64_t base_us_ = 0;      // the first call's time
    uint64_t base_sample_ = 0; // the position at base_us_
    bool started_ = false;
    std::vector<int16_t> history_;  // the newest frames, interleaved

    void generate(uint32_t n);
};

}  // namespace md
