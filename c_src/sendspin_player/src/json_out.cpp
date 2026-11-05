#include "json_out.h"

#include <cstdio>
#include <iostream>
#include <mutex>

namespace {

std::mutex g_stdout_mtx;

// Length of the well-formed UTF-8 sequence starting at s[i], or 0 if the
// bytes there are not one (same rules as is_valid_utf8).
size_t utf8_seq_len(std::string_view s, size_t i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t needed = 0;
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) {
        if (c < 0xC2) return 0;  // overlong 2-byte
        needed = 1;
    } else if ((c & 0xF0) == 0xE0) {
        needed = 2;
    } else if ((c & 0xF8) == 0xF0) {
        if (c > 0xF4) return 0;  // beyond U+10FFFF
        needed = 3;
    } else {
        return 0;
    }
    if (i + needed >= s.size()) return 0;
    for (size_t j = 1; j <= needed; j++) {
        if ((static_cast<unsigned char>(s[i + j]) & 0xC0) != 0x80) return 0;
    }
    unsigned char c1 = static_cast<unsigned char>(s[i + 1]);
    if (needed == 2) {
        if (c == 0xE0 && c1 < 0xA0) return 0;   // overlong
        if (c == 0xED && c1 >= 0xA0) return 0;  // surrogate
    }
    if (needed == 3) {
        if (c == 0xF0 && c1 < 0x90) return 0;   // overlong
        if (c == 0xF4 && c1 >= 0x90) return 0;  // beyond U+10FFFF
    }
    return needed + 1;
}

}  // namespace

bool is_valid_utf8(const std::string& s) {
    size_t i = 0;
    while (i < s.size()) {
        size_t n = utf8_seq_len(s, i);
        if (n == 0) return false;
        i += n;
    }
    return true;
}

std::string json_escape(const std::string& s) {
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

std::string sanitize_text(std::string_view s, size_t max_bytes) {
    std::string out;
    out.reserve(s.size() < max_bytes ? s.size() : max_bytes);
    size_t i = 0;
    while (i < s.size()) {
        size_t n = utf8_seq_len(s, i);
        if (n == 0) {
            i++;
            continue;
        }
        if (out.size() + n > max_bytes) break;
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (n == 1 && (c < 0x20 || c == 0x7F)) {
            out += ' ';
        } else {
            out.append(s.data() + i, n);
        }
        i += n;
    }
    return out;
}

void emit_json(const std::string& line) {
    std::lock_guard<std::mutex> lock(g_stdout_mtx);
    if (line.size() > MAX_EMIT_LINE_BYTES) {
        std::fprintf(stderr, "sendspin_player: dropped a %zu-byte stdout line: %.64s\n",
                     line.size(), line.c_str());
        std::cout << "{\"event\":\"error\",\"kind\":\"oversize_line\",\"msg\":\"dropped a "
                  << line.size() << "-byte stdout line\"}\n";
    } else {
        std::cout << line << '\n';
    }
    std::cout.flush();
}
