// A test-only facade over sendspin_player's PCM tap writer. It lives in its
// own translation unit because the writer includes sendspin_player's copy
// of pcm_tap.h, while the renderer includes its own (identical) copy.

#pragma once

#include <cstdint>
#include <memory>
#include <string>

class RingWriter {
public:
    static std::unique_ptr<RingWriter> open(const std::string& path);
    virtual ~RingWriter() = default;
    // Commits interleaved stereo S16 frames whose last one plays at t_end_us.
    virtual void commit(uint64_t stream, uint32_t rate, const int16_t* stereo, uint32_t frames,
                        int64_t t_end_us) = 0;
    virtual void end_stream() = 0;
};
