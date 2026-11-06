#include "options.h"

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace md {

const char* const USAGE =
    "usage: milkdrop_renderer --mode WxH[@Hz] --pack-dir DIR --ladder WxH[,WxH...]\n"
    "                         --rotate-s N --skip-file PATH\n"
    "                         [--high-frequency] [--locked FILE] [--pcm-ring PATH]\n"
    "  tuning: [--card DEV] [--blend S] [--min-fps F] [--interval N] [--seed N]\n"
    "          [--av-offset-ms N] [--master-timeout-ms N] [--mesh WxH] [--stats-s N]\n"
    "  check:  [--headless-frames N]  (off-screen on --card, e.g. /dev/dri/renderD128)\n"
    "          [--simulate-kms]       (take/flips/release simulated on --card, a render node)\n"
    "          [--test-tone]          (a synthetic beat while the ring has no audio)\n";

namespace {

bool parse_int(std::string_view s, long long lo, long long hi, long long& out) {
    if (s.empty() || s.size() > 19) return false;
    std::string text(s);
    char* end = nullptr;
    errno = 0;
    long long v = std::strtoll(text.c_str(), &end, 10);
    if (errno != 0 || end != text.c_str() + text.size() || v < lo || v > hi) return false;
    out = v;
    return true;
}

bool parse_double(std::string_view s, double lo, double hi, double& out) {
    if (s.empty() || s.size() > 32) return false;
    std::string text(s);
    char* end = nullptr;
    errno = 0;
    double v = std::strtod(text.c_str(), &end);
    if (errno != 0 || end != text.c_str() + text.size() || !std::isfinite(v) || v < lo || v > hi)
        return false;
    out = v;
    return true;
}

}  // namespace

std::optional<Resolution> parse_resolution(std::string_view s) {
    size_t x = s.find('x');
    if (x == std::string_view::npos) return std::nullopt;
    long long w = 0, h = 0;
    if (!parse_int(s.substr(0, x), 1, 16384, w) || !parse_int(s.substr(x + 1), 1, 16384, h))
        return std::nullopt;
    return Resolution{static_cast<int>(w), static_cast<int>(h)};
}

std::string DisplayMode::str() const {
    char buf[64];
    if (std::fabs(refresh - std::round(refresh)) < 1e-9) {
        std::snprintf(buf, sizeof(buf), "%dx%d@%d", size.width, size.height,
                      static_cast<int>(std::lround(refresh)));
    } else {
        std::snprintf(buf, sizeof(buf), "%dx%d@%.3g", size.width, size.height, refresh);
    }
    return buf;
}

std::optional<DisplayMode> parse_mode(std::string_view s) {
    DisplayMode mode;
    size_t at = s.find('@');
    auto res = parse_resolution(s.substr(0, at));
    if (!res) return std::nullopt;
    mode.size = *res;
    if (at != std::string_view::npos && !parse_double(s.substr(at + 1), 1.0, 1000.0, mode.refresh))
        return std::nullopt;
    return mode;
}

std::optional<std::vector<Resolution>> parse_ladder(std::string_view s) {
    std::vector<Resolution> out;
    size_t start = 0;
    while (start <= s.size()) {
        size_t comma = s.find(',', start);
        std::string_view part = s.substr(start, comma == std::string_view::npos ? s.npos : comma - start);
        auto r = parse_resolution(part);
        if (!r) return std::nullopt;
        if (!out.empty() && r->area() >= out.back().area()) return std::nullopt;
        out.push_back(*r);
        if (out.size() > 8) return std::nullopt;
        if (comma == std::string_view::npos) break;
        start = comma + 1;
    }
    if (out.empty()) return std::nullopt;
    return out;
}

bool parse_options(const std::vector<std::string>& args, Options& out, std::string& error) {
    bool have_mode = false, have_pack = false, have_ladder = false, have_rotate = false,
         have_skip = false;
    for (size_t i = 0; i < args.size(); i++) {
        const std::string& a = args[i];
        auto value = [&](std::string& v) -> bool {
            if (i + 1 >= args.size()) {
                error = "missing value for " + a;
                return false;
            }
            v = args[++i];
            return true;
        };
        std::string v;
        long long n = 0;
        if (a == "--high-frequency") {
            out.high_frequency = true;
            continue;
        }
        if (a == "--test-tone") {
            out.test_tone = true;
            continue;
        }
        if (a == "--simulate-kms") {
            out.simulate_kms = true;
            continue;
        }
        if (a.rfind("--", 0) != 0) {
            error = "unexpected argument";
            return false;
        }
        if (!value(v)) return false;
        if (a == "--mode") {
            auto m = parse_mode(v);
            if (!m) {
                error = "bad --mode";
                return false;
            }
            out.mode = *m;
            have_mode = true;
        } else if (a == "--pack-dir") {
            out.pack_dir = v;
            have_pack = !v.empty();
        } else if (a == "--ladder") {
            auto l = parse_ladder(v);
            if (!l) {
                error = "bad --ladder";
                return false;
            }
            out.ladder = *l;
            have_ladder = true;
        } else if (a == "--rotate-s") {
            if (!parse_int(v, 1, 3600, n)) {
                error = "bad --rotate-s";
                return false;
            }
            out.rotate_s = static_cast<int>(n);
            have_rotate = true;
        } else if (a == "--skip-file") {
            out.skip_file = v;
            have_skip = true;
        } else if (a == "--locked") {
            out.locked = v;
        } else if (a == "--pcm-ring") {
            out.pcm_ring = v;
        } else if (a == "--card") {
            out.card = v;
        } else if (a == "--blend") {
            if (!parse_double(v, 0.0, 30.0, out.blend_s)) {
                error = "bad --blend";
                return false;
            }
        } else if (a == "--min-fps") {
            if (!parse_double(v, 1.0, 240.0, out.min_fps)) {
                error = "bad --min-fps";
                return false;
            }
        } else if (a == "--interval") {
            if (!parse_int(v, 1, 4, n)) {
                error = "bad --interval";
                return false;
            }
            out.interval = static_cast<int>(n);
        } else if (a == "--seed") {
            if (!parse_int(v, 0, 0x7fffffffffffffffLL, n)) {
                error = "bad --seed";
                return false;
            }
            out.seed = static_cast<uint64_t>(n);
        } else if (a == "--av-offset-ms") {
            if (!parse_int(v, -1000, 1000, n)) {
                error = "bad --av-offset-ms";
                return false;
            }
            out.av_offset_ms = static_cast<int>(n);
        } else if (a == "--master-timeout-ms") {
            if (!parse_int(v, 1, 60000, n)) {
                error = "bad --master-timeout-ms";
                return false;
            }
            out.master_timeout_ms = static_cast<int>(n);
        } else if (a == "--mesh") {
            auto r = parse_resolution(v);
            if (!r || r->width > 512 || r->height > 512) {
                error = "bad --mesh";
                return false;
            }
            out.mesh_width = r->width;
            out.mesh_height = r->height;
        } else if (a == "--headless-frames") {
            if (!parse_int(v, 1, 1000000, n)) {
                error = "bad --headless-frames";
                return false;
            }
            out.headless_frames = static_cast<int>(n);
        } else if (a == "--stats-s") {
            if (!parse_int(v, 1, 3600, n)) {
                error = "bad --stats-s";
                return false;
            }
            out.stats_s = static_cast<int>(n);
        } else {
            error = "unknown option";
            return false;
        }
    }
    if (!have_mode || !have_pack || !have_ladder || !have_rotate || !have_skip) {
        error = "missing required option";
        return false;
    }
    if (out.simulate_kms && out.headless_frames > 0) {
        error = "--simulate-kms and --headless-frames are exclusive";
        return false;
    }
    return true;
}

}  // namespace md
