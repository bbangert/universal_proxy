#include "alsa_caps.h"

#include <alsa/asoundlib.h>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
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


// The sample rates at which the HDMI sink behind `hw_device`
// ("hw:<card>,<dev>") takes 24-bit LPCM, from the ELD the kernel exposes at
// /proc/asound/card<N>/eld#<D>.0. Rates and sample sizes pair up per Short
// Audio Descriptor, so a rate counts only when one LPCM descriptor lists
// both it and 24 bits. Anything unreadable (another device naming, no ELD,
// no sink) yields none.
std::vector<uint32_t> eld_lpcm_24bit_rates(const std::string& hw_device) {
    unsigned card = 0, dev = 0;
    if (std::sscanf(hw_device.c_str(), "hw:%u,%u", &card, &dev) != 2) return {};

    std::ifstream eld("/proc/asound/card" + std::to_string(card) + "/eld#" +
                      std::to_string(dev) + ".0");
    if (!eld) return {};

    struct Sad {
        bool lpcm = false;
        bool has_24 = false;
        std::vector<uint32_t> rates;
    };
    std::map<std::string, Sad> sads;  // keyed by "sadN"
    std::string line;
    while (std::getline(eld, line)) {
        auto key_end = line.find_first_of(" \t");
        if (key_end == std::string::npos || !starts_with(line, "sad")) continue;
        std::string key = line.substr(0, key_end);
        auto underscore = key.find('_');
        if (underscore == std::string::npos) continue;
        Sad& sad = sads[key.substr(0, underscore)];
        std::string field = key.substr(underscore + 1);
        // Values look like "[0x14e0] 32000 44100 48000"; the list follows ']'.
        std::string value = line.substr(key_end);
        auto list = value.find(']');
        std::istringstream items(list == std::string::npos ? value : value.substr(list + 1));
        if (field == "coding_type") {
            sad.lpcm = value.find("LPCM") != std::string::npos;
        } else if (field == "bits") {
            for (unsigned bits; items >> bits;) sad.has_24 = sad.has_24 || bits == 24;
        } else if (field == "rates") {
            for (uint32_t rate; items >> rate;) sad.rates.push_back(rate);
        }
    }

    std::vector<uint32_t> rates;
    for (const auto& [name, sad] : sads) {
        if (!sad.lpcm || !sad.has_24) continue;
        for (uint32_t rate : sad.rates) {
            if (std::find(rates.begin(), rates.end(), rate) == rates.end()) rates.push_back(rate);
        }
    }
    return rates;
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

    // HDMI on the Pi (vc4-hdmi) accepts only IEC958 subframes at hw:, so
    // none of the linear formats above test true. Playback goes through
    // plughw:, which packs linear samples into subframes. A subframe carries
    // up to 24 bits, but that says nothing about the sink: every probed rate
    // (already limited to the ELD's) gets 16-bit, and 24-bit only at the
    // rates an LPCM descriptor in the ELD pairs with 24 bits. Never 32, which
    // a subframe would truncate. These pairs replace the rates x depths
    // cross product.
    if (caps.bit_depths.empty() &&
        snd_pcm_hw_params_test_format(pcm, hw, SND_PCM_FORMAT_IEC958_SUBFRAME_LE) == 0) {
        std::vector<uint32_t> rates_24 = eld_lpcm_24bit_rates(hw_device);
        caps.bit_depths = {16};
        for (uint32_t rate : caps.rates) caps.pairs.emplace_back(rate, uint8_t{16});
        for (uint32_t rate : caps.rates) {
            if (std::find(rates_24.begin(), rates_24.end(), rate) != rates_24.end()) {
                caps.pairs.emplace_back(rate, uint8_t{24});
            }
        }
        if (caps.pairs.size() > caps.rates.size()) caps.bit_depths.push_back(24);
    }

    snd_pcm_close(pcm);

    // An empty result is indistinguishable from a failed probe to the
    // caller — both must fall back to the floor — so only claim success
    // when at least one rate and one depth came back.
    caps.ok = !caps.rates.empty() && !caps.bit_depths.empty();
    return caps;
}
