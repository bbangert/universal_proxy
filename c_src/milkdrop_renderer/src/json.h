// Minimal JSON: a DOM parser for the manifest and stdin commands, string
// escaping, and the bounded stdout line writer.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstddef>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace md {

class JsonValue {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0.0;
    std::string string;
    std::vector<JsonValue> array;
    // Insertion order does not matter to any reader here; duplicate keys
    // keep the last value, as most parsers do.
    std::map<std::string, JsonValue, std::less<>> object;

    bool is_null() const { return type == Type::Null; }
    bool is_bool() const { return type == Type::Bool; }
    bool is_number() const { return type == Type::Number; }
    bool is_string() const { return type == Type::String; }
    bool is_array() const { return type == Type::Array; }
    bool is_object() const { return type == Type::Object; }

    // The member `key` of an object, or null when absent / not an object.
    const JsonValue* get(std::string_view key) const;
};

// Parses one JSON text (RFC 8259; nesting limited to 64 levels). Returns
// false with `error` set on malformed input or trailing garbage.
bool json_parse(std::string_view text, JsonValue& out, std::string& error);

// Escapes `"`, `\` and control characters for a JSON string body.
std::string json_escape(std::string_view s);

// Untrusted text made safe for a bounded line: invalid UTF-8 bytes are
// dropped, control characters become spaces, and the result is cut at a
// codepoint boundary to at most `max_bytes`.
std::string sanitize_text(std::string_view s, size_t max_bytes);

// The BEAM reads stdout with `{:line, 4096}`. emit_line refuses anything
// past this budget and writes a short `error` event in its place.
inline constexpr size_t MAX_EMIT_LINE_BYTES = 4000;

// Writes one line to stdout under a mutex (callable from any thread).
void emit_line(const std::string& line);
// emit_line, unless another thread holds the writer for `timeout_ms` (a
// stuck write): then nothing is written and false is returned.
bool emit_line_within(const std::string& line, int timeout_ms);

// Redirects emit_line (tests). Null restores stdout.
void set_emit_sink(std::function<void(const std::string&)> sink);

}  // namespace md
