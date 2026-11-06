#include "output_select.h"

#include <cmath>

namespace md {

namespace {

constexpr double MAX_OFF_HZ = 0.5;

bool same_size(const ModeCandidate& m, const DisplayMode& want) {
    return !m.interlaced && m.width == want.size.width && m.height == want.size.height;
}

}  // namespace

std::string connector_name(std::string_view type_name, unsigned type_id) {
    return std::string(type_name) + "-" + std::to_string(type_id);
}

int choose_connector(const std::vector<ConnectorCandidate>& connectors, std::string_view wanted, std::string& err) {
    for (size_t i = 0; i < connectors.size(); i++) {
        const ConnectorCandidate& c = connectors[i];
        if (wanted.empty() ? c.hdmi && c.connected && c.modes > 0 : c.name == wanted) {
            if (c.connected && c.modes > 0) return static_cast<int>(i);
            err = "connector " + c.name + " not connected";
            return -1;
        }
    }
    err = wanted.empty() ? "no connected HDMI connector" : "no connector " + std::string(wanted);
    return -1;
}

const char* mode_source_name(ModeSource source) {
    switch (source) {
        case ModeSource::Crtc: return "crtc";
        case ModeSource::Closest: return "closest";
        case ModeSource::Preferred: return "preferred";
        case ModeSource::Highest: return "highest";
    }
    return "";
}

std::optional<ModeChoice> choose_mode(const std::optional<ModeCandidate>& crtc,
                                      const std::vector<ModeCandidate>& modes, const DisplayMode& want) {
    if (want.refresh) {
        const double hz = *want.refresh;
        if (crtc && same_size(*crtc, want) && std::fabs(crtc->refresh - hz) <= MAX_OFF_HZ)
            return ModeChoice{-1, ModeSource::Crtc};
        int best = -1;
        double best_off = 0;
        for (size_t i = 0; i < modes.size(); i++) {
            if (!same_size(modes[i], want)) continue;
            const double off = std::fabs(modes[i].refresh - hz);
            if (off <= MAX_OFF_HZ && (best < 0 || off < best_off)) {
                best = static_cast<int>(i);
                best_off = off;
            }
        }
        if (best < 0) return std::nullopt;
        return ModeChoice{best, ModeSource::Closest};
    }

    if (crtc && same_size(*crtc, want)) return ModeChoice{-1, ModeSource::Crtc};
    int preferred = -1, highest = -1;
    for (size_t i = 0; i < modes.size(); i++) {
        if (!same_size(modes[i], want)) continue;
        if (preferred < 0 && modes[i].preferred) preferred = static_cast<int>(i);
        if (highest < 0 || modes[i].refresh > modes[static_cast<size_t>(highest)].refresh)
            highest = static_cast<int>(i);
    }
    if (preferred >= 0) return ModeChoice{preferred, ModeSource::Preferred};
    if (highest >= 0) return ModeChoice{highest, ModeSource::Highest};
    return std::nullopt;
}

}  // namespace md
