#include "started_event.h"

#include "json_out.h"

#include <sstream>

using namespace sendspin;

const char* codec_name(SendspinCodecFormat c) {
    switch (c) {
        case SendspinCodecFormat::FLAC: return "flac";
        case SendspinCodecFormat::OPUS: return "opus";
        case SendspinCodecFormat::PCM:  return "pcm";
        case SendspinCodecFormat::UNSUPPORTED: return "unsupported";
    }
    return "unknown";
}

// Negotiation is 100% server-driven (the server picks from this menu and
// encodes to the chosen format before streaming), so this list is the only
// lever for enabling hi-res output.
//
// The first five entries are the unconditional baseline floor — exactly what
// was advertised before per-device probing existed. Keeping them present
// always means a probe failure (or a non-card device) silently degrades to
// today's behaviour rather than going silent. Hi-res entries are layered on
// top only when the probe succeeds.
std::vector<AudioSupportedFormatObject> build_audio_formats(const ProbedCaps& caps) {
    std::vector<AudioSupportedFormatObject> formats = {
        {SendspinCodecFormat::FLAC, 2, 44100, 16},
        {SendspinCodecFormat::FLAC, 2, 48000, 16},
        {SendspinCodecFormat::OPUS, 2, 48000, 16},
        {SendspinCodecFormat::PCM,  2, 44100, 16},
        {SendspinCodecFormat::PCM,  2, 48000, 16},
    };

    if (!caps.ok) return formats;

    // Cross-product of probed rates × probed depths, for FLAC + PCM only.
    // Opus is hard-locked to 16-bit in the decoder (decoder.cpp:174), so it
    // never receives hi-res entries. Skip the {44100,48000} × 16-bit corner
    // the floor already covers to keep the advertised list dupe-free.
    // Channels stay stereo — channel-count probing is out of scope.
    for (uint8_t depth : caps.bit_depths) {
        for (uint32_t rate : caps.rates) {
            bool in_floor = (depth == 16 && (rate == 44100 || rate == 48000));
            if (in_floor) continue;
            formats.push_back({SendspinCodecFormat::FLAC, 2, rate, depth});
            formats.push_back({SendspinCodecFormat::PCM,  2, rate, depth});
        }
    }

    return formats;
}

// The advertised menu, otherwise visible only in the WS client/hello, made
// observable on stdout for the contract test and hardware validation.
std::string formats_to_json(const std::vector<AudioSupportedFormatObject>& formats) {
    std::ostringstream os;
    os << '[';
    bool first = true;
    for (const auto& f : formats) {
        if (!first) os << ',';
        first = false;
        os << "{\"codec\":\"" << codec_name(f.codec) << "\","
           << "\"channels\":" << static_cast<unsigned>(f.channels) << ","
           << "\"rate\":" << f.sample_rate << ","
           << "\"bit_depth\":" << static_cast<unsigned>(f.bit_depth) << "}";
    }
    os << ']';
    return os.str();
}

static std::string echo(const std::string& s) {
    return json_escape(sanitize_text(s, STARTED_TEXT_BYTES));
}

std::string started_json(const StartedInfo& info) {
    std::ostringstream os;
    os << "{\"event\":\"started\","
       << "\"version\":\"" << info.version << "\","
       << "\"port\":" << info.port << ","
       << "\"name\":\"" << echo(info.name) << "\","
       << "\"product\":\"" << echo(info.product) << "\","
       << "\"alsa_device\":\"" << echo(info.alsa_device) << "\","
       << "\"formats\":" << formats_to_json(info.formats);
    if (info.display_roles) os << ",\"display_roles\":true";
    os << "}";
    return os.str();
}
