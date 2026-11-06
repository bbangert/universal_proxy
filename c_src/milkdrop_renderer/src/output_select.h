// Which connector and mode Kms::open presents on, free of libdrm so the
// host unit tests can check it.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "options.h"

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace md {

struct ConnectorCandidate {
    std::string name;  // "HDMI-A-1": connector_name()
    bool hdmi = false;
    bool connected = false;
    int modes = 0;
};

// The kernel's connector name: "<type name>-<type id>".
std::string connector_name(std::string_view type_name, unsigned type_id);

// The index of the connector to use: the one named `wanted`, which must be
// connected with modes, or with `wanted` empty the first connected HDMI
// one with modes. -1 with `err` set otherwise.
int choose_connector(const std::vector<ConnectorCandidate>& connectors, std::string_view wanted, std::string& err);

struct ModeCandidate {
    int width = 0;
    int height = 0;
    double refresh = 0;  // exact Hz
    bool interlaced = false;
    bool preferred = false;
};

// Where the chosen mode came from (the `prepared` event's `mode_source`).
enum class ModeSource {
    Crtc,       // the mode the CRTC scanned out at open: no modeset
    Closest,    // WxH@Hz: the offered mode nearest that refresh
    Preferred,  // WxH: the connector's preferred mode at that size
    Highest,    // WxH: the highest refresh at that size (none preferred)
};

const char* mode_source_name(ModeSource source);

struct ModeChoice {
    int index = -1;  // into the connector's modes; -1 = the CRTC's mode
    ModeSource source = ModeSource::Crtc;
};

// The mode to present `want` in, from the CRTC's current mode (if it had
// one) and the connector's modes. Only progressive modes of `want`'s size
// are used.
//   * "WxH@Hz": the CRTC's mode when within 0.5 Hz of Hz, else the offered
//     mode closest to Hz within 0.5 Hz.
//   * "WxH": the CRTC's mode, whatever its refresh, else the preferred
//     mode at that size, else the highest refresh at that size.
// Keeping the CRTC's mode avoids a modeset: a different pixel clock under
// a running HDMI audio stream leaves vc4's N/CTS stale.
std::optional<ModeChoice> choose_mode(const std::optional<ModeCandidate>& crtc,
                                      const std::vector<ModeCandidate>& modes, const DisplayMode& want);

}  // namespace md
