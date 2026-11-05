// The advertised audio formats and the `started` stdout event.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "alsa_caps.h"

#include "sendspin/player_role.h"

#include <string>
#include <vector>

const char* codec_name(sendspin::SendspinCodecFormat c);

// The format menu advertised to the Sendspin server: the baseline floor,
// plus probed hi-res FLAC/PCM entries when the probe succeeded.
std::vector<sendspin::AudioSupportedFormatObject> build_audio_formats(const ProbedCaps& caps);

std::string formats_to_json(const std::vector<sendspin::AudioSupportedFormatObject>& formats);

struct StartedInfo {
    const char* version = "";
    int port = 0;
    std::string name;
    std::string product;
    std::string alsa_device;
    std::vector<sendspin::AudioSupportedFormatObject> formats;
    bool display_roles = false;
};

// Echoed text fields are cut to this many bytes (sanitized, so they at most
// double when escaped). With the largest possible format menu (every
// candidate rate × depth) the line stays under MAX_EMIT_LINE_BYTES; the
// unit tests check that worst case.
inline constexpr size_t STARTED_TEXT_BYTES = 128;

std::string started_json(const StartedInfo& info);
