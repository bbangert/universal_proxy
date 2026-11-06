// Host unit tests for milkdrop_renderer's GL-free core. Prints one line per
// failure and exits non-zero if any check failed.

#include "cost_guard.h"
#include "frame_pacer.h"
#include "json.h"
#include "manifest.h"
#include "options.h"
#include "pcm_feed.h"
#include "preset_manager.h"
#include "protocol.h"
#include "ring_writer.h"  // sendspin_player's writer: the real producer
#include "stderr_capture.h"
#include "test_tone.h"
#include "thermal.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <map>
#include <set>
#include <string>
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
    CHECK(parse_mode("1280x720") && parse_mode("1280x720")->refresh == 60.0);
    CHECK(!parse_mode("1280x720@") && !parse_mode("x720") && !parse_mode("1280x0"));
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
          o3.card == "/dev/dri/renderD128");
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
    CHECK(json_parse(event_prepared("1280x720@60", "VC4 V3D 2.1", "OpenGL ES 2.0", true, 7, true, "1280x720@60"),
                     v, err) &&
          v.get("crtc_mode_valid")->boolean && v.get("crtc_mode")->string == "1280x720@60" &&
          v.get("presets")->number == 7);
    CHECK(json_parse(event_prepared("1280x720@60", "r", "v", true, 7, false, ""), v, err) &&
          !v.get("crtc_mode_valid")->boolean && v.get("crtc_mode") == nullptr);
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
    CHECK(event_prepared(hostile, hostile, hostile, true, 3, true, hostile).size() < MAX_EMIT_LINE_BYTES);
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
    PresetManager lk2(es, {}, cfg);
    CHECK(lk2.start("p1.milk")->file != "p1.milk" && !lk2.locked());
    PresetManager lk3(es, {}, cfg);
    CHECK(lk3.start("nope.milk") != nullptr && !lk3.locked());

    // Turning high_frequency on admits p1; off again ejects it if current.
    PresetManager hf(es, {}, cfg);
    hf.start("");
    CHECK(!hf.set_high_frequency(true));
    CHECK(hf.eligible_count() == 5);
    const PresetEntry* p = nullptr;
    for (int i = 0; i < 20 && (p == nullptr || p->file != "p1.milk"); i++) p = hf.rotate();
    CHECK(p != nullptr && p->file == "p1.milk");
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
}

int main() {
    test_json();
    test_options();
    test_protocol();
    test_manifest();
    test_rotation();
    test_history();
    test_filters_and_lock();
    test_guard_ladder();
    test_guard_60hz();
    test_pacer();
    test_thermal();
    test_stderr_classifier();
    test_stderr_capture();
    test_pcm_feed_alignment();
    test_tone();
    if (g_failures == 0) std::printf("OK\n");
    return g_failures == 0 ? 0 : 1;
}
