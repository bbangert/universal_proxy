// sendspin_player — universal_proxy
//
// Per-ALSA-output Sendspin player binary. One process per output, supervised
// from the BEAM via MuonTrap.Daemon. Audio (PCM/FLAC/Opus) is decoded in this
// process and pushed to libasound directly — no audio data crosses the BEAM
// boundary. The BEAM ↔ binary interface is line-delimited JSON on stdout
// (status events) and stdin (control commands).
//
// Adapted from LeoLTM/sendspin-armv6/src/main.cpp (Apache-2.0). Key changes
// from upstream:
//   • CLI args via getopt_long instead of INI config file
//   • JSON status events on stdout instead of stderr free-form logs
//   • JSON commands on stdin for runtime volume/mute/shutdown
//   • Honors SENDSPIN_WS_PORT (via our sendspin-cpp patch) to bind a
//     non-default WebSocket port so multiple players can coexist
//
// Licensed under the Apache License, Version 2.0.

#include "sendspin/client.h"
#include "sendspin/player_role.h"

#include "alsa_pipe_sink.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <getopt.h>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <unistd.h>

using namespace sendspin;

static constexpr const char* VERSION = "0.1.0";
static constexpr int DEFAULT_WS_PORT = 8928;

static std::atomic<bool> g_running{true};
static std::mutex g_stdout_mtx;

static void signal_handler(int /*sig*/) { g_running.store(false); }

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

// Validates that `s` is well-formed UTF-8 per RFC 3629 / Unicode 16.0:
// 1-byte (ASCII), 2-byte (C2–DF + cont), 3-byte (E0–EF + 2 cont),
// 4-byte (F0–F4 + 3 cont). Rejects overlong forms, surrogate pairs,
// and bytes >= 0xF5. Used at argv ingress so json_escape never emits a
// malformed line that the BEAM-side Jason decoder would raise on.
static bool is_valid_utf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        size_t needed = 0;
        if (c < 0x80) {
            i++;
            continue;
        }
        if ((c & 0xE0) == 0xC0) {
            if (c < 0xC2) return false;  // overlong 2-byte
            needed = 1;
        } else if ((c & 0xF0) == 0xE0) {
            needed = 2;
        } else if ((c & 0xF8) == 0xF0) {
            if (c > 0xF4) return false;  // beyond U+10FFFF
            needed = 3;
        } else {
            return false;
        }
        if (i + needed >= s.size()) return false;
        for (size_t j = 1; j <= needed; j++) {
            if ((static_cast<unsigned char>(s[i + j]) & 0xC0) != 0x80) return false;
        }
        // Reject surrogate halves (U+D800..U+DFFF) and overlong 3-byte forms.
        if (needed == 2) {
            unsigned char c1 = static_cast<unsigned char>(s[i + 1]);
            if (c == 0xE0 && c1 < 0xA0) return false;  // overlong
            if (c == 0xED && c1 >= 0xA0) return false;  // surrogate
        }
        if (needed == 3) {
            unsigned char c1 = static_cast<unsigned char>(s[i + 1]);
            if (c == 0xF0 && c1 < 0x90) return false;  // overlong
            if (c == 0xF4 && c1 >= 0x90) return false;  // beyond U+10FFFF
        }
        i += needed + 1;
    }
    return true;
}

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                                  static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

static void emit_json(const std::string& line) {
    std::lock_guard<std::mutex> lock(g_stdout_mtx);
    std::cout << line << '\n';
    std::cout.flush();
}

static const char* codec_name(SendspinCodecFormat c) {
    switch (c) {
        case SendspinCodecFormat::FLAC: return "flac";
        case SendspinCodecFormat::OPUS: return "opus";
        case SendspinCodecFormat::PCM:  return "pcm";
        case SendspinCodecFormat::UNSUPPORTED: return "unsupported";
    }
    return "unknown";
}

// ---------------------------------------------------------------------------
// Integer parsing (overflow-checked, replaces std::atoi)
// ---------------------------------------------------------------------------

static bool parse_int(std::string_view sv, int& out) {
    int parsed = 0;
    auto [ptr, ec] = std::from_chars(sv.data(), sv.data() + sv.size(), parsed);
    if (ec != std::errc{}) return false;
    if (ptr != sv.data() + sv.size()) return false;  // trailing garbage
    out = parsed;
    return true;
}

// ---------------------------------------------------------------------------
// CLI options
// ---------------------------------------------------------------------------

struct Options {
    std::string server;
    std::string alsa_device;
    std::string name;
    std::string client_id;
    int mdns_port = DEFAULT_WS_PORT;
    int initial_volume = 50;
    std::string log_level = "info";
};

static void print_usage(const char* prog) {
    std::fprintf(stderr,
        "Usage: %s [options]\n\n"
        "Required:\n"
        "  --name STR            Friendly display name.\n"
        "  --client-id STR       Stable unique client identifier (e.g. UUID).\n\n"
        "Optional:\n"
        "  --server URL          Sendspin server WebSocket URL\n"
        "                        (e.g. ws://music.local:8927/sendspin).\n"
        "                        If empty, only inbound server connections are accepted.\n"
        "  --alsa-device STR     ALSA device name (e.g. plughw:0,0). Empty = default.\n"
        "  --mdns-port INT       Local WebSocket listener port (default: %d).\n"
        "  --initial-volume N    Startup volume 0-100 (default: 50).\n"
        "  --log-level STR       none|error|warn|info|debug|verbose (default: info).\n"
        "  -h, --help            Show this help.\n"
        "  -V, --version         Show version.\n",
        prog, DEFAULT_WS_PORT);
}

static bool require_utf8(const char* flag, const std::string& value) {
    if (is_valid_utf8(value)) return true;
    std::fprintf(stderr, "Error: %s contains invalid UTF-8\n", flag);
    return false;
}

static bool parse_args(int argc, char** argv, Options& opts) {
    static struct option long_options[] = {
        {"server",         required_argument, nullptr, 's'},
        {"alsa-device",    required_argument, nullptr, 'd'},
        {"name",           required_argument, nullptr, 'n'},
        {"client-id",      required_argument, nullptr, 'i'},
        {"mdns-port",      required_argument, nullptr, 'p'},
        {"initial-volume", required_argument, nullptr, 'v'},
        {"log-level",      required_argument, nullptr, 'l'},
        {"help",           no_argument,       nullptr, 'h'},
        {"version",        no_argument,       nullptr, 'V'},
        {nullptr, 0, nullptr, 0}
    };
    int opt = 0;
    int idx = 0;
    while ((opt = getopt_long(argc, argv, "hV", long_options, &idx)) != -1) {
        switch (opt) {
            case 's': opts.server = optarg; break;
            case 'd': opts.alsa_device = optarg; break;
            case 'n': opts.name = optarg; break;
            case 'i': opts.client_id = optarg; break;
            case 'p':
                if (!parse_int(optarg, opts.mdns_port)) {
                    std::fprintf(stderr, "Error: --mdns-port must be an integer\n");
                    return false;
                }
                break;
            case 'v':
                if (!parse_int(optarg, opts.initial_volume)) {
                    std::fprintf(stderr, "Error: --initial-volume must be an integer\n");
                    return false;
                }
                break;
            case 'l': opts.log_level = optarg; break;
            case 'h': print_usage(argv[0]); std::exit(0);
            case 'V': std::fprintf(stdout, "sendspin_player %s\n", VERSION); std::exit(0);
            default: print_usage(argv[0]); return false;
        }
    }
    if (opts.name.empty()) {
        std::fprintf(stderr, "Error: --name is required\n");
        return false;
    }
    if (opts.client_id.empty()) {
        std::fprintf(stderr, "Error: --client-id is required\n");
        return false;
    }
    if (opts.mdns_port <= 0 || opts.mdns_port > 65535) {
        std::fprintf(stderr, "Error: --mdns-port out of range\n");
        return false;
    }
    if (opts.initial_volume < 0 || opts.initial_volume > 100) {
        std::fprintf(stderr, "Error: --initial-volume must be 0-100\n");
        return false;
    }
    // UTF-8 gate before any field flows into a stdout JSON event.
    if (!require_utf8("--name", opts.name)) return false;
    if (!require_utf8("--client-id", opts.client_id)) return false;
    if (!require_utf8("--alsa-device", opts.alsa_device)) return false;
    if (!require_utf8("--server", opts.server)) return false;
    return true;
}

static bool parse_log_level(const std::string& s, LogLevel& level) {
    if (s == "none")    { level = LogLevel::NONE;    return true; }
    if (s == "error")   { level = LogLevel::ERROR;   return true; }
    if (s == "warn")    { level = LogLevel::WARN;    return true; }
    if (s == "info")    { level = LogLevel::INFO;    return true; }
    if (s == "debug")   { level = LogLevel::DEBUG;   return true; }
    if (s == "verbose") { level = LogLevel::VERBOSE; return true; }
    return false;
}

// ---------------------------------------------------------------------------
// Stdin command parser
// ---------------------------------------------------------------------------
//
// Strict shape parser for line-delimited JSON commands. Accepts:
//   {"cmd":"shutdown"}
//   {"cmd":"set_volume","value":75}
//   {"cmd":"set_muted","value":true}
//
// Whitespace is allowed between tokens but the structure is fixed. Hand-
// rolled instead of pulling in nlohmann/json because (a) the wire format
// is closed and minimal, (b) we avoid one ~25kB header-only dep on Nerves
// cross-builds, and (c) the loose substring scan that preceded this version
// would have matched `"cmd"` inside nested string values.

namespace {

class Scanner {
public:
    explicit Scanner(std::string_view s) : src_(s), pos_(0) {}

    void skip_ws() {
        while (pos_ < src_.size() &&
               std::isspace(static_cast<unsigned char>(src_[pos_]))) {
            ++pos_;
        }
    }

    bool expect(char c) {
        skip_ws();
        if (pos_ >= src_.size() || src_[pos_] != c) return false;
        ++pos_;
        return true;
    }

    // Consumes "ident" (a bare double-quoted ASCII identifier — no escapes).
    bool string_literal(std::string& out) {
        skip_ws();
        if (pos_ >= src_.size() || src_[pos_] != '"') return false;
        ++pos_;
        size_t start = pos_;
        while (pos_ < src_.size() && src_[pos_] != '"') {
            if (src_[pos_] == '\\') return false;  // we don't accept escapes
            ++pos_;
        }
        if (pos_ >= src_.size()) return false;
        out.assign(src_.data() + start, pos_ - start);
        ++pos_;
        return true;
    }

    // Returns one of: "bool", "int", or "" on failure. Caller inspects the
    // appropriate out param.
    std::string_view value(int& int_out, bool& bool_out) {
        skip_ws();
        if (pos_ >= src_.size()) return "";
        char c = src_[pos_];
        if (c == 't' && src_.compare(pos_, 4, "true") == 0) {
            pos_ += 4;
            bool_out = true;
            return "bool";
        }
        if (c == 'f' && src_.compare(pos_, 5, "false") == 0) {
            pos_ += 5;
            bool_out = false;
            return "bool";
        }
        if (c == '-' || (c >= '0' && c <= '9')) {
            size_t start = pos_;
            if (c == '-') ++pos_;
            while (pos_ < src_.size() &&
                   std::isdigit(static_cast<unsigned char>(src_[pos_]))) {
                ++pos_;
            }
            if (parse_int(src_.substr(start, pos_ - start), int_out)) {
                return "int";
            }
            return "";
        }
        return "";
    }

    bool at_end() {
        skip_ws();
        return pos_ == src_.size();
    }

private:
    std::string_view src_;
    size_t pos_;
};

}  // namespace

static bool parse_command(const std::string& line, std::string& cmd,
                          int& int_val, bool& bool_val) {
    Scanner sc(line);
    std::string key;
    int_val = 0;
    bool_val = false;
    if (!sc.expect('{')) return false;
    if (!sc.string_literal(key) || key != "cmd") return false;
    if (!sc.expect(':')) return false;
    if (!sc.string_literal(cmd)) return false;
    sc.skip_ws();
    if (sc.expect(',')) {
        if (!sc.string_literal(key) || key != "value") return false;
        if (!sc.expect(':')) return false;
        auto kind = sc.value(int_val, bool_val);
        if (kind.empty()) return false;
    }
    if (!sc.expect('}')) return false;
    if (!sc.at_end()) return false;
    return true;
}

static void stdin_thread(AlsaPipeSink* sink, PlayerRole* player) {
    std::string line;
    while (g_running.load() && std::getline(std::cin, line)) {
        std::string cmd;
        int int_val = 0;
        bool bool_val = false;
        if (!parse_command(line, cmd, int_val, bool_val)) continue;
        if (cmd == "set_volume") {
            auto v = static_cast<uint8_t>(std::clamp(int_val, 0, 100));
            sink->set_volume(v);
            player->update_volume(v);
            std::ostringstream os;
            os << "{\"event\":\"volume\",\"value\":" << static_cast<int>(v) << "}";
            emit_json(os.str());
        } else if (cmd == "set_muted") {
            sink->set_muted(bool_val);
            std::ostringstream os;
            os << "{\"event\":\"mute\",\"value\":" << (bool_val ? "true" : "false") << "}";
            emit_json(os.str());
        } else if (cmd == "shutdown") {
            g_running.store(false);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Listeners
// ---------------------------------------------------------------------------

namespace {

struct PlayerListener : PlayerRoleListener {
    AlsaPipeSink& sink;
    PlayerRole& player;
    PlayerListener(AlsaPipeSink& s, PlayerRole& p) : sink(s), player(p) {}

    size_t on_audio_write(uint8_t* data, size_t len, uint32_t timeout_ms) override {
        return sink.write(data, len, timeout_ms);
    }

    void on_stream_start() override {
        auto& params = player.get_current_stream_params();
        if (!params.sample_rate.has_value() || !params.channels.has_value() ||
            !params.bit_depth.has_value()) {
            return;
        }
        bool ok = sink.configure(*params.sample_rate, *params.channels,
                                 *params.bit_depth);
        const char* codec = params.codec.has_value()
            ? codec_name(*params.codec)
            : "unknown";
        std::ostringstream os;
        os << "{\"event\":\"stream_start\","
           << "\"sample_rate\":" << *params.sample_rate << ","
           << "\"channels\":" << static_cast<int>(*params.channels) << ","
           << "\"bit_depth\":" << static_cast<int>(*params.bit_depth) << ","
           << "\"codec\":\"" << codec << "\"}";
        emit_json(os.str());
        if (!ok) {
            emit_json("{\"event\":\"error\",\"kind\":\"alsa_configure\","
                      "\"msg\":\"AlsaPipeSink::configure failed\"}");
        }
    }

    void on_stream_end() override {
        sink.clear();
        emit_json("{\"event\":\"stream_end\"}");
    }

    void on_volume_changed(uint8_t vol) override {
        sink.set_volume(vol);
        std::ostringstream os;
        os << "{\"event\":\"volume\",\"value\":" << static_cast<int>(vol) << "}";
        emit_json(os.str());
    }

    void on_mute_changed(bool muted) override {
        sink.set_muted(muted);
        std::ostringstream os;
        os << "{\"event\":\"mute\",\"value\":" << (muted ? "true" : "false") << "}";
        emit_json(os.str());
    }
};

struct ClientListener : SendspinClientListener {
    void on_time_sync_updated(float error) override {
        if (SendspinClient::get_log_level() >= LogLevel::DEBUG) {
            std::ostringstream os;
            os << "{\"event\":\"time_sync\",\"error_us\":" << error << "}";
            emit_json(os.str());
        }
    }
};

struct NetworkProvider : SendspinNetworkProvider {
    bool is_network_ready() override { return true; }
};

}  // namespace

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char* argv[]) {
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    Options opts;
    if (!parse_args(argc, argv, opts)) return 1;

    // Fail closed on unknown log levels — a typo silently downgrading to
    // INFO is a quiet operational footgun (e.g. you asked for `verbose`
    // and got `info`, never knowing). Validate before any further setup.
    LogLevel log_level = LogLevel::INFO;
    if (!parse_log_level(opts.log_level, log_level)) {
        std::fprintf(stderr, "Error: unknown --log-level '%s' "
                             "(expected: none|error|warn|info|debug|verbose)\n",
                     opts.log_level.c_str());
        return 1;
    }

    // Invariant: SENDSPIN_WS_PORT must be set BEFORE SendspinClient is
    // constructed and BEFORE any thread is spawned, because (a) the patched
    // sendspin-cpp reads it inside start_server(), and (b) POSIX setenv/
    // getenv are not MT-safe — a future refactor that moves thread spawn
    // earlier would race.
    {
        char buf[16];
        std::snprintf(buf, sizeof(buf), "%d", opts.mdns_port);
        ::setenv("SENDSPIN_WS_PORT", buf, 1);
    }

    SendspinClient::set_log_level(log_level);

    SendspinClientConfig client_config;
    client_config.client_id = opts.client_id;
    client_config.name = opts.name;
    client_config.product_name = "sendspin_player";
    client_config.manufacturer = "universal_proxy";
    client_config.software_version = VERSION;
    SendspinClient client(std::move(client_config));

    PlayerRoleConfig player_config;
    player_config.audio_formats = {
        {SendspinCodecFormat::FLAC, 2, 44100, 16},
        {SendspinCodecFormat::FLAC, 2, 48000, 16},
        {SendspinCodecFormat::OPUS, 2, 48000, 16},
        {SendspinCodecFormat::PCM,  2, 44100, 16},
        {SendspinCodecFormat::PCM,  2, 48000, 16},
    };
    player_config.audio_buffer_capacity = 2'000'000;
    player_config.fixed_delay_us = AlsaPipeSink::PIPELINE_DELAY_US;
    auto& player = client.add_player(std::move(player_config));

    AlsaPipeSink audio_sink;
    if (!opts.alsa_device.empty()) {
        audio_sink.set_device(opts.alsa_device);
    }

    PlayerListener player_listener(audio_sink, player);
    audio_sink.on_frames_played = [&player](uint32_t frames, int64_t ts) {
        player.notify_audio_played(frames, ts);
    };

    ClientListener client_listener;
    NetworkProvider network_provider;
    player.set_listener(&player_listener);
    client.set_listener(&client_listener);
    client.set_network_provider(&network_provider);

    {
        std::ostringstream os;
        os << "{\"event\":\"started\","
           << "\"version\":\"" << VERSION << "\","
           << "\"port\":" << opts.mdns_port << ","
           << "\"name\":\"" << json_escape(opts.name) << "\","
           << "\"alsa_device\":\"" << json_escape(opts.alsa_device) << "\"}";
        emit_json(os.str());
    }

    if (!client.start_server()) {
        emit_json("{\"event\":\"error\",\"kind\":\"start_server\","
                  "\"msg\":\"failed to bind WebSocket listener\"}");
        return 1;
    }

    {
        auto v = static_cast<uint8_t>(opts.initial_volume);
        audio_sink.set_volume(v);
        player.update_volume(v);
        std::ostringstream os;
        os << "{\"event\":\"volume\",\"value\":" << opts.initial_volume << "}";
        emit_json(os.str());
    }

    std::thread stdin_reader(stdin_thread, &audio_sink, &player);

    using clock = std::chrono::steady_clock;
    static constexpr auto RECONNECT_INTERVAL = std::chrono::seconds(5);
    auto last_connect_attempt = clock::now() - RECONNECT_INTERVAL;
    bool was_connected = false;

    while (g_running.load()) {
        client.loop();

        bool now_connected = client.is_connected();
        if (now_connected != was_connected) {
            if (now_connected) {
                std::ostringstream os;
                os << "{\"event\":\"connected\",\"server\":\""
                   << json_escape(opts.server) << "\"}";
                emit_json(os.str());
            } else {
                emit_json("{\"event\":\"disconnected\"}");
            }
            was_connected = now_connected;
        }

        if (!now_connected && !opts.server.empty()) {
            auto now = clock::now();
            if (now - last_connect_attempt >= RECONNECT_INTERVAL) {
                client.connect_to(opts.server);
                last_connect_attempt = now;
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    client.disconnect(SendspinGoodbyeReason::SHUTDOWN);
    emit_json("{\"event\":\"shutdown\"}");

    // Unblock the stdin reader by closing fd 0 — std::getline's underlying
    // read() returns 0 (EOF) and the thread exits cleanly. Then join so no
    // thread outlives main(). On Linux this is the canonical "wake a thread
    // blocked in a blocking read" pattern.
    ::close(STDIN_FILENO);
    if (stdin_reader.joinable()) stdin_reader.join();
    return 0;
}
