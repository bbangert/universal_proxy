// Audio for each frame from the sendspin_player PCM tap ring (pcm_tap.h):
// the samples whose play time ends at the frame's predicted scanout time.
// Flip times are CLOCK_MONOTONIC and the ring's t_end_us is
// CLOCK_MONOTONIC_RAW, so a MONOTONIC->RAW offset is kept (re-sampled every
// 10 s; the two drift apart under NTP slewing). No ring, no stream, an
// underrun gap or a target past the newest audio gives silence (the
// reader's NoData), so presets decay naturally.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "pcm_tap.h"

#include <cstdint>
#include <string>
#include <sys/types.h>

namespace md {

// CLOCK_MONOTONIC_RAW minus CLOCK_MONOTONIC, in microseconds, from one
// bracketed sample.
int64_t sample_raw_offset_us();

int64_t monotonic_us();
int64_t monotonic_raw_us();

class PcmFeed {
public:
    // Frames per read: projectM analyses its newest 576 samples per frame.
    static constexpr uint32_t FRAMES = 576;
    // A read the writer overtook is retried this many times in a frame.
    static constexpr int RETRIES = 3;

    enum class Result { Ok, Silent };

    // `path` empty: always silence. `av_offset_us` is added to targets.
    PcmFeed(std::string path, int64_t av_offset_us);

    // Re-samples the clock offset, (re)opens the ring if it is missing or
    // was replaced. Call about once a second; cheap.
    void maintain(int64_t now_mono_us);

    // Fills `out` (FRAMES * 2 interleaved S16) with the audio ending at
    // `t_mono_us`.
    Result read(int64_t t_mono_us, int16_t* out);

    // For tests: pin the offset instead of sampling clocks.
    void set_offset_us(int64_t offset_us) {
        offset_us_ = offset_us;
        fixed_offset_ = true;
    }

    uint64_t ok = 0, silent = 0;

private:
    std::string path_;
    int64_t av_offset_us_;
    int64_t offset_us_ = 0;
    bool fixed_offset_ = false;
    int64_t last_offset_sample_us_ = 0;
    int64_t last_open_try_us_ = -1;
    pcm_tap::Reader reader_;
    dev_t dev_ = 0;
    ino_t ino_ = 0;

    bool try_open();
};

}  // namespace md
