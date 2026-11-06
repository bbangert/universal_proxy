// Host unit tests for milkdrop_renderer's GL-free core. Prints one line per
// failure and exits non-zero if any check failed.

#include "cost_guard.h"
#include "exit_guard.h"
#include "frame_pacer.h"
#include "json.h"
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
#include "test_tone.h"
#include "thermal.h"

#include <algorithm>
#include <atomic>
#include <csignal>
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
    CHECK(json_parse(event_skip("x.milk", "budget"), v, err) && v.get("preset")->string == "x.milk" &&
          v.get("reason")->string == "budget" && v.get("message") == nullptr);
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
    cfg.min_fps = 19.0;
    cfg.settle_frames = 5;
    cfg.window_frames = 10;
    CostGuard g(cfg);
    CHECK(g.levels().size() == 2 && g.levels()[0].interval == 2 && g.levels()[1].rung == 1);

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
    // Both ready: the flip first, commands after, never a second dispatch.
    handle_poll_round({true, true}, awaited, dispatch, release);
    CHECK((order == std::vector<std::string>{"flip", "commands"}));
    // The flip was consumed elsewhere (stale readiness): no dispatch.
    order.clear();
    awaiting = false;
    handle_poll_round({true, true}, awaited, dispatch, release);
    CHECK((order == std::vector<std::string>{"commands"}));
    order.clear();
    awaiting = true;
    handle_poll_round({false, true}, awaited, dispatch, release);
    CHECK((order == std::vector<std::string>{"commands"}));
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

int main() {
    test_json();
    test_options();
    test_connector_choice();
    test_mode_choice();
    test_protocol();
    test_manifest();
    test_rotation();
    test_history();
    test_filters_and_lock();
    test_high_frequency_safety();
    test_guard_ladder();
    test_guard_60hz();
    test_pacer();
    test_thermal();
    test_stderr_classifier();
    test_stderr_capture();
    test_pcm_feed_alignment();
    test_tone();
    test_selection();
    test_poll_round();
    test_drain_lines();
    test_exit_guard();
    if (g_failures == 0) std::printf("OK\n");
    return g_failures == 0 ? 0 : 1;
}
