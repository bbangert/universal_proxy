// Host unit tests for sendspin_player's pure helpers. Prints one line per
// failure and exits non-zero if any check failed.

#include "artwork_store.h"
#include "display_roles.h"
#include "json_out.h"
#include "pcm_tap.h"
#include "pcm_tap_writer.h"
#include "sha256.h"
#include "started_event.h"
#include "viz_gate.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <atomic>
#include <chrono>
#include <limits>
#include <random>
#include <string>
#include <thread>
#include <fcntl.h>
#include <sys/mman.h>
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

// ---- PCM tap ----

using pcm_tap::Reader;
using Status = pcm_tap::Reader::Status;

static std::string tap_path(const char* name) {
    return (fs::temp_directory_path() /
            ("sendspin_pcm_tap_" + std::string(name) + "_" + std::to_string(::getpid())))
        .string();
}

// Stereo frames whose samples encode their absolute frame index.
static void fill_indexed(std::vector<int16_t>& buf, uint64_t first, uint32_t frames) {
    buf.resize(size_t{frames} * 2);
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t f = first + i;
        buf[size_t{i} * 2] = static_cast<int16_t>(f & 0x7fff);
        buf[size_t{i} * 2 + 1] = static_cast<int16_t>((f >> 15) & 0x7fff);
    }
}

static bool is_frame(const int16_t* s, uint64_t f) {
    return s[0] == static_cast<int16_t>(f & 0x7fff) &&
           s[1] == static_cast<int16_t>((f >> 15) & 0x7fff);
}

static void test_pcm_tap_layout() {
    CHECK(pcm_tap::samples_offset(1024) == 24640);
    CHECK(pcm_tap::file_bytes(65536, 1024) == 24640 + 65536 * 4);
    std::string path = tap_path("layout");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err);
    CHECK(w != nullptr);
    CHECK(fs::file_size(path) == pcm_tap::file_bytes(65536, 1024));
    CHECK(pcm_tap::Writer::open(path, err, 1000, 16) == nullptr);
    Reader r;
    CHECK(r.open(path.c_str()));
    Reader::Info info;
    CHECK(r.format(info) && info.sample_rate == 0);
    std::vector<int16_t> out(64 * 2);
    CHECK(r.read_latest(64, out.data()) == Status::NoData);
    CHECK(!r.open("/nonexistent/pcm_tap"));
    fs::remove(path);
}

static void test_pcm_tap_convert() {
    int16_t out[8];
    // S16_LE stereo: unchanged.
    const int16_t s16[] = {1, -2, 300, -400};
    CHECK(pcm_tap::to_s16_stereo(reinterpret_cast<const uint8_t*>(s16), 2, 16, 2, out));
    CHECK(out[0] == 1 && out[1] == -2 && out[2] == 300 && out[3] == -400);
    // S24_3LE stereo: the top 16 bits.
    const uint8_t s24[] = {0x56, 0x34, 0x12, 0xff, 0xff, 0xff, 0x00, 0x00, 0x80, 0xff, 0xff, 0x7f};
    CHECK(pcm_tap::to_s16_stereo(s24, 2, 24, 2, out));
    CHECK(out[0] == 0x1234 && out[1] == -1 && out[2] == INT16_MIN && out[3] == INT16_MAX);
    // S32_LE stereo.
    const int32_t s32[] = {0x12345678, -65536, INT32_MIN, INT32_MAX};
    CHECK(pcm_tap::to_s16_stereo(reinterpret_cast<const uint8_t*>(s32), 2, 32, 2, out));
    CHECK(out[0] == 0x1234 && out[1] == -1 && out[2] == INT16_MIN && out[3] == INT16_MAX);
    // Mono is duplicated; a third channel is dropped.
    const int16_t mono[] = {7, -8};
    CHECK(pcm_tap::to_s16_stereo(reinterpret_cast<const uint8_t*>(mono), 2, 16, 1, out));
    CHECK(out[0] == 7 && out[1] == 7 && out[2] == -8 && out[3] == -8);
    const uint8_t s24x3[] = {0, 1, 0, 0, 2, 0, 0, 3, 0};
    CHECK(pcm_tap::to_s16_stereo(s24x3, 1, 24, 3, out));
    CHECK(out[0] == 1 && out[1] == 2);
    CHECK(!pcm_tap::to_s16_stereo(s24, 1, 8, 2, out));
    CHECK(!pcm_tap::to_s16_stereo(s24, 1, 16, 0, out));
}

static void test_pcm_tap_wraparound() {
    std::string path = tap_path("wrap");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err, 256, 8);
    CHECK(w != nullptr);
    Reader r;
    CHECK(r.open(path.c_str()));
    std::vector<int16_t> chunk;
    std::vector<int16_t> out(256 * 2);
    uint64_t f = 0;
    for (int i = 0; i < 40; i++) {
        // 100 frames per chunk, 100 us apart at 1 MHz: frame f plays at f.
        fill_indexed(chunk, f, 100);
        f += 100;
        w->commit(1, 1'000'000, chunk.data(), 100, static_cast<int64_t>(f - 1));
        Reader::Info info;
        if (f >= 200) {
            CHECK(r.read_latest(200, out.data(), &info) == Status::Ok);
            CHECK(info.end_frame == f);
            bool ok = true;
            for (uint32_t k = 0; k < 200; k++) ok = ok && is_frame(&out[k * 2], f - 200 + k);
            CHECK(ok);
        }
    }
    // Past the 256-frame ring (but within the 8 records): overwritten.
    CHECK(r.read_ending_at(static_cast<int64_t>(f - 1 - 300), 100, out.data()) == Status::Retry);
    // Mid-chunk lookup across the slot wrap.
    CHECK(r.read_ending_at(static_cast<int64_t>(f - 1 - 50), 150, out.data()) == Status::Ok);
    CHECK(is_frame(&out[149 * 2], f - 1 - 50) && is_frame(&out[0], f - 50 - 150));
    // A chunk larger than the ring keeps its newest frames.
    fill_indexed(chunk, f, 300);
    w->commit(1, 1'000'000, chunk.data(), 300, static_cast<int64_t>(f + 299));
    CHECK(r.read_latest(256, out.data()) == Status::Ok);
    CHECK(is_frame(&out[0], f + 44) && is_frame(&out[255 * 2], f + 299));
    fs::remove(path);
}

static void test_pcm_tap_time_lookup() {
    std::string path = tap_path("time");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err);
    Reader r;
    CHECK(w != nullptr && r.open(path.c_str()));
    // 480-frame (10 ms) chunks at 48 kHz; chunk k's last frame plays at
    // base + (k + 1) * 10 ms.
    const int64_t base = 5'000'000;
    std::vector<int16_t> chunk;
    for (uint64_t k = 0; k < 10; k++) {
        fill_indexed(chunk, k * 480, 480);
        w->commit(7, 48000, chunk.data(), 480, base + static_cast<int64_t>(k + 1) * 10'000);
    }
    std::vector<int16_t> out(1024 * 2);
    Reader::Info info;
    // 5 ms (240 frames) before chunk 3's end.
    CHECK(r.read_ending_at(base + 40'000 - 5'000, 1024, out.data(), &info) == Status::Ok);
    CHECK(info.sample_rate == 48000 && info.end_frame == 4 * 480 - 240);
    CHECK(is_frame(&out[1023 * 2], 4 * 480 - 241) && is_frame(&out[0], 4 * 480 - 240 - 1024));
    // Exactly a chunk's end.
    CHECK(r.read_ending_at(base + 70'000, 576, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 7 * 480);
    // Later than anything written, or before the first chunk began.
    CHECK(r.read_ending_at(base + 100'001, 576, out.data()) == Status::NoData);
    CHECK(r.read_ending_at(base - 1, 576, out.data()) == Status::NoData);
    // The window reaches back before frame 0: zero-filled.
    CHECK(r.read_ending_at(base + 10'000, 1024, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 480 && out[0] == 0 && out[(1024 - 480) * 2 - 1] == 0);
    CHECK(is_frame(&out[(1024 - 480) * 2], 0) && is_frame(&out[1023 * 2], 479));
    fs::remove(path);
}

static void test_pcm_tap_epochs() {
    std::string path = tap_path("epoch");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err);
    Reader r;
    CHECK(w != nullptr && r.open(path.c_str()));
    std::vector<int16_t> chunk;
    std::vector<int16_t> out(600 * 2);
    Reader::Info info;

    fill_indexed(chunk, 0, 480);
    w->commit(1, 48000, chunk.data(), 480, 10'000);
    CHECK(r.read_latest(480, out.data(), &info) == Status::Ok);
    const uint32_t e1 = info.epoch;

    // Format change: a new epoch at the new rate. The old stream's data
    // is gone, and the new one's window starts at its first frame.
    fill_indexed(chunk, 480, 441);
    w->commit(2, 44100, chunk.data(), 441, 20'000);
    CHECK(r.format(info) && info.epoch == e1 + 1 && info.sample_rate == 44100);
    CHECK(r.read_ending_at(10'000, 100, out.data()) == Status::NoData);
    CHECK(r.read_latest(600, out.data(), &info) == Status::Ok);
    CHECK(info.epoch == e1 + 1 && out[0] == 0 && out[(600 - 441) * 2 - 1] == 0);
    CHECK(is_frame(&out[(600 - 441) * 2], 480) && is_frame(&out[599 * 2], 920));

    // A flush (same rate, new stream) also bumps it, before any data.
    w->begin_stream(3, 44100);
    CHECK(r.format(info) && info.epoch == e1 + 2);
    CHECK(r.read_latest(100, out.data()) == Status::NoData);

    // No stream: no data. Reopening keeps the counters and bumps again.
    w->end_stream();
    CHECK(r.format(info) && info.epoch == e1 + 3 && info.sample_rate == 0);
    w.reset();
    w = pcm_tap::Writer::open(path, err);
    CHECK(w != nullptr && w->epoch() == e1 + 4);
    fill_indexed(chunk, 921, 100);
    w->commit(1, 48000, chunk.data(), 100, 30'000);
    CHECK(r.read_latest(100, out.data(), &info) == Status::Ok);
    CHECK(info.epoch == e1 + 5 && info.end_frame == 1021 && is_frame(&out[0], 921));
    fs::remove(path);
}

// Play times with a gap (an underrun) between chunks, and with jitter.
static void test_pcm_tap_gaps() {
    std::string path = tap_path("gaps");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err, 1024, 64);
    Reader r;
    CHECK(w != nullptr && r.open(path.c_str()));
    std::vector<int16_t> chunk;
    std::vector<int16_t> out(300 * 2);
    Reader::Info info;
    // 1 MHz, 100-frame chunks: A (frames 0..99) ends at 99, B (100..199)
    // at 1099, 900 us of silence after A.
    fill_indexed(chunk, 0, 100);
    w->commit(1, 1'000'000, chunk.data(), 100, 99);
    fill_indexed(chunk, 100, 100);
    w->commit(1, 1'000'000, chunk.data(), 100, 1099);
    // Inside the gap: no PCM plays then.
    CHECK(r.read_ending_at(500, 50, out.data()) == Status::NoData);
    CHECK(r.read_ending_at(999, 50, out.data()) == Status::NoData);
    // Within a chunk of A's end: jitter, so A's end.
    CHECK(r.read_ending_at(150, 50, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 100 && is_frame(&out[0], 50) && is_frame(&out[49 * 2], 99));
    // A window reaching back across the gap: silence before B.
    CHECK(r.read_ending_at(1099, 150, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 200 && out[0] == 0 && out[49 * 2 + 1] == 0);
    CHECK(is_frame(&out[50 * 2], 100) && is_frame(&out[149 * 2], 199));
    // Jitter under a chunk: C (200..299) ends 30 us late, D (300..399)
    // 20 us early. Still contiguous.
    fill_indexed(chunk, 200, 100);
    w->commit(1, 1'000'000, chunk.data(), 100, 1229);
    fill_indexed(chunk, 300, 100);
    w->commit(1, 1'000'000, chunk.data(), 100, 1309);
    CHECK(r.read_ending_at(1115, 10, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 200 && is_frame(&out[9 * 2], 199));
    CHECK(r.read_ending_at(1309, 300, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 400 && is_frame(&out[0], 100) && is_frame(&out[299 * 2], 399));
    fs::remove(path);
}

// Chunk records wrap before the samples do: a window older than the
// records kept has no known history.
static void test_pcm_tap_record_history() {
    std::string path = tap_path("history");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err, 256, 8);
    Reader r;
    CHECK(w != nullptr && r.open(path.c_str()));
    std::vector<int16_t> chunk;
    for (uint64_t f = 0; f < 100; f++) {
        fill_indexed(chunk, f, 1);
        w->commit(1, 1'000'000, chunk.data(), 1, static_cast<int64_t>(f));
    }
    std::vector<int16_t> out(64 * 2);
    Reader::Info info;
    CHECK(r.read_latest(64, out.data()) == Status::NoData);
    CHECK(r.read_latest(8, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 100 && is_frame(&out[0], 92) && is_frame(&out[7 * 2], 99));
    CHECK(r.read_ending_at(97, 6, out.data()) == Status::Ok && is_frame(&out[0], 92));
    CHECK(r.read_ending_at(97, 7, out.data()) == Status::NoData);
    fs::remove(path);
}

// A writer killed mid-commit leaves samples overwritten past the written
// counters. The next writer must not lower the reserved counters that
// make readers discard them.
static void test_pcm_tap_reopen_after_kill() {
    std::string path = tap_path("kill");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err, 256, 8);
    Reader r;
    CHECK(w != nullptr && r.open(path.c_str()));
    std::vector<int16_t> chunk;
    for (uint64_t f = 0; f < 256; f += 64) {
        fill_indexed(chunk, f, 64);
        w->commit(1, 1'000'000, chunk.data(), 64, static_cast<int64_t>(f + 63));
    }

    // The killed writer: reserved frames 256..319 and record 4, overwrote
    // the slots of frames 0..63, published nothing.
    const size_t bytes = pcm_tap::file_bytes(256, 8);
    int fd = ::open(path.c_str(), O_RDWR);
    void* base = ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    ::close(fd);
    CHECK(base != MAP_FAILED);
    auto& h = *static_cast<pcm_tap::Header*>(base);
    pcm_tap::atomic(h.frames_reserved).store(320);
    pcm_tap::atomic(h.chunks_reserved).store(5);
    auto* samples = reinterpret_cast<int16_t*>(static_cast<uint8_t*>(base) +
                                               pcm_tap::samples_offset(8));
    for (size_t i = 0; i < 64 * 2; i++) samples[i] = 0x5555;
    w.reset();

    std::vector<int16_t> out(64 * 2);
    Reader::Info info;
    CHECK(r.read_ending_at(63, 64, out.data()) == Status::Retry);
    CHECK(r.read_ending_at(255, 64, out.data()) == Status::Ok && is_frame(&out[0], 192));

    w = pcm_tap::Writer::open(path, err, 256, 8);
    CHECK(w != nullptr);
    CHECK(pcm_tap::atomic(h.frames_reserved).load() >= 320);
    CHECK(pcm_tap::atomic(h.chunks_reserved).load() >= 5);
    fill_indexed(chunk, 320, 64);
    w->commit(2, 1'000'000, chunk.data(), 64, 10'063);
    CHECK(r.read_latest(64, out.data(), &info) == Status::Ok);
    CHECK(info.end_frame == 384 && is_frame(&out[0], 320) && is_frame(&out[63 * 2], 383));
    ::munmap(base, bytes);
    fs::remove(path);
}

// A writer laps a small ring as fast as it can while a reader checks that
// every read it accepts is exactly the frames it asked for.
static void test_pcm_tap_no_torn_reads() {
    std::string path = tap_path("torn");
    std::string err;
    auto w = pcm_tap::Writer::open(path, err, 256, 16);
    Reader r;
    CHECK(w != nullptr && r.open(path.c_str()));

    std::atomic<bool> stop{false};
    std::thread writer([&] {
        std::vector<int16_t> chunk;
        std::mt19937 rng(1);
        uint64_t f = 0;
        for (uint64_t i = 0; !stop.load(std::memory_order_relaxed); i++) {
            uint32_t n = 1 + rng() % 97;
            fill_indexed(chunk, f, n);
            f += n;
            // 1 MHz: frame f plays at time f.
            w->commit(1, 1'000'000, chunk.data(), n, static_cast<int64_t>(f - 1));
            if (i % 64 == 0) std::this_thread::sleep_for(std::chrono::microseconds(20));
        }
    });

    std::vector<int16_t> out(64 * 2);
    std::mt19937 rng(2);
    uint64_t ok = 0, retry = 0, none = 0, bad = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
    while (std::chrono::steady_clock::now() < deadline || ok < 1000) {
        Reader::Info info;
        if (r.read_latest(1, out.data(), &info) != Status::Ok || info.end_frame < 256) continue;
        int64_t t = static_cast<int64_t>(info.end_frame - 1) - static_cast<int64_t>(rng() % 160);
        switch (r.read_ending_at(t, 64, out.data(), &info)) {
            case Status::Ok: {
                ok++;
                bool good = info.end_frame == static_cast<uint64_t>(t) + 1;
                for (uint32_t k = 0; k < 64; k++)
                    good = good && is_frame(&out[k * 2], static_cast<uint64_t>(t) - 63 + k);
                if (!good) bad++;
                break;
            }
            case Status::Retry: retry++; break;
            case Status::NoData: none++; break;
        }
        if (std::chrono::steady_clock::now() > deadline + std::chrono::seconds(10)) break;
    }
    stop.store(true);
    writer.join();
    std::printf("pcm_tap race: %llu ok, %llu retry, %llu no data\n",
                static_cast<unsigned long long>(ok), static_cast<unsigned long long>(retry),
                static_cast<unsigned long long>(none));
    CHECK(ok >= 1000);
    CHECK(bad == 0);
    fs::remove(path);
}

int main() {
    test_probe_pairs();
    test_sha256();
    test_sanitize_text();
    test_started_budget();
    test_metadata_budget();
    test_artwork_store();
    test_viz_gate();
    test_pcm_tap_layout();
    test_pcm_tap_convert();
    test_pcm_tap_wraparound();
    test_pcm_tap_time_lookup();
    test_pcm_tap_epochs();
    test_pcm_tap_gaps();
    test_pcm_tap_record_history();
    test_pcm_tap_reopen_after_kill();
    test_pcm_tap_no_torn_reads();
    if (g_failures == 0) std::printf("OK\n");
    return g_failures == 0 ? 0 : 1;
}
