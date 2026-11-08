// Host unit tests for milkdrop_renderer's GL-free core. Prints one line per
// failure and exits non-zero if any check failed.

#include "cost_guard.h"
#include "exit_guard.h"
#include "frame_pacer.h"
#include "json.h"
#include "kmsg_watch.h"
#include "manifest.h"
#include "options.h"
#include "output_select.h"
#include "pcm_feed.h"
#include "poll_round.h"
#include "preset_manager.h"
#include "preset_selection.h"
#include "protocol.h"
#include "ring_writer.h"  // sendspin_player's writer: the real producer
#include "stderr_capture.h"
#include "switch_state.h"
#include "test_tone.h"
#include "thermal.h"

#include <algorithm>
#include <atomic>
#include <csignal>
#include <cstdlib>
#include <functional>
#include <chrono>
#include <cstdio>
#include <fcntl.h>
#include <filesystem>
#include <map>
#include <set>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace md;

static int g_failures = 0;

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            g_failures++;                                               \
        }                                                               \
    } while (0)

static std::string tmp_path(const char* name) {
    return (fs::temp_directory_path() /
            ("milkdrop_unit_" + std::to_string(getpid()) + "_" + name))
        .string();
}

// ---------------------------------------------------------------- json

static void test_json() {
    JsonValue v;
    std::string err;
    CHECK(json_parse(R"({"a":[1,2.5,-3e2],"b":{"c":"x\"y\\z\u00e9\ud83c\udfb5"},"d":true,"e":null})", v, err));
    CHECK(v.get("a") && v.get("a")->array.size() == 3 && v.get("a")->array[2].number == -300);
    CHECK(v.get("b")->get("c")->string == "x\"y\\z\xc3\xa9\xf0\x9f\x8e\xb5");
    CHECK(v.get("d")->is_bool() && v.get("d")->boolean);
    CHECK(v.get("e")->is_null());
    CHECK(v.get("missing") == nullptr);
    CHECK(!json_parse("{\"a\":1", v, err));
    CHECK(!json_parse("{\"a\":1} x", v, err));
    CHECK(!json_parse("[01]", v, err));
    CHECK(!json_parse("\"\\ud800\"", v, err));
    CHECK(!json_parse("\"a\nb\"", v, err));
    CHECK(!json_parse(std::string(100, '[') + std::string(100, ']'), v, err));
    CHECK(json_escape("a\"b\\c\n\x01") == "a\\\"b\\\\c\\n\\u0001");
    CHECK(sanitize_text("ab\x01" "c\xff\xc3\xa9", 100) == "ab c\xc3\xa9");
}

// ---------------------------------------------------------------- options

static std::vector<std::string> base_args() {
    return {"--mode", "1280x720@60", "--pack-dir", "/p", "--ladder", "640x360,480x270",
            "--rotate-s", "20", "--skip-file", "/tmp/s"};
}

static void test_options() {
    Options o;
    std::string err;
    CHECK(parse_options(base_args(), o, err));
    CHECK(o.mode.size == (Resolution{1280, 720}) && o.mode.refresh == 60.0);
    CHECK(o.mode.str() == "1280x720@60");
    CHECK(o.connector.empty());
    CHECK(o.ladder.size() == 2 && o.ladder[1] == (Resolution{480, 270}));
    CHECK(o.rotate_s == 20 && !o.high_frequency && o.locked.empty() && o.pcm_ring.empty());
    CHECK(o.blend_s == 0.5);
    CHECK(o.min_fps == 20.0);

    auto args = base_args();
    args.insert(args.end(), {"--high-frequency", "--locked", "a/b.milk", "--pcm-ring", "/run/up-pcm-x"});
    Options o2;
    CHECK(parse_options(args, o2, err));
    CHECK(o2.high_frequency && o2.locked == "a/b.milk" && o2.pcm_ring == "/run/up-pcm-x");

    auto m = parse_mode("1280x720@59.94");
    CHECK(m && m->refresh > 59.9 && m->refresh < 60);
    // No refresh: whatever the output runs at that size.
    auto any = parse_mode("1280x720");
    CHECK(any && any->size == (Resolution{1280, 720}) && !any->refresh);
    CHECK(any->str() == "1280x720" && any->refresh_or_default() == 60.0);
    CHECK(parse_mode("1920x1080@50")->refresh == 50.0 && parse_mode("1920x1080@50")->str() == "1920x1080@50");
    CHECK(!parse_mode("1280x720@") && !parse_mode("x720") && !parse_mode("1280x0"));
    CHECK(!parse_mode("1280x720@0") && !parse_mode("1280x720@60x"));

    auto wxh = base_args();
    wxh[1] = "1920x1080";
    Options o6;
    CHECK(parse_options(wxh, o6, err) && !o6.mode.refresh && o6.mode.size == (Resolution{1920, 1080}));

    auto conn = base_args();
    conn.insert(conn.end(), {"--connector", "HDMI-A-2"});
    Options o7;
    CHECK(parse_options(conn, o7, err) && o7.connector == "HDMI-A-2");
    for (const char* bad_name : {"", "HDMI A", "HDMI-A-1;", "../card0", "HDMI-A-1\n"}) {
        auto bc = base_args();
        bc.insert(bc.end(), {"--connector", bad_name});
        Options o8;
        CHECK(!parse_options(bc, o8, err) && err == "bad --connector");
    }
    CHECK(valid_connector_name("HDMI-A-1") && valid_connector_name(std::string(32, 'a')));
    CHECK(!valid_connector_name(std::string(33, 'a')));
    auto conn_missing = base_args();
    conn_missing.push_back("--connector");
    Options o9;
    CHECK(!parse_options(conn_missing, o9, err) && err == "missing value for --connector");
    CHECK(!parse_ladder("640x360,960x540"));  // must shrink
    CHECK(!parse_ladder("640x360,"));
    CHECK(parse_ladder("960x540,640x360,480x270")->size() == 3);

    Options bad;
    CHECK(!parse_options({"--mode", "1280x720"}, bad, err) && err == "missing required option");
    auto unknown = base_args();
    unknown.push_back("--bogus");
    unknown.push_back("1");
    CHECK(!parse_options(unknown, bad, err) && err == "unknown option");
    auto missing = base_args();
    missing.push_back("--locked");
    CHECK(!parse_options(missing, bad, err));
    auto rot = base_args();
    rot[7] = "0";
    CHECK(!parse_options(rot, bad, err));
    auto checks = base_args();
    checks.insert(checks.end(), {"--test-tone", "--headless-frames", "300", "--card", "/dev/dri/renderD128"});
    Options o3;
    CHECK(parse_options(checks, o3, err) && o3.test_tone && o3.headless_frames == 300 &&
          o3.card == "/dev/dri/renderD128" && !o3.simulate_kms);
    auto sim = base_args();
    sim.insert(sim.end(), {"--simulate-kms", "--card", "/dev/dri/renderD128"});
    Options o4;
    CHECK(parse_options(sim, o4, err) && o4.simulate_kms && o4.headless_frames == 0);
    sim.insert(sim.end(), {"--headless-frames", "10"});
    Options o5;
    CHECK(!parse_options(sim, o5, err));
}

// ---------------------------------------------------------------- output selection

static void test_connector_choice() {
    CHECK(connector_name("HDMI-A", 2) == "HDMI-A-2");
    std::string err;
    std::vector<ConnectorCandidate> two = {
        {"Composite-1", false, true, 4},
        {"HDMI-A-1", true, true, 10},
        {"HDMI-A-2", true, true, 12},
    };
    // Default: the first connected HDMI one.
    CHECK(choose_connector(two, "", err) == 1);
    // By name: the second HDMI port, not the first connected.
    CHECK(choose_connector(two, "HDMI-A-2", err) == 2);
    CHECK(choose_connector(two, "Composite-1", err) == 0);

    std::vector<ConnectorCandidate> one_off = {
        {"HDMI-A-1", true, true, 10},
        {"HDMI-A-2", true, false, 0},
    };
    // The named one disconnected: an error, never the other port.
    CHECK(choose_connector(one_off, "HDMI-A-2", err) == -1 && err == "connector HDMI-A-2 not connected");
    CHECK(choose_connector(one_off, "HDMI-A-3", err) == -1 && err == "no connector HDMI-A-3");
    CHECK(choose_connector(one_off, "", err) == 0);

    std::vector<ConnectorCandidate> no_modes = {{"HDMI-A-1", true, true, 0}, {"HDMI-A-2", true, false, 0}};
    CHECK(choose_connector(no_modes, "", err) == -1 && err == "no connected HDMI connector");
    CHECK(choose_connector(no_modes, "HDMI-A-1", err) == -1 && err == "connector HDMI-A-1 not connected");
    CHECK(choose_connector({}, "", err) == -1);
}

static void test_mode_choice() {
    auto m = [](int w, int h, double hz, bool preferred = false, bool interlaced = false) {
        return ModeCandidate{w, h, hz, interlaced, preferred};
    };
    auto want = [](const char* s) { return *parse_mode(s); };
    const std::vector<ModeCandidate> tv = {
        m(1920, 1080, 60), m(1920, 1080, 50), m(1920, 1080, 59.94), m(1920, 1080, 60, false, true),
        m(1280, 720, 60), m(1280, 720, 50), m(1280, 720, 59.94),
    };

    // WxH: the CRTC's mode whatever its refresh (no modeset).
    auto c = choose_mode(m(1280, 720, 50), tv, want("1280x720"));
    CHECK(c && c->index == -1 && c->source == ModeSource::Crtc);
    c = choose_mode(m(1280, 720, 120), tv, want("1280x720"));
    CHECK(c && c->index == -1 && c->source == ModeSource::Crtc);
    // An interlaced or other-size CRTC mode is not kept.
    c = choose_mode(m(1920, 1080, 60, false, true), tv, want("1920x1080"));
    CHECK(c && c->index == 0 && c->source == ModeSource::Highest);
    c = choose_mode(m(1920, 1080, 60), tv, want("1280x720"));
    CHECK(c && c->index == 4 && c->source == ModeSource::Highest);
    // No CRTC mode: the preferred one at that size, else the highest.
    auto preferred_50 = tv;
    preferred_50[5].preferred = true;
    c = choose_mode(std::nullopt, preferred_50, want("1280x720"));
    CHECK(c && c->index == 5 && c->source == ModeSource::Preferred);
    preferred_50[0].preferred = true;  // another size's preferred flag is ignored
    c = choose_mode(std::nullopt, preferred_50, want("1280x720"));
    CHECK(c && c->index == 5);
    // A 50-Hz-only TV.
    const std::vector<ModeCandidate> pal = {m(1280, 720, 50), m(720, 576, 50)};
    c = choose_mode(std::nullopt, pal, want("1280x720"));
    CHECK(c && c->index == 0 && c->source == ModeSource::Highest);
    CHECK(!choose_mode(std::nullopt, pal, want("1280x720@60")));
    CHECK(!choose_mode(std::nullopt, pal, want("1920x1080")));
    CHECK(!choose_mode(std::nullopt, {m(1280, 720, 60, true, true)}, want("1280x720")));

    // WxH@Hz: the CRTC's within 0.5 Hz, else the closest offered.
    c = choose_mode(m(1280, 720, 59.94), tv, want("1280x720@60"));
    CHECK(c && c->index == -1 && c->source == ModeSource::Crtc);
    c = choose_mode(m(1280, 720, 50), tv, want("1280x720@60"));
    CHECK(c && c->index == 4 && c->source == ModeSource::Closest);
    c = choose_mode(std::nullopt, tv, want("1280x720@59.94"));
    CHECK(c && c->index == 6 && c->source == ModeSource::Closest);
    c = choose_mode(std::nullopt, tv, want("1920x1080@50"));
    CHECK(c && c->index == 1);
    CHECK(!choose_mode(m(1280, 720, 50), tv, want("1280x720@55")));
    CHECK(std::string(mode_source_name(ModeSource::Preferred)) == "preferred");
}

// ---------------------------------------------------------------- protocol

static void test_protocol() {
    std::string err;
    auto c = parse_command(R"({"cmd":"take"})", err);
    CHECK(c && c->type == Command::Type::Take);
    CHECK(parse_command(R"({"cmd":"release"})", err)->type == Command::Type::Release);
    CHECK(parse_command(R"({"cmd":"exit"})", err)->type == Command::Type::Exit);
    CHECK(parse_command(R"({"cmd":"next"})", err)->type == Command::Type::Next);
    CHECK(parse_command(R"({"cmd":"prev"})", err)->type == Command::Type::Prev);
    CHECK(parse_command(R"({"cmd":"lock"})", err)->type == Command::Type::Lock);
    CHECK(parse_command(R"({"cmd":"unlock"})", err)->type == Command::Type::Unlock);
    c = parse_command(R"({"value":45,"cmd":"set_rotate"})", err);
    CHECK(c && c->type == Command::Type::SetRotate && c->int_value == 45);
    CHECK(!parse_command(R"({"cmd":"set_rotate","value":2.5})", err));
    CHECK(!parse_command(R"({"cmd":"set_rotate","value":"5"})", err));
    CHECK(!parse_command(R"({"cmd":"set_rotate","value":0})", err));
    c = parse_command(R"({"cmd":"set_high_frequency","value":true})", err);
    CHECK(c && c->type == Command::Type::SetHighFrequency && c->bool_value);
    CHECK(!parse_command(R"({"cmd":"set_high_frequency","value":1})", err));
    c = parse_command(R"({"cmd":"set_min_fps","value":25})", err);
    CHECK(c && c->type == Command::Type::SetMinFps && c->number_value == 25.0);
    CHECK(parse_command(R"({"cmd":"set_min_fps","value":27.5})", err)->number_value == 27.5);
    CHECK(!parse_command(R"({"cmd":"set_min_fps","value":"25"})", err) && err == "bad set_min_fps value");
    CHECK(!parse_command(R"({"cmd":"set_min_fps","value":0})", err));
    CHECK(!parse_command(R"({"cmd":"set_min_fps","value":241})", err));
    CHECK(!parse_command(R"({"cmd":"set_min_fps"})", err));
    CHECK(!parse_command(R"({"cmd":"dance"})", err) && err == "unknown cmd");
    CHECK(!parse_command(R"({"value":1})", err));
    CHECK(!parse_command("take", err));

    // Lines: split on \n, over-long ones dropped whole.
    LineBuffer lb(8);
    std::vector<std::string> lines;
    auto on_line = [&](std::string_view l) { lines.emplace_back(l); };
    std::string in = "abc\nde";
    lb.feed(in.data(), in.size(), on_line);
    in = "f\n0123456789abc\nok\n";
    lb.feed(in.data(), in.size(), on_line);
    CHECK((lines == std::vector<std::string>{"abc", "def", "ok"}));
    CHECK(lb.overflowed == 1);

    // Events parse back, and the worst case fits the line budget.
    JsonValue v;
    CHECK(json_parse(event_preset("a \"b\".milk", true, "640x360", "rotate", false), v, err));
    CHECK(v.get("event")->string == "preset" && v.get("file")->string == "a \"b\".milk" &&
          v.get("locked")->boolean && v.get("rung")->string == "640x360");
    CHECK(json_parse(event_loading("hf/a \"b\".milk"), v, err) && v.get("event")->string == "loading" &&
          v.get("preset")->string == "hf/a \"b\".milk" && v.object.size() == 2);
    CHECK(json_parse(event_skip("x.milk", "budget"), v, err) && v.get("preset")->string == "x.milk" &&
          v.get("reason")->string == "budget" && v.get("message") == nullptr && v.get("fps") == nullptr);
    CHECK(json_parse(event_skip("x.milk", "budget", {}, 17.34), v, err) && v.get("fps")->number == 17.3 &&
          v.get("message") == nullptr);
    // Rounded down, so a measurement under a floor never reads back at it.
    CHECK(json_parse(event_skip("x.milk", "budget", {}, 28.96), v, err) && v.get("fps")->number == 28.9);
    CHECK(json_parse(event_skip("x.milk", "budget", {}, 29.0), v, err) && v.get("fps")->number == 29.0);
    CHECK(json_parse(event_skip("x.milk", "budget", {}, 0.0), v, err) && v.get("fps")->number == 0.0);
    CHECK(json_parse(event_skip("x.milk", "compile_error", "warp: 0:12: bad"), v, err) &&
          v.get("reason")->string == "compile_error" && v.get("message")->string == "warp: 0:12: bad");
    CHECK(json_parse(event_presenting(false, 3.5, false), v, err) && !v.get("modeset")->boolean &&
          v.get("master_ms")->number == 3.5 && !v.get("crtc_lit")->boolean);
    PreparedInfo info;
    info.mode = "1280x720@60";
    info.connector = "HDMI-A-2";
    info.mode_source = "crtc";
    info.gl_renderer = "VC4 V3D 2.1";
    info.gl_version = "OpenGL ES 2.0";
    info.gles2 = true;
    info.presets = 7;
    info.crtc_mode_valid = true;
    info.crtc_mode = "1280x720@60";
    CHECK(json_parse(event_prepared(info), v, err) && v.get("crtc_mode_valid")->boolean &&
          v.get("crtc_mode")->string == "1280x720@60" && v.get("presets")->number == 7 &&
          v.get("connector")->string == "HDMI-A-2" && v.get("mode_source")->string == "crtc" &&
          v.get("mode")->string == "1280x720@60");
    PreparedInfo bare;
    bare.mode = "1280x720@60";
    CHECK(json_parse(event_prepared(bare), v, err) && !v.get("crtc_mode_valid")->boolean &&
          v.get("crtc_mode") == nullptr && v.get("connector") == nullptr && v.get("mode_source") == nullptr);
    CHECK(json_parse(event_simple("released"), v, err) && v.get("event")->string == "released");
    CHECK(json_parse(event_exiting("thermal"), v, err) && v.get("reason")->string == "thermal");
    std::string hostile(MAX_PRESET_NAME_BYTES, '"');
    StatsSnapshot s;
    s.preset = hostile;
    s.rung = std::string(100, '\\');
    CHECK(event_stats(s).size() < MAX_EMIT_LINE_BYTES);
    CHECK(json_parse(event_stats(s), v, err) && v.get("preset")->string == hostile);
    CHECK(event_preset(hostile, false, hostile, hostile, false).size() < MAX_EMIT_LINE_BYTES);
    CHECK(event_error(hostile, hostile + hostile).size() < MAX_EMIT_LINE_BYTES);
    PreparedInfo worst{hostile, hostile, hostile, hostile, hostile, true, 3, true, hostile};
    CHECK(event_prepared(worst).size() < MAX_EMIT_LINE_BYTES);
    CHECK(event_skip(hostile, hostile, hostile + hostile).size() < MAX_EMIT_LINE_BYTES);
    CHECK(event_loading(hostile).size() < MAX_EMIT_LINE_BYTES);
    CHECK(json_parse(event_loading(hostile), v, err) && v.get("preset")->string == hostile);
    s.temp_c = 61.25;
    s.arm_mhz = 1200;
    CHECK(json_parse(event_stats(s), v, err) && v.get("arm_mhz")->number == 1200 &&
          v.get("temp_c")->number >= 61.2);

    // emit_line refuses an oversize line.
    std::vector<std::string> sunk;
    set_emit_sink([&](const std::string& l) { sunk.push_back(l); });
    emit_line(std::string(MAX_EMIT_LINE_BYTES + 1, 'x'));
    emit_line("{\"event\":\"prepared\"}");
    set_emit_sink(nullptr);
    CHECK(sunk.size() == 2 && sunk[0].find("oversize_line") != std::string::npos &&
          sunk[1] == "{\"event\":\"prepared\"}");
}

// ---------------------------------------------------------------- manifest

static const char* MANIFEST = R"({
  "format": 1,
  "version": "2026.11.1",
  "presets": [
    {"file": "a.milk", "tags": [], "rpi3": {"rung": "640x360", "frame_ms": 21.5}, "compile_ms": 120, "eval_ms": 2.5},
    {"file": "b.milk", "rpi3": {"rung": "480x270"}},
    {"file": "c.milk", "rpi3": {"rung": "skip", "reason": "register_allocate"}},
    {"file": "high_frequency/d.milk"},
    {"file": "e.milk", "tags": ["high_frequency", "extreme"], "rpi3": "skip"},
    {"file": "f.milk", "compile_ms": 900},
    {"file": "../evil.milk"},
    {"file": "/abs.milk"},
    {"file": "notmilk.txt"},
    {"file": "a.milk"},
    {"file": "bad\nname.milk"},
    {"file": "g.milk", "rpi3": {"rung": "huge"}},
    {"file": 7},
    "string"
  ]
})";

static void test_manifest() {
    Manifest m;
    std::string err;
    CHECK(parse_manifest(MANIFEST, m, err));
    CHECK(m.version == "2026.11.1");
    CHECK(m.presets.size() == 6);
    CHECK(m.rejected == 8);
    CHECK(m.presets[0].file == "a.milk" && m.presets[0].rpi3_rung == (Resolution{640, 360}) &&
          m.presets[0].rpi3_frame_ms == 21.5 && m.presets[0].compile_ms == 120 &&
          m.presets[0].eval_ms == 2.5 && !m.presets[0].high_frequency);
    CHECK(m.presets[1].rpi3_rung == (Resolution{480, 270}) && m.presets[1].compile_ms < 0);
    CHECK(m.presets[2].rpi3_skip && m.presets[2].rpi3_reason == "register_allocate");
    CHECK(m.presets[3].high_frequency);
    CHECK(m.presets[4].high_frequency && m.presets[4].rpi3_skip && m.presets[4].tags.size() == 2);
    CHECK(m.presets[5].compile_ms == 900);

    CHECK(!parse_manifest(R"({"format":2,"presets":[]})", m, err));
    CHECK(!parse_manifest(R"({"presets":{}})", m, err));
    CHECK(!parse_manifest("[]", m, err));
    CHECK(parse_manifest(R"({"presets":[]})", m, err) && m.presets.empty());

    CHECK(valid_preset_file("x/y z.milk"));
    CHECK(!valid_preset_file("x//y.milk") && !valid_preset_file("./y.milk") && !valid_preset_file(".milk"));

    auto skips = parse_skip_list("a.milk\r\n\nb c.milk\nlast.milk");
    CHECK(skips.size() == 3 && skips.count("a.milk") && skips.count("b c.milk") && skips.count("last.milk"));
    CHECK(parse_skip_list("").empty());

    std::string path = tmp_path("manifest");
    {
        FILE* f = std::fopen(path.c_str(), "w");
        std::fputs(MANIFEST, f);
        std::fclose(f);
    }
    std::string text;
    CHECK(read_file(path, text) && text == MANIFEST);
    CHECK(!read_file(path, text, 10));
    CHECK(!read_file(path + ".missing", text));
    fs::remove(path);
}

// ---------------------------------------------------------------- presets

static std::vector<PresetEntry> entries(int n) {
    std::vector<PresetEntry> out;
    for (int i = 0; i < n; i++) {
        PresetEntry e;
        e.file = "p" + std::to_string(i) + ".milk";
        out.push_back(e);
    }
    return out;
}

static void test_rotation() {
    PresetManager::Config cfg;
    cfg.seed = 42;
    PresetManager pm(entries(10), {}, cfg);
    CHECK(pm.eligible_count() == 10);
    // Every preset once per round, no repeat across the round boundary.
    std::vector<std::string> seen;
    seen.push_back(pm.start("")->file);
    for (int i = 0; i < 29; i++) seen.push_back(pm.rotate()->file);
    for (int round = 0; round < 3; round++) {
        std::set<std::string> uniq(seen.begin() + round * 10, seen.begin() + round * 10 + 10);
        CHECK(uniq.size() == 10);
    }
    for (size_t i = 1; i < seen.size(); i++) CHECK(seen[i] != seen[i - 1]);

    // Same seed, same order.
    PresetManager pm2(entries(10), {}, cfg);
    CHECK(pm2.start("")->file == seen[0] && pm2.rotate()->file == seen[1]);
}

// Re-sending the filter's current value must not re-deal the shuffle bag.
static void test_high_frequency_keeps_bag() {
    PresetManager::Config cfg;
    cfg.seed = 42;
    PresetManager pm(entries(10), {}, cfg);
    std::set<std::string> seen;
    seen.insert(pm.start("")->file);
    for (int i = 0; i < 4; i++) seen.insert(pm.rotate()->file);
    CHECK(seen.size() == 5);
    CHECK(!pm.set_high_frequency(false));  // unchanged
    for (int i = 0; i < 5; i++) seen.insert(pm.rotate()->file);
    CHECK(seen.size() == 10);  // the rest of the round: no repeats

    // A real change still re-deals, and reports a cut when needed.
    CHECK(!pm.set_high_frequency(true));
    CHECK(!pm.set_high_frequency(true));
    CHECK(pm.high_frequency());
}

static void test_history() {
    PresetManager::Config cfg;
    cfg.seed = 7;
    PresetManager pm(entries(20), {}, cfg);
    std::string a = pm.start("")->file;
    std::string b = pm.next()->file;
    std::string c = pm.next()->file;
    CHECK(pm.prev()->file == b);
    CHECK(pm.prev()->file == a);
    CHECK(pm.prev() == nullptr);  // nothing earlier: no change
    CHECK(pm.current()->file == a);
    CHECK(pm.next()->file == b);  // forward through history
    CHECK(pm.next()->file == c);
    std::string d = pm.next()->file;  // past the end: a new pick
    CHECK(d != a && d != b && d != c);
    // A rotation from the middle of history drops the forward part.
    pm.prev();
    pm.prev();
    CHECK(pm.current()->file == b);
    std::string e = pm.rotate()->file;
    CHECK(pm.prev()->file == b);
    CHECK(pm.next()->file == e);
    // prev skips presets that became ineligible.
    CHECK(!pm.skip(b));
    CHECK(pm.prev()->file == a);
    CHECK(pm.skip(a));  // the current one
}

static void test_filters_and_lock() {
    auto es = entries(6);
    es[1].high_frequency = true;
    es[2].rpi3_skip = true;
    es[3].compile_ms = 900;
    PresetManager::Config cfg;
    cfg.seed = 3;
    cfg.gles2 = true;
    PresetManager pm(es, {"p4.milk"}, cfg);
    CHECK(pm.eligible_count() == 3);  // p0, p3, p5
    for (int i = 0; i < 30; i++) {
        const auto* p = pm.rotate();
        CHECK(p->file != "p1.milk" && p->file != "p2.milk" && p->file != "p4.milk");
    }
    // GLES3 builds ignore the rpi3 verdict.
    PresetManager::Config es3 = cfg;
    es3.gles2 = false;
    CHECK(PresetManager(es, {}, es3).eligible_count() == 5);

    // Locked start on an eligible file; an ineligible one falls back unlocked.
    PresetManager lk(es, {}, cfg);
    CHECK(lk.start("p3.milk")->file == "p3.milk" && lk.locked());
    CHECK(lk.refused_lock().empty());
    PresetManager lk2(es, {}, cfg);
    CHECK(lk2.start("p1.milk")->file != "p1.milk" && !lk2.locked());
    CHECK(lk2.refused_lock() == "high_frequency");
    PresetManager lk3(es, {}, cfg);
    CHECK(lk3.start("nope.milk") != nullptr && !lk3.locked());
    CHECK(lk3.refused_lock() == "unknown");
    PresetManager lk4(es, {"p0.milk"}, cfg);
    CHECK(lk4.start("p0.milk")->file != "p0.milk" && lk4.refused_lock() == "skipped");
    PresetManager lk5(es, {}, cfg);
    CHECK(lk5.start("p2.milk")->file != "p2.milk" && lk5.refused_lock() == "rpi3_skip");
    CHECK(lk5.start("")->file != "" && lk5.refused_lock().empty());

    // Turning high_frequency on admits p1; off again ejects it if shown.
    PresetManager hf(es, {}, cfg);
    hf.on_shown(*hf.start(""), false);
    CHECK(!hf.set_high_frequency(true));
    CHECK(hf.eligible_count() == 5);
    const PresetEntry* p = nullptr;
    for (int i = 0; i < 20 && (p == nullptr || p->file != "p1.milk"); i++) p = hf.rotate();
    CHECK(p != nullptr && p->file == "p1.milk");
    hf.on_shown(*p, false);
    CHECK(hf.set_high_frequency(false));

    // Expensive presets rotate at half weight: later in the round on average.
    double cheap_pos = 0, dear_pos = 0;
    int rounds = 400;
    auto many = entries(8);
    many[0].compile_ms = 900;
    PresetManager w(many, {}, cfg);
    w.start("");
    for (int r = 0; r < rounds; r++) {
        for (int k = 0; k < 8; k++) {
            const auto* q = w.rotate();
            if (q->file == "p0.milk") dear_pos += k;
            if (q->file == "p1.milk") cheap_pos += k;
        }
    }
    CHECK(dear_pos > cheap_pos * 1.1);

    // Nothing eligible.
    PresetManager none(entries(2), {"p0.milk", "p1.milk"}, cfg);
    CHECK(none.start("") == nullptr && none.eligible_count() == 0);
}

// The photosensitivity filter: with high_frequency presets off, none is
// ever picked, and one still rendered (playing or blending out) must be
// cut away.
static const PresetEntry* by_file(const PresetManager& pm, const std::string& file) {
    for (const auto& e : pm.entries())
        if (e.file == file) return &e;
    return nullptr;
}

static void test_high_frequency_safety() {
    // Mostly high_frequency: a random pick would land on one quickly.
    auto es = entries(40);
    for (int i = 0; i < 40; i++) es[static_cast<size_t>(i)].high_frequency = i % 10 != 0;  // p0, p10, p20, p30 safe
    auto safe = [](const PresetEntry* e) { return e != nullptr && !e->high_frequency; };

    // Startup: never one, whatever the seed; a locked one is refused.
    for (uint64_t seed = 1; seed <= 200; seed++) {
        PresetManager::Config cfg;
        cfg.seed = seed;
        PresetManager pm(es, {}, cfg);
        CHECK(safe(pm.start("")));
        PresetManager lk(es, {}, cfg);
        const PresetEntry* first = lk.start("p1.milk");
        CHECK(safe(first) && !lk.locked() && lk.refused_lock() == "high_frequency");
    }

    PresetManager::Config cfg;
    cfg.seed = 9;

    // rotate / next / prev never return one while off, history included.
    {
        PresetManager pm(es, {}, cfg);
        pm.set_high_frequency(true);
        pm.on_shown(*pm.start(""), false);
        for (int i = 0; i < 30; i++) pm.on_shown(*pm.rotate(), false);  // history full of them
        for (int i = 0; i < 15; i++) pm.prev();                          // somewhere in the middle
        pm.set_high_frequency(false);
        for (int i = 0; i < 40; i++) {
            const PresetEntry* q = pm.prev();
            if (q == nullptr) break;
            CHECK(safe(q));
        }
        for (int i = 0; i < 60; i++) CHECK(safe(pm.next()));
        for (int i = 0; i < 60; i++) CHECK(safe(pm.rotate()));
        CHECK(safe(pm.cut_target()));
    }

    // The playing preset is one when they turn off: cut, and to a safe one.
    {
        PresetManager pm(es, {}, cfg);
        pm.set_high_frequency(true);
        pm.on_shown(*by_file(pm, "p1.milk"), false);
        CHECK(!pm.high_frequency_on_screen());
        CHECK(pm.set_high_frequency(false));
        CHECK(pm.high_frequency_on_screen());
        const PresetEntry* to = pm.cut_target();
        CHECK(safe(to) && to->file != "p1.milk");
        pm.on_shown(*to, false);  // a cut
        CHECK(!pm.high_frequency_on_screen() && pm.outgoing() == nullptr);
    }

    // Mid-blend, the outgoing one is high_frequency and the safe incoming
    // one plays: still on screen until a cut. The cut target is the
    // playing preset itself (its blend completes at once).
    {
        PresetManager pm(es, {}, cfg);
        pm.set_high_frequency(true);
        pm.on_shown(*by_file(pm, "p1.milk"), false);
        pm.on_shown(*by_file(pm, "p10.milk"), true);  // blending p1 -> p10
        CHECK(pm.outgoing()->file == "p1.milk" && pm.showing()->file == "p10.milk");
        CHECK(pm.set_high_frequency(false));
        CHECK(pm.high_frequency_on_screen());
        const PresetEntry* to = pm.cut_target();
        CHECK(to != nullptr && to->file == "p10.milk");
        pm.on_shown(*to, false);
        CHECK(!pm.high_frequency_on_screen());
        // The same blend ending by itself also clears it.
        pm.set_high_frequency(true);
        pm.on_shown(*by_file(pm, "p2.milk"), true);  // p10 -> p2
        pm.on_shown(*by_file(pm, "p20.milk"), true);  // completes p10 -> p2; p2 -> p20
        CHECK(pm.outgoing()->file == "p2.milk");
        pm.set_high_frequency(false);
        CHECK(pm.high_frequency_on_screen());
        pm.on_blend_done();
        CHECK(!pm.high_frequency_on_screen());
    }

    // Mid-blend into a high_frequency one (the filter turned on during
    // it): both directions count, and the cut goes elsewhere.
    {
        PresetManager pm(es, {}, cfg);
        pm.set_high_frequency(true);
        pm.on_shown(*by_file(pm, "p0.milk"), false);
        pm.on_shown(*by_file(pm, "p3.milk"), true);  // p0 -> p3
        CHECK(pm.set_high_frequency(false));
        const PresetEntry* to = pm.cut_target();
        CHECK(safe(to));
        pm.on_shown(*to, false);
        CHECK(!pm.high_frequency_on_screen() && pm.outgoing() == nullptr);
    }

    // A locked high_frequency preset turning ineligible: the cut target is
    // a safe one (the caller keeps the lock on it).
    {
        PresetManager pm(es, {}, cfg);
        pm.set_high_frequency(true);
        const PresetEntry* lp = pm.start("p5.milk");
        CHECK(lp->file == "p5.milk" && pm.locked());
        pm.on_shown(*lp, false);
        CHECK(pm.set_high_frequency(false));
        CHECK(safe(pm.cut_target()) && pm.locked());
    }

    // Through select_preset: every candidate tried is safe, and failures
    // (skips) don't open a way to one.
    {
        PresetManager pm(es, {}, cfg);
        std::vector<std::string> tried;
        auto attempt = [&](const PresetEntry& e) {
            tried.push_back(e.file);
            return e.file == "p30.milk" ? Attempt::Loaded : Attempt::Failed;
        };
        Selection sel = select_preset(pm, pm.start(""), 8, attempt);
        while (sel == Selection::Deferred) sel = select_preset(pm, pm.rotate(), 8, attempt);
        for (const auto& f : tried) CHECK(!by_file(pm, f)->high_frequency);
        CHECK(sel == Selection::Switched || sel == Selection::Exhausted);
    }

    // A preset the manager doesn't own is ignored.
    {
        PresetManager pm(es, {}, cfg);
        PresetEntry stray;
        stray.file = "p1.milk";
        stray.high_frequency = true;
        pm.on_shown(stray, false);
        CHECK(pm.showing() == nullptr && !pm.high_frequency_on_screen());
    }
}

// ---------------------------------------------------------------- guard

static void feed(CostGuard& g, int frames, int64_t interval_us, CostGuard::Verdict& last,
                 bool measurable = true) {
    for (int i = 0; i < frames; i++) {
        auto v = g.on_flip(interval_us, measurable);
        if (v != CostGuard::Verdict::None) last = v;
    }
}

static void test_guard_ladder() {
    using V = CostGuard::Verdict;
    CostGuard::Config cfg;
    cfg.rungs = 2;
    cfg.start_interval = 2;
    cfg.min_fps = 20.0;
    cfg.settle_frames = 5;
    cfg.window_frames = 10;
    CostGuard g(cfg);
    CHECK(g.levels().size() == 2 && g.levels()[0].interval == 2 && g.levels()[1].rung == 1);
    CHECK(g.levels()[0].min_fps == 19.0 && g.levels()[1].min_fps == 19.0);  // 20 with the slack

    // 30 fps holds.
    CHECK(g.begin("fast.milk") == 0);
    V last = V::None;
    feed(g, 15, 33333, last);
    CHECK(last == V::Accept && g.level() == 0);
    CHECK(g.last_fps() > 29.9);

    // 20 fps (3 vblanks) is the floor: kept, even with one hitch per window.
    CHECK(g.begin("twenty.milk") == 0);
    last = V::None;
    feed(g, 5, 50000, last);
    feed(g, 9, 50000, last);
    feed(g, 1, 200000, last);  // dropped as the window's worst
    CHECK(last == V::Accept && g.level() == 0);

    // 15 fps steps down, then skips at the last rung.
    CHECK(g.begin("slow.milk") == 0);
    last = V::None;
    feed(g, 15, 66666, last);
    CHECK(last == V::StepDown && g.level() == 1);
    last = V::None;
    feed(g, 4, 66666, last);  // settling after the step: no verdict
    CHECK(last == V::None);
    feed(g, 11, 66666, last);
    CHECK(last == V::Skip);

    // Blend frames are not measured and restart the settle period.
    CHECK(g.begin("blend.milk") == 0);
    last = V::None;
    feed(g, 30, 100000, last, false);
    CHECK(last == V::None);
    feed(g, 15, 33333, last);
    CHECK(last == V::Accept);

    // A preset seen before resumes at its settled level; the manifest hint
    // is a starting level only.
    CHECK(g.begin("slow2.milk") == 0);
    feed(g, 15, 66666, last);
    CHECK(g.level() == 1);
    feed(g, 15, 40000, last);
    CHECK(last == V::Accept);
    CHECK(g.begin("slow2.milk") == 1);
    CHECK(g.begin("hinted.milk", 1) == 1);
    CHECK(g.begin("hinted2.milk", 5) == 1);  // below the ladder: the last level
    CHECK(g.measured_fps("fast.milk") > 29.9 && g.measured_fps("never.milk") < 0);

    // Thermal floor: nothing above rung 1 from now on.
    CHECK(g.begin("fast.milk") == 0);
    CHECK(g.set_rung_floor(1) && g.level() == 1);
    CHECK(g.begin("fresh.milk") == 1);
    CHECK(!g.set_rung_floor(1));
}

static void test_guard_60hz() {
    using V = CostGuard::Verdict;
    CostGuard::Config cfg;
    cfg.rungs = 3;
    cfg.start_interval = 1;
    cfg.refresh_hz = 60;
    cfg.settle_frames = 0;
    cfg.window_frames = 10;
    CostGuard g(cfg);
    // (r0,1) (r0,2) (r1,2) (r2,2)
    CHECK(g.levels().size() == 4 && g.levels()[0].interval == 1 && g.levels()[1].interval == 2 &&
          g.levels()[1].rung == 0 && g.levels()[3].rung == 2);
    CHECK(g.levels()[0].min_fps == 54.0);
    g.begin("x.milk");
    V last = V::None;
    feed(g, 10, 16667, last);
    CHECK(last == V::Accept && g.level() == 0);
    g.begin("y.milk");
    feed(g, 10, 33333, last);  // 30 fps at a 60 fps level: halve the rate first
    CHECK(last == V::StepDown && g.level() == 1 && g.current().interval == 2 && g.current().rung == 0);
    feed(g, 10, 33333, last);
    CHECK(last == V::Accept && g.level() == 1);
}

static void test_guard_min_fps() {
    using V = CostGuard::Verdict;
    // rpi3: interval 2 at 60 Hz presents at most 30 fps.
    CostGuard::Config cfg;
    cfg.rungs = 2;
    cfg.start_interval = 2;
    cfg.refresh_hz = 60;
    cfg.min_fps = 25;
    cfg.settle_frames = 0;
    cfg.window_frames = 10;
    {
        CostGuard g(cfg);
        CHECK(g.levels()[0].min_fps == 24.0);
        V last = V::None;
        g.begin("twenty.milk");
        feed(g, 10, 50000, last);  // 20 fps no longer holds
        CHECK(last == V::StepDown && g.level() == 1);
        feed(g, 10, 50000, last);
        CHECK(last == V::Skip && g.measured_fps("twenty.milk") > 19.9);
        g.begin("thirty.milk");
        feed(g, 10, 33333, last);
        CHECK(last == V::Accept);
    }
    {
        // Capped at what interval 2 can present: 30 (29 with the slack).
        cfg.min_fps = 60;
        CostGuard g(cfg);
        CHECK(g.levels()[0].min_fps == 29.0 && g.levels()[1].min_fps == 29.0);
        V last = V::None;
        g.begin("thirty.milk");
        feed(g, 10, 33333, last);
        CHECK(last == V::Accept);
    }
    // rpi4/5: (r0,1) (r0,2) (r1,2) at 60 Hz.
    cfg.start_interval = 1;
    cfg.min_fps = 20;
    {
        CostGuard g(cfg);
        CHECK(g.levels()[0].min_fps == 54.0 && g.levels()[1].min_fps == 19.0);
    }
    {
        // 35: no interval-2 level can hold it, so (r0,1) needs only the
        // floor, and a preset failing it skips without trying them.
        cfg.min_fps = 35;
        CostGuard g(cfg);
        CHECK(g.levels()[0].min_fps == 34.0 && g.levels()[1].min_fps == 34.0);
        V last = V::None;
        g.begin("forty.milk");
        feed(g, 10, 25000, last);
        CHECK(last == V::Accept && g.level() == 0);
        g.begin("thirty.milk");
        feed(g, 10, 33333, last);
        CHECK(last == V::Skip);
    }
    {
        cfg.min_fps = 60;
        CostGuard g(cfg);
        CHECK(g.levels()[0].min_fps == 59.0);
        V last = V::None;
        g.begin("sixty.milk");
        feed(g, 10, 16667, last);
        CHECK(last == V::Accept && g.level() == 0);
    }
    {
        // Live changes: the current preset is judged against the new floor.
        cfg.min_fps = 20;
        CostGuard g(cfg);
        V last = V::None;
        g.begin("half.milk");
        feed(g, 10, 33333, last);
        CHECK(last == V::StepDown && g.level() == 1);
        feed(g, 10, 33333, last);
        CHECK(last == V::Accept && g.level() == 1);
        CHECK(g.set_min_fps(20) == V::None && g.begin("half.milk") == 1);  // unchanged: kept
        feed(g, 10, 33333, last);
        CHECK(last == V::Accept);
        CHECK(g.set_min_fps(25) == V::None && g.min_fps() == 25 && g.level() == 1);
        CHECK(g.levels()[1].min_fps == 24.0);
        feed(g, 10, 50000, last);  // 20 fps fails the new floor at once
        CHECK(last == V::StepDown && g.level() == 2);
        // Raised past what interval 2 can present: skipped straight away.
        g.begin("half2.milk");
        feed(g, 10, 33333, last);
        CHECK(g.level() == 1);
        CHECK(g.set_min_fps(40) == V::Skip);
        CHECK(g.on_flip(33333, true) == V::None);  // nothing measured any more
        // Settled levels are forgotten: re-measured from the hint.
        CHECK(g.set_min_fps(20) == V::None);
        CHECK(g.begin("half.milk") == 0);
        // Thermal floor past the interval-1 level with a floor interval 2
        // can't present: the first window skips.
        CHECK(g.set_min_fps(40) == V::None);
        g.set_rung_floor(1);
        CHECK(g.begin("cool.milk") == 2);
        feed(g, 10, 33333, last);
        CHECK(last == V::Skip);
    }
}

// ---------------------------------------------------------------- pacing

static void test_pacer() {
    FramePacer p(60.0, 2);
    CHECK(p.period_us() == 16667);
    CHECK(p.earliest_submit() == 0);
    const int64_t T = 1'000'000;
    p.reset(T);
    // The next flip is held until just after the in-between vblank.
    CHECK(p.earliest_submit() == T + 16667 + 2000);
    // Rendering now with no flip pending: on screen one slot after the last.
    CHECK(p.predict_present(T + 1000, false, 10000) == T + 33334);
    // A flip pending: the slot after that one.
    CHECK(p.predict_present(T + 1000, true, 10000) == T + 66668);
    // A slow frame lands on the next vblank it can make.
    CHECK(p.predict_present(T + 30000, false, 20000) == T + 33334 + 16667);
    CHECK(p.on_flip(T + 33334) == 33334 && p.late() == 0);
    CHECK(p.on_flip(T + 33334 + 50000) == 50000 && p.late() == 1);

    FramePacer q(60.0, 1);
    q.reset(T);
    CHECK(q.earliest_submit() == T);
    CHECK(q.predict_present(T + 100, true, 5000) == T + 2 * 16667);
}

// ---------------------------------------------------------------- thermal

static void test_thermal() {
    using A = ThermalGuard::Action;
    ThermalGuard t;
    CHECK(t.update(0, 70) == A::None);
    CHECK(t.update(1, 78) == A::None);
    CHECK(t.update(10.5, 79) == A::None);
    CHECK(t.update(11, 79) == A::DropRung);
    CHECK(t.update(30, 80) == A::None);  // once per session
    CHECK(t.dropped());
    CHECK(t.update(31, 83) == A::Exit);

    ThermalGuard u;
    CHECK(u.update(0, 79) == A::None);
    CHECK(u.update(5, 77) == A::None);  // cooled: the 10 s restart
    CHECK(u.update(9, 79) == A::None);
    CHECK(u.update(18, 79) == A::None);
    CHECK(u.update(19, 79) == A::DropRung);

    std::string path = tmp_path("temp");
    {
        FILE* f = std::fopen(path.c_str(), "w");
        std::fputs("61250\n", f);
        std::fclose(f);
    }
    CHECK(read_temp_c(path) && *read_temp_c(path) == 61.25);
    CHECK(read_cpu_mhz(path) && *read_cpu_mhz(path) == 61);
    CHECK(!read_temp_c(path + ".missing"));
    fs::remove(path);
}

// ---------------------------------------------------------------- stderr

static void test_stderr_classifier() {
    StderrClassifier c;
    std::vector<StderrFinding> found;
    std::string text = "MESA: error: Failed to register allocate: QIR dump follows\n";
    for (int i = 0; i < 5000; i++) text += "  qir: mov r" + std::to_string(i) + ", t" + std::to_string(i) + "\n";
    text += "MESA-LOADER: failed to open vc4\n";
    text += "libEGL warning: harmless\n";
    text += std::string(5000, 'z') + "\n";
    text += StderrClassifier::marker_line(3);
    // Fed in awkward chunks.
    for (size_t i = 0; i < text.size(); i += 7) c.feed(text.data() + i, std::min<size_t>(7, text.size() - i), found);
    CHECK(found.size() == 3);
    CHECK(found[0].kind == StderrFinding::Kind::RegisterAllocate);
    CHECK(found[1].kind == StderrFinding::Kind::DriverError && found[1].text == "MESA-LOADER: failed to open vc4");
    CHECK(found[2].kind == StderrFinding::Kind::Marker && found[2].marker == 3);
    CHECK(c.discarded_bytes() > 60000);
    for (auto& f : found) CHECK(f.text.size() <= StderrClassifier::MAX_LINE);
}

static void test_stderr_capture() {
    StderrCapture cap;
    CHECK(cap.start());
    std::string dump = "MESA: error: Failed to register allocate:\n";
    for (int i = 0; i < 20000; i++) dump += "qir line " + std::to_string(i) + "\n";  // > pipe buffer
    CHECK(::write(2, dump.data(), dump.size()) == static_cast<ssize_t>(dump.size()));
    CHECK(cap.sync(2000));
    CHECK(cap.register_allocate_failures() == 1);
    auto f = cap.take_findings();
    CHECK(f.size() == 1 && f[0].kind == StderrFinding::Kind::RegisterAllocate);
    CHECK(cap.take_findings().empty());
    CHECK(cap.discarded_bytes() > 100000);
    cap.stop();
    CHECK(cap.sync(10));  // not capturing: trivially in sync
}


static void test_selection() {
    PresetManager::Config cfg;
    cfg.seed = 3;
    // 20 presets of which only p17 loads: more failures than one batch.
    PresetManager pm(entries(20), {}, cfg);
    std::vector<std::string> tried;
    auto attempt = [&](const PresetEntry& e) {
        tried.push_back(e.file);
        return e.file == "p17.milk" ? Attempt::Loaded : Attempt::Failed;
    };
    const PresetEntry* first = pm.start("");
    int calls = 0;
    Selection sel = Selection::Deferred;
    while (sel == Selection::Deferred && calls < 10) {
        size_t before = tried.size();
        sel = select_preset(pm, first, 8, attempt);
        CHECK(tried.size() - before <= 8);  // a batch at most per call
        if (sel == Selection::Deferred) CHECK(tried.size() - before == 8);
        first = pm.rotate();
        calls++;
    }
    CHECK(sel == Selection::Switched);
    CHECK(tried.back() == "p17.milk");
    CHECK(std::set<std::string>(tried.begin(), tried.end()).size() == tried.size());  // no retries
    CHECK(pm.eligible_count() == 20 - (tried.size() - 1));

    // Nothing loads: Deferred per batch, then Exhausted once none are left.
    PresetManager none(entries(10), {}, cfg);
    auto fail_all = [](const PresetEntry&) { return Attempt::Failed; };
    CHECK(select_preset(none, none.start(""), 8, fail_all) == Selection::Deferred);
    CHECK(none.eligible_count() == 2);
    CHECK(select_preset(none, none.rotate(), 8, fail_all) == Selection::Exhausted);
    CHECK(none.eligible_count() == 0 && none.rotate() == nullptr);

    // Abort stops at once without skipping.
    PresetManager ab(entries(5), {}, cfg);
    CHECK(select_preset(ab, ab.start(""), 8, [](const PresetEntry&) { return Attempt::Abort; }) ==
          Selection::Aborted);
    CHECK(ab.eligible_count() == 5);

    // A failed switch to a preloaded preset is a skip like a failed
    // preload; the selection moves on and the playing preset is untouched.
    SkipCause sc = activation_failure("Error switching to preset: bad texture", "older error");
    CHECK(sc.reason == "load_failed" && sc.message == "Error switching to preset: bad texture");
    sc = activation_failure("", "[ProjectM] Error switching to preset");
    CHECK(sc.reason == "load_failed" && sc.message == "[ProjectM] Error switching to preset");
    CHECK(activation_failure("", "").message.empty());
}

static void test_poll_round() {
    std::vector<std::string> order;
    bool awaiting = true;
    auto awaited = [&] { return awaiting; };
    auto dispatch = [&] {
        order.push_back("flip");
        awaiting = false;
    };
    // `release` waits for the pending flip itself.
    auto release = [&] {
        order.push_back("commands");
        awaiting = false;
    };
    auto checks = [&] { order.push_back("checks"); };
    // Both ready: the flip first, the checks, commands last, never a
    // second dispatch.
    handle_poll_round({true, true}, awaited, dispatch, checks, release);
    CHECK((order == std::vector<std::string>{"flip", "checks", "commands"}));
    // The flip was consumed elsewhere (stale readiness): no dispatch.
    order.clear();
    awaiting = false;
    handle_poll_round({true, true}, awaited, dispatch, checks, release);
    CHECK((order == std::vector<std::string>{"checks", "commands"}));
    order.clear();
    awaiting = true;
    handle_poll_round({false, true}, awaited, dispatch, checks, release);
    CHECK((order == std::vector<std::string>{"checks", "commands"}));
    // Nothing ready (a poll timeout): the checks still run.
    order.clear();
    handle_poll_round({false, false}, awaited, dispatch, checks, release);
    CHECK((order == std::vector<std::string>{"checks"}));

    // A GPU reset logged before a `take` in the same round: the check sees
    // it first, so the take waits instead of showing the hung preset.
    SwitchState sw;
    int taken = 0, deferred = 0;
    auto take = [&] { sw.request_take() ? taken++ : deferred++; };
    handle_poll_round({false, true}, awaited, [] {}, [&] { sw.hang(); }, take);
    CHECK(taken == 0 && deferred == 1 && sw.take_pending());
}

static void test_switch_state() {
    SwitchState sw;
    CHECK(!sw.pending() && sw.smooth() && !sw.holding_frames());
    CHECK(sw.request_take() && !sw.take_pending() && !sw.take_due());

    // Commands and the rotation timer replace each other...
    sw.request(Switch::Next);
    sw.request(Switch::Prev);
    CHECK(sw.requested() == Switch::Prev);
    CHECK(sw.begin() == Switch::Prev && !sw.pending());

    // ...but never a pending eject or retry.
    sw.eject();
    sw.request(Switch::Prev);
    sw.request(Switch::Rotate);
    CHECK(sw.requested() == Switch::Eject);
    sw.eject_if_idle();
    CHECK(sw.begin() == Switch::Eject);
    sw.retry("next");
    sw.request(Switch::Next);
    CHECK(sw.requested() == Switch::Retry && std::string(sw.retry_cause()) == "next");
    sw.selected(Selection::Switched, false);
    sw.begin();

    // A failed preload batch leaves the playing preset: frames go on, blends too.
    CHECK(sw.begin() == Switch::None);
    sw.selected(Selection::Deferred, false);
    sw.retry("rotate");
    CHECK(sw.smooth() && !sw.holding_frames() && sw.request_take());
    sw.begin();
    sw.selected(Selection::Switched, false);

    // An activated failure holds frames and cuts until a switch succeeds.
    sw.request(Switch::Rotate);
    sw.begin();
    sw.selected(Selection::Deferred, true);
    sw.retry("rotate");
    CHECK(!sw.smooth() && sw.holding_frames());
    sw.begin();
    sw.selected(Selection::Deferred, false);  // the force carries over batches
    sw.retry("rotate");
    CHECK(!sw.smooth() && sw.holding_frames());
    sw.begin();
    sw.selected(Selection::Switched, false);
    CHECK(sw.smooth() && !sw.holding_frames() && !sw.pending());

    // The showing preset hung the GPU: eject it with a cut, hold frames,
    // and a take waits for the replacement (once).
    sw.request(Switch::Next);
    sw.hang();
    CHECK(sw.requested() == Switch::Eject && !sw.smooth() && sw.holding_frames());
    CHECK(!sw.request_take() && sw.take_pending() && !sw.take_due());
    sw.request(Switch::Prev);  // a prev with nothing earlier can't drop the eject
    CHECK(sw.begin() == Switch::Eject && !sw.smooth());
    sw.selected(Selection::Deferred, false);
    sw.retry("eject");
    CHECK(sw.holding_frames() && !sw.take_due());
    CHECK(sw.begin() == Switch::Retry && !sw.smooth());
    sw.selected(Selection::Switched, false);
    CHECK(!sw.holding_frames() && sw.take_due() && !sw.take_due() && !sw.take_pending());

    // A release drops a waiting take.
    sw.hang();
    CHECK(!sw.request_take());
    sw.cancel_take();
    sw.begin();
    sw.selected(Selection::Switched, false);
    CHECK(!sw.take_due());
}

// The non-presenting loop's recovery after the prepared preset hung the
// GPU: selection batches until a preset loads, the take only after, and
// none when nothing loads.
static void test_recovery_round() {
    PresetManager::Config cfg;
    cfg.seed = 5;
    auto run = [&](int n, const std::string& loads, std::vector<std::string>& tried, int& taken,
                   std::string& exit_reason) {
        PresetManager pm(entries(n), {}, cfg);
        const PresetEntry* showing = pm.start("");
        SwitchState sw;
        exit_reason.clear();
        taken = 0;
        auto attempt = [&](const PresetEntry& e) {
            tried.push_back(e.file);
            return e.file == loads ? Attempt::Loaded : Attempt::Failed;
        };
        // As App::apply_switch(): the eject or retry is a rotate pick.
        auto apply = [&] {
            const Switch s = sw.begin();
            CHECK(s == Switch::Eject || s == Switch::Retry);
            CHECK(!sw.smooth());  // a cut, never a blend with the hung preset
            const Selection sel = select_preset(pm, pm.rotate(), 8, attempt);
            sw.selected(sel, false);
            if (sel == Selection::Deferred) sw.retry("eject");
            if (sel == Selection::Exhausted) exit_reason = "no_presets";
        };
        auto take = [&] {
            if (!sw.request_take()) return;
            CHECK(!sw.holding_frames());
            taken++;
        };
        auto stopped = [&] { return !exit_reason.empty(); };

        pm.skip(showing->file);
        sw.hang();
        take();  // arrives right after the reset: waits
        CHECK(taken == 0 && sw.take_pending());
        int rounds = 0;
        while (exit_reason.empty() && taken == 0 && rounds++ < 10) {
            const size_t before = tried.size();
            recovery_round(sw, apply, take, stopped);
            CHECK(tried.size() - before <= 8);
            CHECK(std::find(tried.begin(), tried.end(), showing->file) == tried.end());
        }
        return rounds;
    };

    // 20 presets, only p17 loads: more than one batch, then the take.
    std::vector<std::string> tried;
    int taken = 0;
    std::string exit_reason;
    int rounds = run(20, "p17.milk", tried, taken, exit_reason);
    CHECK(taken == 1 && exit_reason.empty() && tried.back() == "p17.milk");
    CHECK(rounds >= 2 || tried.size() <= 8);

    // Nothing loads: batches until exhausted, no_presets, never a take.
    tried.clear();
    run(12, "none.milk", tried, taken, exit_reason);
    CHECK(taken == 0 && exit_reason == "no_presets" && tried.size() == 11);
}

static void test_drain_lines() {
    // `exit` then `take` in one read: the take never runs, and the drain
    // returns although more input keeps coming.
    LineBuffer lines;
    std::vector<std::string> handled;
    bool exit_decided = false;
    int reads = 0;
    auto endless = [&](char* buf, size_t cap) -> ssize_t {
        reads++;
        const std::string chunk = reads == 1 ? "{\"cmd\":\"next\"}\n{\"cmd\":\"exit\"}\n{\"cmd\":\"take\"}\n"
                                             : "{\"cmd\":\"take\"}\n";
        const size_t n = std::min(cap, chunk.size());
        std::copy_n(chunk.data(), n, buf);
        return static_cast<ssize_t>(n);
    };
    auto on_line = [&](std::string_view line) {
        handled.emplace_back(line);
        if (line.find("exit") != line.npos) exit_decided = true;
    };
    auto stop = [&] { return exit_decided; };
    CHECK(drain_lines(lines, endless, on_line, stop) == DrainEnd::Stopped);
    CHECK(reads == 1);
    CHECK((handled == std::vector<std::string>{"{\"cmd\":\"next\"}", "{\"cmd\":\"exit\"}"}));
    // Already decided: nothing is read at all.
    CHECK(drain_lines(lines, endless, on_line, stop) == DrainEnd::Stopped && reads == 1);

    // Input that never runs dry, no exit: the drain gives the loop back.
    LineBuffer l2;
    handled.clear();
    exit_decided = false;
    auto takes = [](char* buf, size_t cap) -> ssize_t {
        const std::string chunk = "{\"cmd\":\"take\"}\n";
        const size_t n = std::min(cap, chunk.size());
        std::copy_n(chunk.data(), n, buf);
        return static_cast<ssize_t>(n);
    };
    CHECK(drain_lines(l2, takes, on_line, stop, 4) == DrainEnd::Budget);
    CHECK(handled.size() == 4);

    // Would block, EOF, errors.
    auto eagain = [](char*, size_t) -> ssize_t {
        errno = EAGAIN;
        return -1;
    };
    auto eof = [](char*, size_t) -> ssize_t { return 0; };
    auto ebadf = [](char*, size_t) -> ssize_t {
        errno = EBADF;
        return -1;
    };
    CHECK(drain_lines(l2, eagain, on_line, stop) == DrainEnd::Drained);
    CHECK(drain_lines(l2, eof, on_line, stop) == DrainEnd::Eof);
    CHECK(drain_lines(l2, ebadf, on_line, stop) == DrainEnd::Eof);
}

// Runs `body` in a child with stdout on a pipe. Returns the exit status
// (-1: still running after `wait_ms`, then killed), its output and how long
// it ran.
static int run_child(const std::function<void()>& body, int wait_ms, std::string& out, int64_t& ran_ms) {
    int p[2];
    if (pipe(p) != 0) return -2;
    std::fflush(stdout);
    const auto t0 = std::chrono::steady_clock::now();
    pid_t pid = fork();
    if (pid == 0) {
        dup2(p[1], 1);
        close(p[0]);
        close(p[1]);
        body();
        _exit(99);
    }
    close(p[1]);
    int status = 0, code = -1;
    while (true) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        ran_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
        if (r == pid) {
            code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            break;
        }
        if (ran_ms > wait_ms) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    char buf[4096];
    ssize_t n;
    while ((n = read(p[0], buf, sizeof(buf))) > 0) out.append(buf, static_cast<size_t>(n));
    close(p[0]);
    return code;
}

// A shutdown that hangs (here: a blocking read that never returns, as on
// the DRM fd) still emits `exiting` and exits with its code in budget.
static void hang_forever() {
    int p[2];
    if (pipe(p) == 0) {
        char c;
        while (true) (void)!read(p[0], &c, 1);
    }
}

static void test_exit_guard() {
    std::string out;
    int64_t ms = 0;
    int code = run_child(
        [] {
            ExitGuard g(nullptr, 150);
            g.start();
            g.arm("requested", 0);
            hang_forever();
        },
        3000, out, ms);
    CHECK(code == 0);
    CHECK(ms >= 140 && ms < 1000);
    CHECK(out == "{\"event\":\"exiting\",\"reason\":\"requested\"}\n");

    // The main thread already sent `exiting`: not repeated; the code holds.
    out.clear();
    code = run_child(
        [] {
            ExitGuard g(nullptr, 100);
            g.start();
            g.arm("output_lost", 1);
            emit_line(event_exiting("output_lost"));
            g.exiting_sent();
            hang_forever();
        },
        3000, out, ms);
    CHECK(code == 1 && ms < 1000);
    CHECK(out == "{\"event\":\"exiting\",\"reason\":\"output_lost\"}\n");

    // A signal arms it even if the main thread never gets to.
    out.clear();
    code = run_child(
        [] {
            static std::atomic<int> sig{0};
            ExitGuard g(&sig, 100);
            g.start();
            sig.store(1);
            hang_forever();
        },
        3000, out, ms);
    CHECK(code == 0 && ms < 1000);
    CHECK(out == "{\"event\":\"exiting\",\"reason\":\"signal\"}\n");

    // A teardown that finishes in budget: stop() and no event from the guard.
    out.clear();
    code = run_child(
        [] {
            ExitGuard g(nullptr, 100);
            g.start();
            g.arm("eof", 0);
            g.stop();
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            _exit(7);
        },
        3000, out, ms);
    CHECK(code == 7 && out.empty());

    // stdout and stderr both full (readers that never read): the watchdog's
    // writes give up and the exit still comes in budget.
    out.clear();
    code = run_child(
        [] {
            static int err_pipe[2];
            if (pipe(err_pipe) != 0) _exit(98);
            dup2(err_pipe[1], 2);
            for (int fd : {1, 2}) {
                const int fl = fcntl(fd, F_GETFL);
                fcntl(fd, F_SETFL, fl | O_NONBLOCK);
                const std::string junk(4096, 'x');
                while (write(fd, junk.data(), junk.size()) > 0) {}
                fcntl(fd, F_SETFL, fl);  // blocking again, as the renderer's are
            }
            ExitGuard g(nullptr, 100);
            g.start();
            g.arm("requested", 3);
            hang_forever();
        },
        3000, out, ms);
    CHECK(code == 3);
    CHECK(ms >= 90 && ms < 1000);
    CHECK(out.find("exiting") == std::string::npos);  // no room: dropped, not blocked on

    // The writer stuck elsewhere: emit_line_within gives up.
    out.clear();
    code = run_child(
        [] {
            std::thread([] { emit_line_within("{\"a\":1}", 50); }).join();
            set_emit_sink([](const std::string&) { std::this_thread::sleep_for(std::chrono::seconds(10)); });
            std::thread stuck([] { emit_line("x"); });
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            const bool sent = emit_line_within("{\"b\":2}", 50);
            _exit(sent ? 1 : 0);
        },
        3000, out, ms);
    CHECK(code == 0 && out == "{\"a\":1}\n");
}

// ---------------------------------------------------------------- pcm

static void fill_indexed(std::vector<int16_t>& chunk, uint64_t first, uint32_t frames) {
    chunk.resize(size_t{frames} * 2);
    for (uint32_t i = 0; i < frames; i++) {
        chunk[2 * i] = static_cast<int16_t>((first + i) & 0x7fff);
        chunk[2 * i + 1] = static_cast<int16_t>(-static_cast<int16_t>((first + i) & 0x7fff));
    }
}

static void test_pcm_feed_alignment() {
    std::string path = tmp_path("ring");
    auto w = RingWriter::open(path);
    CHECK(w != nullptr);

    PcmFeed feed(path, 0);
    feed.set_offset_us(5'000);  // RAW = MONOTONIC + 5 ms
    feed.maintain(1);
    std::vector<int16_t> out(PcmFeed::FRAMES * 2);

    // Nothing written yet: silence.
    CHECK(feed.read(1'000'000, out.data()) == PcmFeed::Result::Silent && out[0] == 0);

    // 480-frame (10 ms) chunks at 48 kHz; chunk k's last frame plays at
    // RAW base + (k + 1) * 10 ms.
    const int64_t base = 2'000'000;
    std::vector<int16_t> chunk;
    for (uint64_t k = 0; k < 20; k++) {
        fill_indexed(chunk, k * 480, 480);
        w->commit(9, 48000, chunk.data(), 480, base + static_cast<int64_t>(k + 1) * 10'000);
    }
    // A MONOTONIC target 5 ms earlier than chunk 9's end in RAW time.
    const int64_t t_mono = base + 100'000 - 5'000;
    CHECK(feed.read(t_mono, out.data()) == PcmFeed::Result::Ok);
    // Ends exactly at chunk 9's last frame: frame 10*480-1.
    CHECK(out[(PcmFeed::FRAMES - 1) * 2] == static_cast<int16_t>(10 * 480 - 1));
    CHECK(out[0] == static_cast<int16_t>(10 * 480 - PcmFeed::FRAMES));

    // The A/V offset shifts the window: +2 ms = 96 frames later.
    PcmFeed shifted(path, 2'000);
    shifted.set_offset_us(5'000);
    shifted.maintain(1);
    CHECK(shifted.read(t_mono - 10'000, out.data()) == PcmFeed::Result::Ok);
    CHECK(out[(PcmFeed::FRAMES - 1) * 2] == static_cast<int16_t>(9 * 480 - 1 + 96));

    // Exactly the newest audio's end.
    const int64_t newest_end = base + 200'000;
    CHECK(feed.read(newest_end - 5'000, out.data()) == PcmFeed::Result::Ok);
    CHECK(out[(PcmFeed::FRAMES - 1) * 2] == static_cast<int16_t>(20 * 480 - 1));
    // Past it (not played yet, a pause, a stale ring): silence.
    std::fill(out.begin(), out.end(), int16_t{1});
    CHECK(feed.read(newest_end - 5'000 + 1'000, out.data()) == PcmFeed::Result::Silent && out[0] == 0 &&
          out[(PcmFeed::FRAMES - 1) * 2 + 1] == 0);
    CHECK(feed.read(newest_end + 1'000'000, out.data()) == PcmFeed::Result::Silent);

    // A new epoch reads as no data until it has some.
    w->end_stream();
    CHECK(feed.read(t_mono, out.data()) == PcmFeed::Result::Silent);
    CHECK(feed.ok == 2 && feed.silent == 4);

    // No ring at all, or none configured: silence.
    PcmFeed missing(path + ".missing", 0);
    missing.maintain(1);
    CHECK(missing.read(t_mono, out.data()) == PcmFeed::Result::Silent);
    PcmFeed off("", 0);
    off.maintain(1);
    CHECK(off.read(t_mono, out.data()) == PcmFeed::Result::Silent);

    // An underrun: a gap of over a chunk between chunks. A target in it is
    // silence; a window reaching back across it is zero before the gap.
    auto wg = RingWriter::open(path + ".gap");
    PcmFeed gap(path + ".gap", 0);
    gap.set_offset_us(0);
    gap.maintain(1);
    fill_indexed(chunk, 0, 480);
    wg->commit(3, 48000, chunk.data(), 480, base + 10'000);
    fill_indexed(chunk, 480, 480);
    wg->commit(3, 48000, chunk.data(), 480, base + 100'000);  // 80 ms of nothing before it
    CHECK(gap.read(base + 50'000, out.data()) == PcmFeed::Result::Silent);
    CHECK(gap.read(base + 100'000, out.data()) == PcmFeed::Result::Ok);
    CHECK(out[(PcmFeed::FRAMES - 1) * 2] == static_cast<int16_t>(959));
    CHECK(out[(PcmFeed::FRAMES - 480) * 2] == static_cast<int16_t>(480) && out[0] == 0);
    fs::remove(path + ".gap");

    // A replaced ring file (new inode) is remapped on maintain().
    fs::remove(path);
    auto w2 = RingWriter::open(path);
    fill_indexed(chunk, 0, 480);
    w2->commit(1, 48000, chunk.data(), 480, base + 10'000);
    feed.maintain(5'000'000);
    CHECK(feed.read(base + 10'000 - 5'000, out.data()) == PcmFeed::Result::Ok);
    CHECK(out[(PcmFeed::FRAMES - 1) * 2] == 479);
    fs::remove(path);

    // The offset sample is RAW - MONOTONIC.
    int64_t off_us = sample_raw_offset_us();
    int64_t direct = monotonic_raw_us() - monotonic_us();
    CHECK(off_us - direct < 2000 && direct - off_us < 2000);
}

static void test_tone() {
    TestTone tone;
    std::vector<int16_t> a(576 * 2), b(576 * 2);
    tone.fill(1'000'000, 576, a.data());  // first call: a full window
    int peak = 0;
    for (int16_t v : a) peak = std::max(peak, std::abs(static_cast<int>(v)));
    CHECK(peak > 1000);
    // 5 ms later: 220 new frames; the window slides by that much.
    tone.fill(1'005'000, 576, b.data());
    CHECK(std::equal(a.begin() + 220 * 2, a.end(), b.begin()));
    // Time going backwards adds nothing.
    tone.fill(1'000'000, 576, a.data());
    CHECK(a == b);

    // A normal 33 ms frame interval asks for 576 frames but ~1455 have
    // passed: the tone advances by all of them (the beat keeps 120 BPM),
    // and the window matches a tone sampled finely to the same times.
    TestTone frame_rate, fine;
    std::vector<int16_t> fa(576 * 2), fb(576 * 2);
    const int64_t t0 = 5'000'000;
    frame_rate.fill(t0, 576, fa.data());
    fine.fill(t0, 576, fb.data());
    bool same = true;
    for (int f = 1; f <= 90; f++) {
        const int64_t t = t0 + int64_t{f} * 33'000;
        for (int64_t u = t - 30'000; u <= t; u += 3'000) fine.fill(u, 576, fb.data());
        frame_rate.fill(t, 576, fa.data());
        same = same && fa == fb;
    }
    CHECK(same);
    const uint64_t expect = 576 + uint64_t{90} * 33'000 * TestTone::RATE / 1'000'000;
    CHECK(frame_rate.position() == expect && fine.position() == expect);
    // A long silence is stepped over, not generated.
    frame_rate.fill(t0 + 3'600'000'000LL, 576, fa.data());
    CHECK(frame_rate.position() == 576 + uint64_t{3600} * TestTone::RATE);
}

// ---------------------------------------------------------------- kmsg

static void append_file(const std::string& path, const std::string& text) {
    FILE* f = std::fopen(path.c_str(), "a");
    std::fputs(text.c_str(), f);
    std::fclose(f);
}

static void test_kmsg_watch() {
    // vc4 (rpi3) and v3d (rpi4/5) wording, as /dev/kmsg records.
    CHECK(is_gpu_reset("6,4242,512345678,-;[drm] Resetting GPU."));
    CHECK(is_gpu_reset("3,99,1,-;[drm:v3d_gpu_reset_for_timeout [v3d]] *ERROR* Resetting GPU for hang."));
    CHECK(!is_gpu_reset("6,4243,512345679,-;vc4-drm soc:gpu: [drm] fb0: vc4drmfb frame buffer device"));
    CHECK(!is_gpu_reset(" SUBSYSTEM=platform"));
    CHECK(kmsg_message("6,4242,512345678,-;[drm] Resetting GPU.") == "[drm] Resetting GPU.");
    CHECK(kmsg_message("12,7,3,c,caller=T1;a;b") == "a;b");
    CHECK(kmsg_message("no record header; here") == "no record header; here");

    // Opened at the end: earlier lines are never seen.
    const std::string path = tmp_path("kmsg");
    fs::remove(path);
    append_file(path, "6,1,1,-;[drm] Resetting GPU.\n");
    KmsgWatch w;
    std::string err, msg;
    CHECK(!KmsgWatch().open(tmp_path("kmsg_missing"), err) && !err.empty());
    CHECK(w.open(path, err) && w.active());
    CHECK(w.poll_resets(&msg) == 0 && msg.empty());

    append_file(path, "6,2,2,-;usb 1-1.3: new device\n SUBSYSTEM=usb\n6,3,3,-;[drm] Resetting GPU.\n");
    CHECK(w.poll_resets(&msg) == 1 && msg == "[drm] Resetting GPU.");
    CHECK(w.poll_resets(&msg) == 0);

    // A line split across reads counts once, when it is complete.
    append_file(path, "6,4,4,-;[drm] Resetting");
    CHECK(w.poll_resets() == 0);
    append_file(path, " GPU.\n6,5,5,-;[drm] Resetting GPU.\n");
    CHECK(w.poll_resets() == 2);
    w.close();
    CHECK(!w.active() && w.poll_resets() == 0);
    fs::remove(path);

    // One skip per preset; resets within the window are the same hang.
    GpuResetThrottle t(3000000);
    CHECK(t.report("a.milk", 10000000));
    CHECK(!t.report("b.milk", 11000000));  // 1 s later: the same hang
    CHECK(!t.report("a.milk", 60000000));  // ~50 s later, same preset: already skipped
    CHECK(t.report("b.milk", 70000000));
    CHECK(!t.report("c.milk", 72000000));  // window counts from the last reset seen
    CHECK(t.report("c.milk", 76000000));
}

// ---------------------------------------------------------------- user presets and selection

static void write_file(const std::string& path, const std::string& text) {
    FILE* f = std::fopen(path.c_str(), "w");
    std::fwrite(text.data(), 1, text.size(), f);
    std::fclose(f);
}

static PresetEntry entry(const std::string& file, bool high_frequency = false) {
    PresetEntry e;
    e.file = file;
    e.high_frequency = high_frequency;
    return e;
}

static UserSelection selection(std::vector<std::string> hidden, std::vector<std::string> playlist,
                               bool playlist_enabled, std::vector<std::string> favourites = {}) {
    UserSelection s;
    s.hidden.insert(hidden.begin(), hidden.end());
    s.playlist.insert(playlist.begin(), playlist.end());
    s.favourites.insert(favourites.begin(), favourites.end());
    s.playlist_enabled = playlist_enabled;
    return s;
}

static void test_user_options() {
    Options o;
    std::string err;
    CHECK(parse_options(base_args(), o, err) && o.user_dir.empty() && o.selection_file.empty());
    auto args = base_args();
    args.insert(args.end(), {"--user-dir", "/data/milkdrop/user", "--selection-file", "/run/md-selection.json"});
    Options o2;
    CHECK(parse_options(args, o2, err) && o2.user_dir == "/data/milkdrop/user" &&
          o2.selection_file == "/run/md-selection.json");
    for (const char* opt : {"--user-dir", "--selection-file"}) {
        auto empty = base_args();
        empty.insert(empty.end(), {opt, ""});
        Options o3;
        CHECK(!parse_options(empty, o3, err) && err == std::string("bad ") + opt);
        auto missing = base_args();
        missing.push_back(opt);
        CHECK(!parse_options(missing, o3, err) && err == std::string("missing value for ") + opt);
    }
    CHECK(std::string(USAGE).find("--user-dir DIR") != std::string::npos &&
          std::string(USAGE).find("--selection-file PATH") != std::string::npos);
}

static void test_user_protocol() {
    std::string err;
    auto c = parse_command(R"({"cmd":"play","preset":"user/My Preset.milk","lock":true})", err);
    CHECK(c && c->type == Command::Type::Play && c->string_value == "user/My Preset.milk" && c->bool_value);
    c = parse_command(R"({"cmd":"play","preset":"a/b.milk"})", err);
    CHECK(c && c->type == Command::Type::Play && c->string_value == "a/b.milk" && !c->bool_value);
    c = parse_command(R"({"cmd":"play","preset":"x.milk","lock":false})", err);
    CHECK(c && !c->bool_value);
    for (const char* bad : {R"({"cmd":"play"})", R"({"cmd":"play","preset":7})", R"({"cmd":"play","preset":""})",
                            R"({"cmd":"play","preset":"../x.milk"})", R"({"cmd":"play","preset":"/x.milk"})",
                            R"({"cmd":"play","preset":"x.txt"})", R"({"cmd":"play","preset":"a\nb.milk"})",
                            R"({"cmd":"play","preset":"a\u0000b.milk"})", R"({"cmd":"play","preset":"a\u007fb.milk"})",
                            R"({"cmd":"play","preset":"a//b.milk"})"}) {
        CHECK(!parse_command(bad, err) && err == "bad play preset");
    }
    CHECK(!parse_command(R"({"cmd":"play","preset":"x.milk","lock":1})", err) && err == "bad play lock");
    std::string too_long = R"({"cmd":"play","preset":")" + std::string(MAX_PRESET_NAME_BYTES - 4, 'a') + R"(.milk"})";
    CHECK(!parse_command(too_long, err));
    CHECK(parse_command(R"({"cmd":"reload_user"})", err)->type == Command::Type::ReloadUser);
    CHECK(parse_command(R"({"cmd":"reload_selection"})", err)->type == Command::Type::ReloadSelection);

    // The longest valid id, every byte escaped, still fits a stdin line.
    const std::string longest = std::string(MAX_PRESET_NAME_BYTES - 5, '"') + ".milk";
    CHECK(valid_preset_file(longest));
    const std::string line = R"({"cmd":"play","lock":true,"preset":")" + json_escape(longest) + "\"}\n";
    LineBuffer lb;
    std::vector<std::string> lines;
    lb.feed(line.data(), line.size(), [&](std::string_view l) { lines.emplace_back(l); });
    CHECK(lines.size() == 1 && lb.overflowed == 0);
    c = parse_command(lines.at(0), err);
    CHECK(c && c->type == Command::Type::Play && c->string_value == longest && c->bool_value);

    JsonValue v;
    CHECK(json_parse(event_play_refused("user/a \"b\".milk", "high_frequency"), v, err) &&
          v.get("event")->string == "play_refused" && v.get("preset")->string == "user/a \"b\".milk" &&
          v.get("reason")->string == "high_frequency" && v.object.size() == 3);
    CHECK(event_play_refused(longest, std::string(500, '"')).size() < MAX_EMIT_LINE_BYTES);
    CHECK(json_parse(event_user_reloaded(12, 3, 2, 1), v, err) && v.get("event")->string == "user_reloaded" &&
          v.get("presets")->number == 12 && v.get("added")->number == 3 && v.get("removed")->number == 2 &&
          v.get("rejected")->number == 1);
    CHECK(json_parse(event_selection(9007199254740992LL, 40, true, false), v, err) &&
          v.get("event")->string == "selection" && v.get("gen")->number == 9007199254740992.0 &&
          v.get("eligible")->number == 40 && v.get("playlist_fallback")->boolean &&
          !v.get("hidden_fallback")->boolean);
}

static void test_user_manifest() {
    // The pack never plays ids in the user namespace.
    Manifest pack;
    std::string err;
    CHECK(parse_manifest(R"({"presets":[{"file":"a.milk"},{"file":"user/x.milk"},{"file":"users/y.milk"},
                            {"file":"user/sub/z.milk"},{"file":"bad"}]})",
                         pack, err));
    CHECK(pack.presets.size() == 4 && pack.rejected == 1);
    CHECK(drop_user_ids(pack) == 2);
    CHECK(pack.presets.size() == 2 && pack.presets[0].file == "a.milk" && pack.presets[1].file == "users/y.milk" &&
          pack.rejected == 3);
    CHECK(is_user_id("user/a.milk") && !is_user_id("user") && !is_user_id("users/a.milk") && !is_user_id("a.milk"));

    const fs::path dir = tmp_path("userdir");
    fs::remove_all(dir);
    Manifest user;
    CHECK(load_user_manifest("", user, err) == FileStatus::Missing && user.presets.empty());
    CHECK(load_user_manifest(dir.string(), user, err) == FileStatus::Missing);  // no dir at all
    fs::create_directories(dir);
    CHECK(load_user_manifest(dir.string(), user, err) == FileStatus::Missing);  // no manifest

    const std::string long_name = std::string(MAX_PRESET_NAME_BYTES - USER_PREFIX.size() - 4, 'n') + ".milk";
    CHECK(valid_preset_file(long_name));  // valid in the pack, too long with the prefix
    write_file((dir / "manifest.json").string(),
               R"({"format":1,"version":"user","presets":[
                    {"file":"One.milk","tags":["uploaded"],"sha256":"ab12"},
                    {"file":"Flash.milk","tags":["uploaded","high_frequency"]},
                    {"file":"sub/Two.milk"},
                    {"file":"One.milk"},
                    {"file":"../escape.milk"},
                    {"file":")" + long_name + R"("}]})");
    CHECK(load_user_manifest(dir.string(), user, err) == FileStatus::Ok);
    CHECK(user.version == "user" && user.presets.size() == 3 && user.rejected == 3);
    CHECK(user.presets[0].file == "user/One.milk" && user.presets[0].tags == std::vector<std::string>{"uploaded"} &&
          !user.presets[0].high_frequency && user.presets[0].compile_ms < 0 && user.presets[0].rpi3_rung.width == 0 &&
          !user.presets[0].rpi3_skip);
    CHECK(user.presets[1].file == "user/Flash.milk" && user.presets[1].high_frequency);
    CHECK(user.presets[2].file == "user/sub/Two.milk");

    write_file((dir / "manifest.json").string(), R"({"presets":[)");
    CHECK(load_user_manifest(dir.string(), user, err) == FileStatus::Invalid && !err.empty() && user.presets.empty());
    write_file((dir / "manifest.json").string(), R"({"format":2,"presets":[]})");
    CHECK(load_user_manifest(dir.string(), user, err) == FileStatus::Invalid && err == "unsupported manifest format");
    fs::remove(dir / "manifest.json");
    fs::create_directories(dir / "manifest.json");  // not a file
    CHECK(load_user_manifest(dir.string(), user, err) == FileStatus::Invalid);
    fs::remove_all(dir);

    std::string text;
    const std::string big = tmp_path("big");
    write_file(big, std::string(100, 'x'));
    CHECK(read_file_status(big, text, 100, err) == FileStatus::Ok && text.size() == 100);
    CHECK(read_file_status(big, text, 99, err) == FileStatus::Invalid && text.empty() && !err.empty());
    CHECK(read_file_status(big + ".missing", text, 100, err) == FileStatus::Missing);
    CHECK(read_file_status(big + "/below", text, 100, err) == FileStatus::Missing);  // ENOTDIR
    fs::remove(big);

    CHECK(preset_file_path("/p", "/u", "a/b.milk") == "/p/presets/a/b.milk");
    CHECK(preset_file_path("/p", "/u", "user/sub/c.milk") == "/u/presets/sub/c.milk");
    CHECK(preset_file_path("/p", "", "user/c.milk").empty());
    CHECK(preset_file_path("/p", "/u", "users/c.milk") == "/p/presets/users/c.milk");
    CHECK((texture_search_paths("/p", "/u") == std::vector<std::string>{"/p/textures", "/u/textures"}));
    CHECK((texture_search_paths("/p", "") == std::vector<std::string>{"/p/textures"}));
}

static void test_selection_file() {
    UserSelection s;
    std::string err;
    CHECK(parse_selection(R"({"gen":7,"favourites":["a.milk","user/f.milk"],"hidden":["h.milk"],
                              "playlist":["a.milk","nope.milk","../bad.milk","x.txt"],"playlist_enabled":true,
                              "future":1})",
                          s, err));
    CHECK(s.gen == 7 && s.playlist_enabled && s.favourites.size() == 2 && s.favourites.count("user/f.milk") &&
          s.hidden.size() == 1 && s.hidden.count("h.milk"));
    // Invalid ids dropped; unknown ones kept (a reload may add them).
    CHECK(s.playlist.size() == 2 && s.playlist.count("a.milk") && s.playlist.count("nope.milk"));
    UserSelection empty;
    CHECK(parse_selection("{}", empty, err) && empty.gen == 0 && !empty.playlist_enabled && empty.playlist.empty());
    CHECK(parse_selection(R"({"hidden":null})", empty, err) && empty.hidden.empty());

    // Malformed: false and `out` untouched.
    for (const char* bad : {"", "[]", "{", R"({"gen":-1})", R"({"gen":1.5})", R"({"gen":"1"})",
                            R"({"gen":1e300})", R"({"playlist_enabled":1})", R"({"favourites":"a.milk"})",
                            R"({"hidden":[1]})", R"({"playlist":{"a":1}})"}) {
        CHECK(!parse_selection(bad, s, err) && !err.empty());
    }
    CHECK(s.gen == 7 && s.playlist.size() == 2);

    const std::string path = tmp_path("selection.json");
    fs::remove(path);
    CHECK(load_selection(path, s, err) == FileStatus::Missing && s.gen == 0 && s.playlist.empty());
    s.gen = 3;
    CHECK(load_selection("", s, err) == FileStatus::Missing && s.gen == 0);
    write_file(path, R"({"gen":4,"hidden":["h.milk"]})");
    CHECK(load_selection(path, s, err) == FileStatus::Ok && s.gen == 4 && s.hidden.count("h.milk"));
    write_file(path, R"({"gen":5,"hidden":)");
    CHECK(load_selection(path, s, err) == FileStatus::Invalid && s.gen == 4 && s.hidden.count("h.milk"));
    // Over the cap: refused unread, whatever it holds.
    std::string big = R"({"gen":6,"hidden":[)";
    while (big.size() <= MAX_SELECTION_BYTES) big += R"("x.milk",)";
    big += R"("y.milk"]})";
    write_file(path, big);
    CHECK(load_selection(path, s, err) == FileStatus::Invalid && s.gen == 4);
    fs::remove(path);
}

// The selection over rotation (P6): hidden never rotates, the playlist
// narrows it, and an empty result falls back rather than ending rotation.
static void test_selection_rotation() {
    PresetManager::Config cfg;
    cfg.seed = 11;
    auto es = entries(10);
    es[9].high_frequency = true;
    PresetManager pm(es, {"p8.milk"}, cfg);  // eligible: p0..p7
    pm.start("");

    auto info = pm.set_selection(selection({"p0.milk", "p1.milk"}, {}, false));
    CHECK(info.pool == PresetManager::Pool::Unhidden && info.size == 6 && !info.playlist_fallback &&
          !info.hidden_fallback);
    for (int i = 0; i < 40; i++) {
        const std::string f = pm.rotate()->file;
        CHECK(f != "p0.milk" && f != "p1.milk" && f != "p8.milk" && f != "p9.milk");
    }

    // Playlist on: playlist, eligible and unhidden only. Skipped, filtered,
    // hidden and unknown ids on it don't count.
    info = pm.set_selection(
        selection({"p0.milk"}, {"p0.milk", "p2.milk", "p3.milk", "p8.milk", "p9.milk", "user/gone.milk"}, true));
    CHECK(info.pool == PresetManager::Pool::Playlist && info.size == 2 && !info.playlist_fallback);
    std::set<std::string> seen;
    for (int i = 0; i < 20; i++) seen.insert(pm.rotate()->file);
    CHECK((seen == std::set<std::string>{"p2.milk", "p3.milk"}));
    // Off: the playlist is ignored.
    info = pm.set_selection(selection({}, {"p2.milk"}, false));
    CHECK(info.pool == PresetManager::Pool::Unhidden && info.size == 8);

    // Nothing on the playlist can rotate: the full eligible, unhidden set.
    info = pm.set_selection(selection({"p1.milk"}, {"p1.milk", "p8.milk", "p9.milk", "nope.milk"}, true));
    CHECK(info.pool == PresetManager::Pool::Unhidden && info.size == 7 && info.playlist_fallback);
    seen.clear();
    for (int i = 0; i < 40; i++) seen.insert(pm.rotate()->file);
    CHECK(seen.size() == 7 && !seen.count("p1.milk"));
    info = pm.set_selection(selection({}, {}, true));
    CHECK(info.playlist_fallback && info.size == 8);

    // Everything hidden: rotation still goes on, over all eligible ones.
    info = pm.set_selection(selection({"p0.milk", "p1.milk", "p2.milk", "p3.milk", "p4.milk", "p5.milk", "p6.milk",
                                       "p7.milk"},
                                      {"p0.milk"}, true));
    CHECK(info.pool == PresetManager::Pool::Eligible && info.size == 8 && info.playlist_fallback &&
          info.hidden_fallback);
    for (int i = 0; i < 20; i++) CHECK(pm.rotate() != nullptr);

    // The playlist empties mid-deal (its presets get skipped): the next
    // pick falls back, never null.
    PresetManager drain(entries(6), {}, cfg);
    drain.start("");
    drain.set_selection(selection({}, {"p1.milk", "p2.milk"}, true));
    CHECK(drain.rotate() != nullptr);
    drain.skip("p1.milk");
    drain.skip("p2.milk");
    CHECK(drain.rotation_pool().playlist_fallback);
    for (int i = 0; i < 10; i++) {
        const PresetEntry* p = drain.rotate();
        CHECK(p != nullptr && p->file != "p1.milk" && p->file != "p2.milk");
    }

    // The current preset turning hidden or off the playlist keeps playing;
    // history passes over hidden ones.
    PresetManager h(entries(10), {}, cfg);
    const std::string a = h.start("")->file;
    const std::string b = h.next()->file;
    const std::string c = h.next()->file;
    h.set_selection(selection({b, c}, {a}, true));
    CHECK(h.current()->file == c);
    CHECK(h.prev()->file == a);  // b is hidden
    CHECK(h.next()->file != b);
    // A locked start may name a hidden preset (an explicit pick).
    PresetManager lk(entries(4), {}, cfg);
    lk.set_selection(selection({"p2.milk"}, {}, false));
    CHECK(lk.start("p2.milk")->file == "p2.milk" && lk.locked());
}

// Favourites hold three tickets per deal: they play three times as often
// as plain presets, never twice in a row. The GLES2 half weight still only
// orders a deal.
static void test_favourites() {
    PresetManager::Config cfg;
    cfg.seed = 5;
    cfg.gles2 = true;
    auto many = entries(10);
    many[2].compile_ms = 900;  // a favourite, expensive: still three tickets
    PresetManager w(many, {}, cfg);
    w.set_selection(selection({}, {}, false, {"p0.milk", "p2.milk"}));
    std::map<std::string, int> plays;
    std::string last = w.start("")->file;
    plays[last]++;
    const int deals = 300, per_deal = 8 + 2 * 3;
    for (int i = 1; i < deals * per_deal; i++) {
        const std::string f = w.rotate()->file;
        CHECK(f != last);  // deal boundaries included
        plays[f]++;
        last = f;
    }
    const double plain = plays["p1.milk"];
    for (const char* f : {"p3.milk", "p5.milk", "p9.milk"}) CHECK(std::abs(plays[f] - plain) <= 2);
    CHECK(plays["p0.milk"] > 2.9 * plain && plays["p0.milk"] < 3.1 * plain);
    CHECK(plays["p2.milk"] > 2.9 * plain && plays["p2.milk"] < 3.1 * plain);

    // A deal: every pool member, favourites three times, none adjacent.
    PresetManager deal(entries(10), {}, cfg);
    deal.set_selection(selection({}, {}, false, {"p4.milk"}));
    std::vector<std::string> round{deal.start("")->file};
    for (int i = 0; i < 40; i++) round.push_back(deal.rotate()->file);
    for (size_t i = 1; i < round.size(); i++) CHECK(round[i] != round[i - 1]);
    CHECK(std::count(round.begin(), round.end(), "p4.milk") >= 8);

    // Tiny pools: two presets alternate; one repeats (nothing else to play).
    PresetManager two(entries(2), {}, cfg);
    two.set_selection(selection({}, {}, false, {"p0.milk"}));
    last = two.start("")->file;
    for (int i = 0; i < 30; i++) {
        const std::string f = two.rotate()->file;
        CHECK(f != last);
        last = f;
    }
    PresetManager one(entries(1), {}, cfg);
    one.set_selection(selection({}, {}, false, {"p0.milk"}));
    CHECK(one.start("")->file == "p0.milk");
    for (int i = 0; i < 5; i++) CHECK(one.rotate() != nullptr && one.current()->file == "p0.milk");

    // An unfavoured preset's leftover tickets are dropped at the re-deal.
    PresetManager re(entries(6), {}, cfg);
    re.set_selection(selection({}, {}, false, {"p1.milk"}));
    re.start("");
    for (int i = 0; i < 3; i++) re.rotate();
    re.set_selection(selection({}, {}, false, {}));
    std::set<std::string> fresh;
    for (int i = 0; i < 6; i++) fresh.insert(re.rotate()->file);
    CHECK(fresh.size() == 6);
}

// reload_user: append-only entries with tombstones, so pointers the
// caller holds (current_, what on_shown reported) stay valid.
static void test_user_reload() {
    PresetManager::Config cfg;
    cfg.seed = 13;
    std::vector<PresetEntry> es = entries(4);
    es.push_back(entry("user/u0.milk"));
    es.push_back(entry("user/u1.milk"));
    PresetManager pm(es, {}, cfg);
    const PresetEntry* u0 = pm.start("user/u0.milk");
    CHECK(u0 != nullptr && u0->file == "user/u0.milk" && pm.locked());
    pm.on_shown(*u0, false);
    const PresetEntry* p0 = by_file(pm, "p0.milk");

    // u0 (current, locked, showing) removed; u2 added; non-user ids ignored.
    auto r = pm.set_user_presets({entry("user/u1.milk"), entry("user/u2.milk"), entry("p0.milk", true)});
    CHECK(r.presets == 2 && r.added == 1 && r.removed == 1 && !r.cut);
    CHECK(pm.current() == u0 && pm.showing() == u0 && u0->file == "user/u0.milk" && pm.locked());
    CHECK(pm.removed(4) && !pm.eligible(4) && !p0->high_frequency);
    std::string why;
    CHECK(pm.find_playable("user/u0.milk", why) == nullptr && why == "unknown");
    CHECK(pm.find_playable("user/u2.milk", why) != nullptr && why.empty());
    CHECK(pm.eligible_count() == 6);
    // Never picked again: rotation, next, cut_target.
    for (int i = 0; i < 40; i++) CHECK(pm.rotate()->file != "user/u0.milk");

    // Many reloads: earlier entries never move.
    for (int n = 0; n < 50; n++) {
        std::vector<PresetEntry> batch{entry("user/u1.milk"), entry("user/u2.milk")};
        for (int k = 0; k < 20; k++) batch.push_back(entry("user/n" + std::to_string(n * 20 + k) + ".milk"));
        pm.set_user_presets(std::move(batch));
    }
    CHECK(by_file(pm, "p0.milk") == p0 && u0->file == "user/u0.milk" && pm.showing() == u0);
    CHECK(pm.entries().size() == 4 + 3 + 50 * 20);
    r = pm.set_user_presets({entry("user/u1.milk"), entry("user/u2.milk")});
    CHECK(r.removed == 20 && r.presets == 2 && r.added == 0);

    // An id that comes back revives its own entry, refreshed in place.
    PresetEntry back = entry("user/u0.milk");
    back.tags = {"uploaded", "v2"};
    r = pm.set_user_presets({back, entry("user/u1.milk"), entry("user/u2.milk")});
    CHECK(r.added == 1 && r.removed == 0 && r.presets == 3);
    CHECK(by_file(pm, "user/u0.milk") == u0 && u0->tags.size() == 2 && pm.eligible(4));
    CHECK(pm.find_playable("user/u0.milk", why) == u0);

    // Flagged fast-flashing while it shows and the filter is off: cut.
    r = pm.set_user_presets({entry("user/u0.milk", true), entry("user/u1.milk"), entry("user/u2.milk")});
    CHECK(r.cut && pm.high_frequency_on_screen() && u0->high_frequency);
    const PresetEntry* to = pm.cut_target();
    CHECK(to != nullptr && to != u0 && !to->high_frequency);
    pm.on_shown(*to, false);
    CHECK(!pm.high_frequency_on_screen());

    // History passes over tombstones both ways.
    PresetManager hist(entries(10), {}, cfg);
    hist.set_user_presets({entry("user/a.milk"), entry("user/b.milk")});
    const std::string first = hist.start("")->file;
    std::string why2;
    hist.played(*hist.find_playable("user/a.milk", why2), false);
    hist.played(*hist.find_playable("user/b.milk", why2), false);
    const std::string last = hist.next()->file;
    hist.set_user_presets({entry("user/b.milk")});  // a removed
    CHECK(hist.prev()->file == "user/b.milk");
    CHECK(hist.prev()->file == first);  // over user/a
    CHECK(hist.next()->file == "user/b.milk");
    CHECK(hist.next()->file == last);
    hist.set_user_presets({});
    CHECK(hist.prev()->file == first);  // over both

    // Missing user dir at start, uploads mid-session.
    PresetManager late(entries(2), {}, cfg);
    late.start("");
    r = late.set_user_presets({entry("user/new.milk")});
    CHECK(r.added == 1 && r.presets == 1 && late.eligible_count() == 3);
    std::set<std::string> seen;
    for (int i = 0; i < 12; i++) seen.insert(late.rotate()->file);
    CHECK(seen.count("user/new.milk"));
    // A session skip by id holds for user presets too.
    late.skip("user/new.milk");
    CHECK(late.find_playable("user/new.milk", why) == nullptr && why == "skipped");
    PresetManager sk(std::vector<PresetEntry>{entry("p.milk"), entry("user/s.milk")}, {"user/s.milk"}, cfg);
    CHECK(sk.start("user/s.milk")->file == "p.milk" && sk.refused_lock() == "skipped");
}

// play: any eligible preset (hidden, off the playlist), never a skipped,
// unknown, removed or (filter off) high_frequency one.
static void test_play() {
    PresetManager::Config cfg;
    cfg.seed = 17;
    cfg.gles2 = true;
    auto es = entries(6);
    es[1].high_frequency = true;
    es[2].rpi3_skip = true;
    es.push_back(entry("user/up.milk"));
    PresetManager pm(es, {"p3.milk"}, cfg);
    pm.set_selection(selection({"p4.milk"}, {"p0.milk"}, true));
    const std::string first = pm.start("")->file;
    CHECK(first == "p0.milk");
    std::string why;
    CHECK(pm.find_playable("nope.milk", why) == nullptr && why == "unknown");
    CHECK(pm.find_playable("p3.milk", why) == nullptr && why == "skipped");
    CHECK(pm.find_playable("p1.milk", why) == nullptr && why == "high_frequency");
    CHECK(pm.find_playable("p2.milk", why) == nullptr && why == "rpi3_skip");
    const PresetEntry* hid = pm.find_playable("p4.milk", why);  // hidden: an explicit pick may
    CHECK(hid != nullptr && why.empty());
    const PresetEntry* off = pm.find_playable("p5.milk", why);  // off the playlist
    CHECK(off != nullptr && why.empty());
    pm.set_high_frequency(true);
    CHECK(pm.find_playable("p1.milk", why) != nullptr);
    pm.set_high_frequency(false);

    // Played: the current preset, in history, locked or not.
    pm.played(*off, true);
    CHECK(pm.current() == off && pm.locked());
    pm.played(*pm.find_playable("user/up.milk", why), false);
    CHECK(pm.current()->file == "user/up.milk" && !pm.locked());
    CHECK(pm.prev() == off && pm.prev()->file == first);
    // A copy isn't ours.
    PresetEntry copy = *off;
    pm.played(copy, true);
    CHECK(pm.current()->file == first && !pm.locked());

    // The load: one candidate, no rotation fallback; a failure skips it.
    std::vector<std::string> tried;
    auto fail_all = [&](const PresetEntry& e) {
        tried.push_back(e.file);
        return Attempt::Failed;
    };
    CHECK(select_preset(pm, pm.find_playable("p5.milk", why), 1, fail_all) == Selection::Deferred);
    CHECK((tried == std::vector<std::string>{"p5.milk"}));
    CHECK(pm.find_playable("p5.milk", why) == nullptr && why == "skipped");
    CHECK(pm.current()->file == first);  // the playing preset stays current
}

static void test_switch_play() {
    SwitchState sw;
    // A play replaces a plain request, and a later one replaces it.
    sw.request(Switch::Rotate);
    sw.request_play();
    CHECK(sw.requested() == Switch::Play);
    sw.request(Switch::Next);
    CHECK(sw.requested() == Switch::Next);
    sw.request_play();
    sw.eject_if_idle();
    CHECK(sw.begin() == Switch::Play && !sw.pending());
    sw.selected(Selection::Switched, false);
    sw.play_done();
    CHECK(!sw.pending() && sw.smooth());

    // A preload failure: the playing preset just carries on.
    sw.request_play();
    sw.begin();
    sw.selected(Selection::Deferred, false);
    sw.play_failed();
    CHECK(!sw.pending() && sw.smooth() && !sw.holding_frames());

    // A failure after activation holds the transition slot: cut past it.
    sw.request_play();
    sw.begin();
    sw.selected(Selection::Deferred, true);
    sw.play_failed();
    CHECK(sw.requested() == Switch::Retry && std::string(sw.retry_cause()) == "eject" && !sw.smooth() &&
          sw.holding_frames());
    sw.begin();
    sw.selected(Selection::Switched, false);

    // It takes over an eject, which comes back if it fails...
    sw.eject();
    sw.request_play();
    CHECK(sw.requested() == Switch::Play);
    sw.request(Switch::Next);  // ...and nothing else drops it
    sw.request(Switch::Rotate);
    CHECK(sw.requested() == Switch::Play);
    CHECK(sw.begin() == Switch::Play);
    sw.selected(Selection::Deferred, false);
    sw.play_failed();
    CHECK(sw.requested() == Switch::Eject);
    sw.begin();
    sw.selected(Selection::Switched, false);
    // ...or is done when it loads.
    sw.eject();
    sw.request_play();
    sw.begin();
    sw.selected(Selection::Switched, false);
    sw.play_done();
    sw.play_failed();  // stale: nothing to restore
    CHECK(!sw.pending());

    // A retry too, with its cause.
    sw.retry("next");
    sw.request_play();
    sw.begin();
    sw.selected(Selection::Deferred, false);
    sw.play_failed();
    CHECK(sw.requested() == Switch::Retry && std::string(sw.retry_cause()) == "next");
    sw.begin();
    sw.selected(Selection::Switched, false);

    // A hang while a play is pending: the play goes first, with a cut and
    // frames held; the eject follows if it fails.
    sw.request_play();
    sw.hang();
    CHECK(sw.requested() == Switch::Play && !sw.smooth() && sw.holding_frames());
    CHECK(!sw.request_take());
    sw.begin();
    sw.selected(Selection::Deferred, false);
    sw.play_failed();
    CHECK(sw.requested() == Switch::Eject && sw.holding_frames() && !sw.take_due());
    sw.begin();
    sw.selected(Selection::Switched, false);
    CHECK(!sw.holding_frames() && sw.take_due());

    // A skip (eject) arriving while a play is pending doesn't drop it.
    sw.request_play();
    sw.eject();
    CHECK(sw.requested() == Switch::Play);
    sw.begin();
    sw.selected(Selection::Switched, false);
    sw.play_done();
    CHECK(!sw.pending());
}

// A play while not presenting (prepared or released) loads in the next
// round, and before a `take` that follows it, so the take shows it.
static void test_play_before_take() {
    std::vector<std::string> log;
    SwitchState sw;
    Attempt outcome = Attempt::Loaded;
    bool activated = false;
    // As App::apply_switch() for a play.
    auto apply = [&] {
        const Switch s = sw.begin();
        log.push_back(s == Switch::Play ? "play" : "other");
        if (s != Switch::Play) return;
        if (outcome == Attempt::Loaded) {
            sw.selected(Selection::Switched, false);
            sw.play_done();
        } else {
            sw.selected(Selection::Deferred, activated);
            sw.play_failed();
        }
    };
    auto take = [&] {
        if (sw.request_take()) log.push_back("take");
    };
    bool stop = false;
    auto stopped = [&] { return stop; };

    // Released, a play arrives: the next round loads it; no take.
    sw.request_play();
    recovery_round(sw, apply, take, stopped);
    CHECK((log == std::vector<std::string>{"play"}) && !sw.pending());
    // Other requests still wait for presenting.
    log.clear();
    sw.request(Switch::Next);
    recovery_round(sw, apply, take, stopped);
    CHECK(log.empty() && sw.requested() == Switch::Next);
    sw.begin();

    // play then take in one read: the play loads first.
    sw.request_play();
    CHECK(take_ready(sw, apply, stopped));
    CHECK((log == std::vector<std::string>{"play"}));
    // No play pending: take_ready is request_take().
    log.clear();
    CHECK(take_ready(sw, apply, stopped) && log.empty());

    // A play whose preload fails: the take shows the preset that stayed.
    outcome = Attempt::Failed;
    sw.request_play();
    CHECK(take_ready(sw, apply, stopped) && !sw.pending());
    // One that fails after activation holds the slot: the take waits for
    // the replacement, which a recovery round brings.
    activated = true;
    log.clear();
    sw.request_play();
    CHECK(!take_ready(sw, apply, stopped) && sw.take_pending());
    CHECK(sw.requested() == Switch::Retry && sw.holding_frames());
    sw.begin();
    sw.selected(Selection::Switched, false);
    CHECK(sw.take_due());
    activated = false;

    // Frames held (the prepared preset hung) and a play pending: the take
    // waits; the recovery round runs the play, then the take.
    outcome = Attempt::Loaded;
    log.clear();
    sw.hang();
    sw.request_play();
    CHECK(!take_ready(sw, apply, stopped) && log.empty());
    recovery_round(sw, apply, take, stopped);
    CHECK((log == std::vector<std::string>{"play", "take"}));

    // An exit decided during the play: no take.
    log.clear();
    sw.request_play();
    auto apply_then_stop = [&] {
        apply();
        stop = true;
    };
    CHECK(!take_ready(sw, apply_then_stop, stopped) && !sw.take_pending());
}

// The no-repeat rule can leave a favourite's tickets unplayable in tiny
// pools (it can play at most every other pick): the bag stays bounded,
// and nothing repeats unless the pool is one preset.
static void test_favourites_tiny_pools() {
    struct Case {
        int presets;
        std::vector<std::string> favourites;
        double fav_share_min, fav_share_max;
    };
    const std::vector<Case> cases = {
        {1, {"p0.milk"}, 1.0, 1.0},
        {2, {"p0.milk"}, 0.49, 0.51},             // alternates
        {2, {"p0.milk", "p1.milk"}, 0.49, 0.51},  // alternates
        {3, {"p0.milk"}, 0.45, 0.51},             // every other pick at most
        {4, {"p0.milk"}, 0.45, 0.51},
    };
    for (const Case& c : cases) {
        PresetManager::Config cfg;
        cfg.seed = 21;
        PresetManager pm(entries(c.presets), {}, cfg);
        pm.set_selection(selection({}, {}, false, c.favourites));
        std::string last = pm.start("")->file;
        int fav = last == "p0.milk", repeats = 0;
        size_t max_bag = 0;
        const int draws = 100000;
        for (int i = 1; i < draws; i++) {
            const PresetEntry* p = pm.rotate();
            CHECK(p != nullptr);
            if (p == nullptr) break;
            repeats += p->file == last;
            fav += p->file == "p0.milk";
            last = p->file;
            max_bag = std::max(max_bag, pm.bag_size());
        }
        const size_t deal = static_cast<size_t>(c.presets) + 2 * c.favourites.size();
        CHECK(max_bag <= deal + 3);  // a deal plus at most a favourite's carried tickets
        CHECK(c.presets == 1 ? repeats == draws - 1 : repeats == 0);
        const double share = static_cast<double>(fav) / draws;
        CHECK(share >= c.fav_share_min && share <= c.fav_share_max);
    }
}

// A replaced upload: the guard forgets what it learnt about the id, but
// the old content still playing keeps its level and records nothing.
static void test_guard_forget() {
    using V = CostGuard::Verdict;
    CostGuard::Config cfg;
    cfg.rungs = 3;
    cfg.start_interval = 2;
    cfg.settle_frames = 5;
    cfg.window_frames = 10;
    CostGuard g(cfg);
    V last = V::None;
    CHECK(g.begin("user/a.milk") == 0);
    feed(g, 15, 66666, last);  // 15 fps: down a rung
    CHECK(last == V::StepDown && g.level() == 1 && g.measured_fps("user/a.milk") > 14);
    g.begin("p.milk");
    CHECK(g.begin("user/a.milk") == 1);  // settled this session
    g.begin("p.milk");
    g.forget("user/a.milk");
    CHECK(g.measured_fps("user/a.milk") < 0);
    CHECK(g.begin("user/a.milk") == 0);  // from the hint again

    // Forgotten while it plays: same level, verdicts still apply, nothing
    // recorded; the next load starts fresh.
    feed(g, 15, 66666, last);
    CHECK(g.level() == 1);
    g.forget("user/a.milk");
    CHECK(g.level() == 1 && g.measured_fps("user/a.milk") < 0);
    last = V::None;
    feed(g, 15, 40000, last);  // 25 fps holds at this level
    CHECK(last == V::Accept && g.level() == 1 && g.last_fps() > 24);
    CHECK(g.measured_fps("user/a.milk") < 0);
    feed(g, 10, 66666, last);  // still steps down for the content it measures
    CHECK(last == V::StepDown && g.level() == 2);
    // A failed switch hands the guard back to it as it was.
    const CostGuard::Run run = g.run();
    CHECK(run.file == "user/a.milk" && run.level == 2 && run.detached);
    g.begin("candidate.milk");
    g.resume(run);
    CHECK(g.level() == 2 && g.current().rung == 2);
    feed(g, 15, 33333, last);
    CHECK(last == V::Accept && g.measured_fps("user/a.milk") < 0);
    g.begin("p.milk");
    CHECK(g.begin("user/a.milk") == 0);
    feed(g, 15, 33333, last);
    CHECK(g.measured_fps("user/a.milk") > 29);  // a fresh load records again
    // resume() respects the thermal floor.
    CostGuard::Run low{"x.milk", 0, false};
    g.set_rung_floor(1);
    g.resume(low);
    CHECK(g.current().rung >= 1);
}

// What projectM renders keeps the high_frequency it was loaded with: a
// reload clearing the tag doesn't let flashing content stay on screen.
static void test_high_frequency_loaded() {
    PresetManager::Config cfg;
    cfg.seed = 4;
    std::vector<PresetEntry> es = entries(4);
    es.push_back(entry("user/flash.milk", true));
    PresetManager pm(es, {}, cfg);
    pm.set_high_frequency(true);
    std::string reason;
    const PresetEntry* flash = pm.find_playable("user/flash.milk", reason);
    pm.on_shown(*flash, false);

    // The tag goes while it shows: turning the filter off still cuts.
    auto r = pm.set_user_presets({entry("user/flash.milk", false)});
    CHECK(!r.cut && !flash->high_frequency);
    CHECK(pm.set_high_frequency(false) && pm.high_frequency_on_screen());
    // The cut may reload it (its file is no longer flagged): that load is
    // the new content, classified as it is now.
    pm.on_shown(*pm.cut_target(), false);
    CHECK(!pm.high_frequency_on_screen());

    // Blending out when the tag goes: still on screen until the blend ends.
    PresetManager b(es, {}, cfg);
    b.set_high_frequency(true);
    std::string why;
    const PresetEntry* f2 = b.find_playable("user/flash.milk", why);
    b.on_shown(*f2, false);
    b.on_shown(*by_file(b, "p0.milk"), true);  // flash -> p0
    b.set_user_presets({entry("user/flash.milk", false)});
    CHECK(b.set_high_frequency(false) && b.high_frequency_on_screen());
    b.on_blend_done();
    CHECK(!b.high_frequency_on_screen());

    // A tag added while it shows counts at once.
    PresetManager a(es, {}, cfg);
    a.set_user_presets({entry("user/flash.milk", false)});
    a.on_shown(*a.find_playable("user/flash.milk", why), false);
    CHECK(!a.high_frequency_on_screen());
    r = a.set_user_presets({entry("user/flash.milk", true)});
    CHECK(r.cut && a.high_frequency_on_screen());
    // ...and clearing it again doesn't undo that.
    r = a.set_user_presets({entry("user/flash.milk", false)});
    CHECK(r.cut && a.high_frequency_on_screen());
}

// Which reloaded ids may have new content (per-content caches go).
static void test_user_changed() {
    auto sha = [](const std::string& file, const std::string& hash) {
        PresetEntry e = entry(file);
        e.sha256 = hash;
        return e;
    };
    PresetManager::Config cfg;
    PresetManager pm(std::vector<PresetEntry>{entry("p.milk"), sha("user/a.milk", "aa"), sha("user/b.milk", "bb"),
                                              entry("user/c.milk")},
                     {}, cfg);
    auto r = pm.set_user_presets({sha("user/a.milk", "aa"), sha("user/b.milk", "b2"), entry("user/c.milk"),
                                  sha("user/new.milk", "nn")});
    // Same hash: unchanged; another hash or none: changed; new ids have
    // nothing cached.
    CHECK((r.changed == std::vector<std::string>{"user/b.milk", "user/c.milk"}));
    r = pm.set_user_presets({});
    CHECK(r.changed.empty() && r.removed == 4);
    r = pm.set_user_presets({sha("user/a.milk", "aa"), sha("user/b.milk", "b3")});
    CHECK((r.changed == std::vector<std::string>{"user/b.milk"}) && r.added == 2);  // revived

    Manifest m;
    std::string err;
    CHECK(parse_manifest(R"({"presets":[{"file":"a.milk","sha256":"ab12"},{"file":"b.milk","sha256":7}]})", m, err));
    CHECK(m.presets.size() == 2 && m.presets[0].sha256 == "ab12" && m.presets[1].sha256.empty());
}

int main() {
    test_json();
    test_options();
    test_connector_choice();
    test_mode_choice();
    test_protocol();
    test_manifest();
    test_rotation();
    test_high_frequency_keeps_bag();
    test_history();
    test_filters_and_lock();
    test_high_frequency_safety();
    test_guard_ladder();
    test_guard_60hz();
    test_guard_min_fps();
    test_pacer();
    test_thermal();
    test_stderr_classifier();
    test_stderr_capture();
    test_pcm_feed_alignment();
    test_tone();
    test_selection();
    test_poll_round();
    test_switch_state();
    test_recovery_round();
    test_drain_lines();
    test_exit_guard();
    test_kmsg_watch();
    test_user_options();
    test_user_protocol();
    test_user_manifest();
    test_selection_file();
    test_selection_rotation();
    test_favourites();
    test_user_reload();
    test_play();
    test_switch_play();
    test_play_before_take();
    test_favourites_tiny_pools();
    test_guard_forget();
    test_high_frequency_loaded();
    test_user_changed();
    if (g_failures == 0) std::printf("OK\n");
    return g_failures == 0 ? 0 : 1;
}
