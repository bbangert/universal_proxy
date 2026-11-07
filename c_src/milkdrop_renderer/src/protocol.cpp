#include "protocol.h"

#include "json.h"

#include <cmath>
#include <cstdio>

namespace md {

namespace {

std::string str_field(std::string_view key, std::string_view value, size_t max = 256) {
    return ",\"" + std::string(key) + "\":\"" + json_escape(sanitize_text(value, max)) + "\"";
}

std::string num_field(std::string_view key, double v, int decimals = 1) {
    char buf[64];
    if (!std::isfinite(v)) v = 0;
    std::snprintf(buf, sizeof(buf), ",\"%.*s\":%.*f", static_cast<int>(key.size()), key.data(),
                  decimals, v);
    return buf;
}

std::string int_field(std::string_view key, long long v) {
    return ",\"" + std::string(key) + "\":" + std::to_string(v);
}

std::string bool_field(std::string_view key, bool v) {
    return ",\"" + std::string(key) + "\":" + (v ? "true" : "false");
}

std::string open(std::string_view name) {
    return "{\"event\":\"" + std::string(name) + "\"";
}

}  // namespace

std::optional<Command> parse_command(std::string_view line, std::string& error) {
    JsonValue v;
    if (!json_parse(line, v, error)) return std::nullopt;
    const JsonValue* cmd = v.get("cmd");
    if (cmd == nullptr || !cmd->is_string()) {
        error = "missing cmd";
        return std::nullopt;
    }
    Command c;
    const std::string& name = cmd->string;
    if (name == "take") c.type = Command::Type::Take;
    else if (name == "release") c.type = Command::Type::Release;
    else if (name == "exit") c.type = Command::Type::Exit;
    else if (name == "next") c.type = Command::Type::Next;
    else if (name == "prev") c.type = Command::Type::Prev;
    else if (name == "lock") c.type = Command::Type::Lock;
    else if (name == "unlock") c.type = Command::Type::Unlock;
    else if (name == "set_rotate") {
        const JsonValue* val = v.get("value");
        if (val == nullptr || !val->is_number() || val->number != std::floor(val->number) ||
            val->number < 1 || val->number > 3600) {
            error = "bad set_rotate value";
            return std::nullopt;
        }
        c.type = Command::Type::SetRotate;
        c.int_value = static_cast<int>(val->number);
    } else if (name == "set_high_frequency") {
        const JsonValue* val = v.get("value");
        if (val == nullptr || !val->is_bool()) {
            error = "bad set_high_frequency value";
            return std::nullopt;
        }
        c.type = Command::Type::SetHighFrequency;
        c.bool_value = val->boolean;
    } else if (name == "set_min_fps") {
        const JsonValue* val = v.get("value");
        if (val == nullptr || !val->is_number() || !std::isfinite(val->number) || val->number < 1 ||
            val->number > 240) {
            error = "bad set_min_fps value";
            return std::nullopt;
        }
        c.type = Command::Type::SetMinFps;
        c.number_value = val->number;
    } else {
        error = "unknown cmd";
        return std::nullopt;
    }
    return c;
}

std::string event_simple(std::string_view name) { return open(name) + "}"; }

std::string event_prepared(const PreparedInfo& info) {
    std::string out = open("prepared") + str_field("mode", info.mode, 32);
    if (!info.connector.empty()) out += str_field("connector", info.connector, 32);
    if (!info.mode_source.empty()) out += str_field("mode_source", info.mode_source, 16);
    out += str_field("gl_renderer", info.gl_renderer, 128) + str_field("gl_version", info.gl_version, 128) +
           bool_field("gles2", info.gles2) + int_field("presets", info.presets) +
           bool_field("crtc_mode_valid", info.crtc_mode_valid);
    if (info.crtc_mode_valid) out += str_field("crtc_mode", info.crtc_mode, 32);
    return out + "}";
}

std::string event_presenting(bool modeset, double master_ms, bool crtc_lit) {
    return open("presenting") + bool_field("modeset", modeset) + num_field("master_ms", master_ms) +
           bool_field("crtc_lit", crtc_lit) + "}";
}

std::string event_preset(std::string_view file, bool locked, std::string_view rung,
                         std::string_view cause, bool cut) {
    return open("preset") + str_field("file", file, MAX_PRESET_NAME_BYTES) + bool_field("locked", locked) +
           str_field("rung", rung, 32) + str_field("cause", cause, 32) + bool_field("cut", cut) + "}";
}

std::string event_loading(std::string_view file) {
    return open("loading") + str_field("preset", file, MAX_PRESET_NAME_BYTES) + "}";
}

std::string event_skip(std::string_view file, std::string_view reason, std::string_view message, double fps) {
    std::string out = open("skip") + str_field("preset", file, MAX_PRESET_NAME_BYTES) + str_field("reason", reason, 64);
    if (!message.empty()) out += str_field("message", message, 256);
    if (fps >= 0) out += num_field("fps", fps);
    return out + "}";
}

std::string event_error(std::string_view reason, std::string_view message) {
    std::string out = open("error") + str_field("reason", reason, 64);
    if (!message.empty()) out += str_field("message", message, 512);
    return out + "}";
}

std::string event_exiting(std::string_view reason) {
    return open("exiting") + str_field("reason", reason, 64) + "}";
}

std::string event_stats(const StatsSnapshot& s) {
    std::string out = open("stats");
    out += num_field("fps", s.fps);
    out += num_field("frame_ms", s.frame_ms);
    out += num_field("frame_ms_max", s.frame_ms_max);
    out += num_field("flip_ms", s.flip_ms);
    out += int_field("frames", static_cast<long long>(s.frames));
    out += int_field("late", static_cast<long long>(s.late));
    out += str_field("rung", s.rung, 32);
    out += int_field("interval", s.interval);
    if (s.temp_c >= 0) out += num_field("temp_c", s.temp_c);
    if (s.arm_mhz >= 0) out += int_field("arm_mhz", s.arm_mhz);
    if (s.gpu_ms >= 0) out += num_field("gpu_ms", s.gpu_ms);
    out += str_field("preset", s.preset, MAX_PRESET_NAME_BYTES);
    out += int_field("pcm_ok", static_cast<long long>(s.pcm_ok));
    out += int_field("pcm_silent", static_cast<long long>(s.pcm_silent));
    out += int_field("warmups", static_cast<long long>(s.warmups));
    out += num_field("warmup_ms_max", s.warmup_ms_max);
    out += int_field("shader_stages", static_cast<long long>(s.shader_stages));
    out += int_field("cached_stages", static_cast<long long>(s.cached_stages));
    out += int_field("stderr_discarded", static_cast<long long>(s.stderr_discarded));
    return out + "}";
}

}  // namespace md
