// JSON output helpers shared by the stdout event emitters.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstddef>
#include <string>
#include <string_view>

// The BEAM reads stdout with `{:line, 4096}`: a longer line arrives split
// into fragments that Audio.Player discards. emit_json refuses anything
// past this budget (under 4096 with the newline) and reports the drop
// instead. Every emitter bounds what it echoes so a valid line never gets
// near it (the unit tests check the largest `started` and `metadata`).
inline constexpr size_t MAX_EMIT_LINE_BYTES = 4000;

// RFC 3629 well-formedness (no overlongs, surrogates or > U+10FFFF).
bool is_valid_utf8(const std::string& s);

// Escapes `"`, `\` and control characters for a JSON string body.
std::string json_escape(const std::string& s);

// Network text (track titles, group names) made safe for a bounded line:
// invalid UTF-8 bytes are dropped, control characters become spaces, and
// the result is cut at a codepoint boundary to at most `max_bytes`. After
// this json_escape can at most double the size (only `"` and `\` remain
// to escape).
std::string sanitize_text(std::string_view s, size_t max_bytes);

// Writes one line to stdout under a mutex (callable from any thread). A
// line over MAX_EMIT_LINE_BYTES is not written; a short `error` event of
// kind `oversize_line` is emitted in its place.
void emit_json(const std::string& line);
