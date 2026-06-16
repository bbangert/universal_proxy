#include "alsa_caps.h"

#include <alsa/asoundlib.h>

#include <string_view>

namespace {

// Candidate sample rates probed via snd_pcm_hw_params_test_rate. On a
// full-speed USB bus (Pi 3 / Zero) the high rates typically fail the test
// and are filtered out — that is the intended behaviour, not an error.
constexpr uint32_t kCandidateRates[] = {
    44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000,
};

// Candidate sample formats and the bit depth each maps to. Must stay in
// sync with the format switch in AlsaPipeSink::open_alsa
// (alsa_pipe_sink.cpp) — only depths the sink can actually open are useful
// to advertise.
struct FormatCandidate {
    snd_pcm_format_t fmt;
    uint8_t bit_depth;
};
constexpr FormatCandidate kCandidateFormats[] = {
    {SND_PCM_FORMAT_S16_LE, 16},
    {SND_PCM_FORMAT_S24_3LE, 24},
    {SND_PCM_FORMAT_S32_LE, 32},
};

bool starts_with(std::string_view s, std::string_view prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

}  // namespace

std::string hw_device_for_probe(const std::string& alsa_device) {
    if (starts_with(alsa_device, "plughw:")) {
        return "hw:" + alsa_device.substr(std::string_view("plughw:").size());
    }
    if (starts_with(alsa_device, "hw:")) {
        return alsa_device;  // already a raw hardware device
    }
    return {};  // "default", empty, or non-card device → skip probe
}

ProbedCaps probe_caps(const std::string& hw_device) {
    ProbedCaps caps;
    if (hw_device.empty()) return caps;  // ok == false

    snd_pcm_t* pcm = nullptr;
    int err = snd_pcm_open(&pcm, hw_device.c_str(), SND_PCM_STREAM_PLAYBACK, 0);
    if (err < 0) {
        // EBUSY (device in use), ENOENT (no such card), EINVAL — any of
        // these means we cannot probe. Fall back to the baseline floor.
        return caps;
    }

    snd_pcm_hw_params_t* hw = nullptr;
    snd_pcm_hw_params_alloca(&hw);
    if (snd_pcm_hw_params_any(pcm, hw) < 0) {
        snd_pcm_close(pcm);
        return caps;
    }

    // snd_pcm_hw_params_test_* are non-mutating queries against the full
    // configuration space from _any(), so rate and format are independent
    // and order does not matter.
    for (uint32_t rate : kCandidateRates) {
        if (snd_pcm_hw_params_test_rate(pcm, hw, rate, 0) == 0) {
            caps.rates.push_back(rate);
        }
    }
    for (const auto& cand : kCandidateFormats) {
        if (snd_pcm_hw_params_test_format(pcm, hw, cand.fmt) == 0) {
            caps.bit_depths.push_back(cand.bit_depth);
        }
    }

    snd_pcm_close(pcm);

    // An empty result is indistinguishable from a failed probe to the
    // caller — both must fall back to the floor — so only claim success
    // when at least one rate and one depth came back.
    caps.ok = !caps.rates.empty() && !caps.bit_depths.empty();
    return caps;
}
