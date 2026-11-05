// Host unit tests for sendspin_player's pure helpers. Prints one line per
// failure and exits non-zero if any check failed.

#include "artwork_store.h"
#include "display_roles.h"
#include "json_out.h"
#include "sha256.h"
#include "started_event.h"
#include "viz_gate.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <atomic>
#include <limits>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace sendspin;

static int g_failures = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
            g_failures++;                                                        \
        }                                                                        \
    } while (0)

static std::string sha(const std::string& s) {
    return sha256_hex(reinterpret_cast<const uint8_t*>(s.data()), s.size());
}

// A 4-byte UTF-8 character (U+1F3B5), the costliest valid text per codepoint.
static std::string wide(size_t chars) {
    std::string s;
    for (size_t i = 0; i < chars; i++) s += "\xF0\x9F\x8E\xB5";
    return s;
}

static void test_sha256() {
    CHECK(sha("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    CHECK(sha("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    CHECK(sha(std::string(56, 'a')) ==
          "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
}

static void test_sanitize_text() {
    std::string t = sanitize_text("ab\x01" "c\xff\xc3\xa9\xe2\x82", 100);
    CHECK(t == "ab c\xc3\xa9");
    CHECK(is_valid_utf8(t));
    // Cut at a codepoint boundary, never inside one.
    CHECK(sanitize_text("h\xc3\xa9llo", 2) == "h");
    CHECK(sanitize_text(wide(10), 9) == wide(2));
}

// The largest `started` a binary can emit: every candidate rate × depth
// probed, display roles on, and long hostile text in every echoed field.
static void test_started_budget() {
    ProbedCaps caps;
    caps.rates = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    caps.bit_depths = {16, 24, 32};
    caps.ok = true;

    std::string hostile = wide(64) + std::string(300, '"') + std::string(300, '\\');

    StartedInfo info;
    info.version = "0.1.0";
    info.port = 65535;
    info.name = hostile;
    info.product = hostile;
    info.alsa_device = hostile;
    info.formats = build_audio_formats(caps);
    info.display_roles = true;

    CHECK(info.formats.size() == 49);
    std::string line = started_json(info);
    std::printf("started worst case: %zu bytes\n", line.size());
    CHECK(line.size() <= MAX_EMIT_LINE_BYTES);
    CHECK(MAX_EMIT_LINE_BYTES < 4095);
    CHECK(line.find("\"display_roles\":true}") != std::string::npos);
    CHECK(line.find("\"rate\":384000,\"bit_depth\":32") != std::string::npos);
    CHECK(is_valid_utf8(line));

    // Ordinary values are echoed unchanged.
    info.name = "Living Room \xC3\xA9";
    CHECK(started_json(info).find("\"name\":\"Living Room \xC3\xA9\"") != std::string::npos);
}

// An IEC958 (HDMI) probe hands back exact (rate, depth) pairs; only those
// are advertised, not the rates x depths cross product.
static void test_probe_pairs() {
    ProbedCaps caps;
    caps.rates = {44100, 48000, 192000};
    caps.bit_depths = {16, 24};
    caps.pairs = {{44100, 16}, {48000, 16}, {192000, 16}, {44100, 24}, {48000, 24}};
    caps.ok = true;

    auto formats = build_audio_formats(caps);
    auto has = [&](uint32_t rate, uint8_t depth) {
        for (const auto& f : formats) {
            if (f.sample_rate == rate && f.bit_depth == depth) return true;
        }
        return false;
    };
    CHECK(has(192000, 16));
    CHECK(has(48000, 24));
    CHECK(!has(192000, 24));
    CHECK(formats.size() == 5 + 2 * 3);  // floor + FLAC/PCM for 192@16, 44.1@24, 48@24
}

static void test_metadata_budget() {
    std::string hostile = wide(64) + std::string(300, '"');
    ServerMetadataStateObject m;
    m.title = hostile;
    m.artist = hostile;
    m.album_artist = hostile;
    m.album = hostile;
    m.artwork_url = hostile;
    m.year = 2024;
    m.track = 12;
    m.progress = MetadataProgressObject{4294967295U, 4294967295U, 4294967295U};
    std::string line = metadata_json(m, 123456789);
    std::printf("metadata worst case: %zu bytes\n", line.size());
    CHECK(line.size() <= MAX_EMIT_LINE_BYTES);
    CHECK(line.find("\"progress_age_ms\":123456789}") != std::string::npos);
    CHECK(is_valid_utf8(line));
}

static bool exists(const std::string& p) { return fs::exists(p); }

static ArtworkStore::Image put(ArtworkStore& store, const std::string& bytes) {
    CHECK(store.stage(0, reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), false));
    return store.take(0);
}

static void test_artwork_store() {
    fs::path dir = fs::temp_directory_path() /
                   ("sendspin_artwork_test_" + std::to_string(::getpid()));
    fs::remove_all(dir);
    fs::create_directories(dir);
    ArtworkStore store(dir.string(), 2);

    auto a = put(store, "image-a");
    CHECK(a.valid && a.path == (dir / (sha("image-a") + ".jpg")).string());
    CHECK(a.seq == 1 && a.bytes == 7 && std::string(a.format) == "jpeg");
    auto b = put(store, "image-b");
    auto c = put(store, "image-c");
    // Keeps the last two displayed.
    CHECK(!exists(a.path) && exists(b.path) && exists(c.path));

    // A pending image survives the eviction of an older copy of itself:
    // B is staged again (same hash, same file) while D's display evicts B.
    std::string b2 = "image-b";
    CHECK(store.stage(1, reinterpret_cast<const uint8_t*>(b2.data()), b2.size(), false));
    auto d = put(store, "image-d");
    CHECK(exists(b.path) && exists(c.path) && exists(d.path));
    auto b_again = store.take(1);
    CHECK(b_again.valid && b_again.path == b.path && exists(b.path));
    // B is now the newest; C went.
    CHECK(!exists(c.path) && exists(d.path));

    // An image superseded before its display is deleted, unless shown.
    std::string e = "image-e";
    std::string f = "image-f";
    CHECK(store.stage(0, reinterpret_cast<const uint8_t*>(e.data()), e.size(), true));
    std::string e_path = (dir / (sha(e) + ".png")).string();
    CHECK(exists(e_path));
    CHECK(store.stage(0, reinterpret_cast<const uint8_t*>(f.data()), f.size(), false));
    CHECK(!exists(e_path));
    auto shown_f = store.take(0);
    CHECK(shown_f.valid && exists(shown_f.path));
    CHECK(!exists(d.path) && exists(b.path));  // shown: F, B

    // B is re-staged, then superseded by G before its display: B is still
    // among the shown files, so it stays.
    CHECK(store.stage(0, reinterpret_cast<const uint8_t*>(b2.data()), b2.size(), false));
    std::string g = "image-g";
    CHECK(store.stage(0, reinterpret_cast<const uint8_t*>(g.data()), g.size(), false));
    CHECK(exists(b.path));

    // Nothing pending: an invalid image.
    CHECK(!store.take(3).valid);

    // A failed write is staged invalid.
    ArtworkStore broken((dir / "missing").string(), 2);
    CHECK(!broken.stage(0, reinterpret_cast<const uint8_t*>(g.data()), g.size(), false));
    CHECK(!broken.take(0).valid);

    fs::remove_all(dir);
}

static void test_viz_gate() {
    using Lines = std::vector<std::string>;
    Lines out;
    VizGate gate([&](const std::string& line) { out.push_back(line); });

    // Off until enabled; the ack is written with the switch.
    CHECK(!gate.emit_frame(5'000, "before-enable"));
    gate.set_enabled(true, "ack:true");
    CHECK(gate.emit_frame(5'000, "f1"));

    // Thread 1: a frame that passed the enabled() hint, then paused while
    // the main thread acked the disable, is dropped: nothing follows the ack.
    CHECK(gate.enabled());
    gate.set_enabled(false, "ack:false");
    CHECK(!gate.emit_frame(6'000, "in-flight"));
    CHECK((out == Lines{"ack:true", "f1", "ack:false"}));
    gate.set_enabled(true, "ack:true");

    // Thread 2: the clear is written before the old stream's last frame even
    // reaches the gate (the library delivered it after its final stale check).
    // That frame was due before the boundary, so it is dropped however late
    // it arrives; a frame due after the boundary goes through.
    gate.boundary(10'000, "clear");
    CHECK(!gate.emit_frame(9'500, "stale-old-stream"));
    CHECK(!gate.emit_frame(10'000 + VizGate::BOUNDARY_MARGIN_US, "at-margin"));
    CHECK(gate.emit_frame(10'000 + VizGate::BOUNDARY_MARGIN_US + 1, "new-stream"));
    CHECK((out == Lines{"ack:true", "f1", "ack:false", "ack:true", "clear", "new-stream"}));

    // A silent boundary (stream start) moves the cut too.
    gate.boundary(20'000);
    CHECK(!gate.emit_frame(19'000, "stale"));

    // Concurrent: frames due on the drain thread's clock race clears and
    // disables on another thread. Every frame written after a clear is due
    // after it, and nothing is written between a disable ack and the next
    // enable ack.
    Lines lines;
    std::mutex lines_mtx;
    VizGate racy([&](const std::string& line) {
        std::lock_guard<std::mutex> lock(lines_mtx);
        lines.push_back(line);
    });
    std::atomic<int64_t> clock{0};
    std::atomic<bool> stop{false};
    racy.set_enabled(true, "on");
    std::thread drain([&] {
        while (!stop.load()) {
            int64_t due = clock.fetch_add(1) * 10;
            if (racy.enabled()) racy.emit_frame(due, "frame:" + std::to_string(due));
        }
    });
    for (int i = 0; i < 300; i++) {
        int64_t now = clock.load() * 10;
        if (i % 3 == 2) {
            racy.set_enabled(false, "off");
            racy.set_enabled(true, "on");
        } else {
            racy.boundary(now, "clear:" + std::to_string(now));
        }
    }
    stop.store(true);
    drain.join();
    int64_t cut = std::numeric_limits<int64_t>::min();
    bool on = false;
    for (const auto& line : lines) {
        if (line == "on") {
            on = true;
        } else if (line == "off") {
            on = false;
        } else if (line.rfind("clear:", 0) == 0) {
            cut = std::stoll(line.substr(6));
        } else {
            CHECK(on);
            CHECK(std::stoll(line.substr(6)) > cut + VizGate::BOUNDARY_MARGIN_US);
        }
    }
}

int main() {
    test_probe_pairs();
    test_sha256();
    test_sanitize_text();
    test_started_budget();
    test_metadata_budget();
    test_artwork_store();
    test_viz_gate();
    if (g_failures == 0) std::printf("OK\n");
    return g_failures == 0 ? 0 : 1;
}
