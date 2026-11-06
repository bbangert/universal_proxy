#include "json.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <mutex>
#include <poll.h>
#include <unistd.h>

namespace md {

const JsonValue* JsonValue::get(std::string_view key) const {
    if (type != Type::Object) return nullptr;
    auto it = object.find(key);
    return it == object.end() ? nullptr : &it->second;
}

namespace {

constexpr int MAX_DEPTH = 64;

class Parser {
public:
    explicit Parser(std::string_view text) : s_(text) {}

    bool parse(JsonValue& out, std::string& error) {
        skip_ws();
        if (!value(out, 0)) {
            error = error_.empty() ? "invalid JSON" : error_;
            return false;
        }
        skip_ws();
        if (pos_ != s_.size()) {
            error = "trailing characters at " + std::to_string(pos_);
            return false;
        }
        return true;
    }

private:
    std::string_view s_;
    size_t pos_ = 0;
    std::string error_;

    bool fail(const char* what) {
        if (error_.empty()) error_ = std::string(what) + " at " + std::to_string(pos_);
        return false;
    }

    void skip_ws() {
        while (pos_ < s_.size() &&
               (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r'))
            pos_++;
    }

    bool literal(std::string_view word) {
        if (s_.substr(pos_, word.size()) != word) return fail("bad literal");
        pos_ += word.size();
        return true;
    }

    bool value(JsonValue& out, int depth) {
        if (depth > MAX_DEPTH) return fail("nesting too deep");
        if (pos_ >= s_.size()) return fail("unexpected end");
        switch (s_[pos_]) {
            case '{': return object(out, depth);
            case '[': return array(out, depth);
            case '"':
                out.type = JsonValue::Type::String;
                return string(out.string);
            case 't':
                out.type = JsonValue::Type::Bool;
                out.boolean = true;
                return literal("true");
            case 'f':
                out.type = JsonValue::Type::Bool;
                out.boolean = false;
                return literal("false");
            case 'n':
                out.type = JsonValue::Type::Null;
                return literal("null");
            default: return number(out);
        }
    }

    bool object(JsonValue& out, int depth) {
        out.type = JsonValue::Type::Object;
        pos_++;  // {
        skip_ws();
        if (pos_ < s_.size() && s_[pos_] == '}') {
            pos_++;
            return true;
        }
        while (true) {
            skip_ws();
            if (pos_ >= s_.size() || s_[pos_] != '"') return fail("expected key");
            std::string key;
            if (!string(key)) return false;
            skip_ws();
            if (pos_ >= s_.size() || s_[pos_] != ':') return fail("expected ':'");
            pos_++;
            skip_ws();
            JsonValue v;
            if (!value(v, depth + 1)) return false;
            out.object[key] = std::move(v);
            skip_ws();
            if (pos_ >= s_.size()) return fail("unterminated object");
            if (s_[pos_] == ',') {
                pos_++;
                continue;
            }
            if (s_[pos_] == '}') {
                pos_++;
                return true;
            }
            return fail("expected ',' or '}'");
        }
    }

    bool array(JsonValue& out, int depth) {
        out.type = JsonValue::Type::Array;
        pos_++;  // [
        skip_ws();
        if (pos_ < s_.size() && s_[pos_] == ']') {
            pos_++;
            return true;
        }
        while (true) {
            skip_ws();
            JsonValue v;
            if (!value(v, depth + 1)) return false;
            out.array.push_back(std::move(v));
            skip_ws();
            if (pos_ >= s_.size()) return fail("unterminated array");
            if (s_[pos_] == ',') {
                pos_++;
                continue;
            }
            if (s_[pos_] == ']') {
                pos_++;
                return true;
            }
            return fail("expected ',' or ']'");
        }
    }

    static void put_utf8(std::string& out, uint32_t cp) {
        if (cp < 0x80) {
            out += static_cast<char>(cp);
        } else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool hex4(uint32_t& v) {
        if (pos_ + 4 > s_.size()) return fail("short \\u escape");
        v = 0;
        for (int i = 0; i < 4; i++) {
            char c = s_[pos_++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
            else return fail("bad \\u escape");
        }
        return true;
    }

    bool string(std::string& out) {
        pos_++;  // opening quote
        out.clear();
        while (pos_ < s_.size()) {
            char c = s_[pos_++];
            if (c == '"') return true;
            if (static_cast<unsigned char>(c) < 0x20) return fail("control character in string");
            if (c != '\\') {
                out += c;
                continue;
            }
            if (pos_ >= s_.size()) break;
            char e = s_[pos_++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    uint32_t cp = 0;
                    if (!hex4(cp)) return false;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        uint32_t lo = 0;
                        if (s_.substr(pos_, 2) != "\\u") return fail("lone surrogate");
                        pos_ += 2;
                        if (!hex4(lo) || lo < 0xDC00 || lo > 0xDFFF) return fail("bad surrogate pair");
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        return fail("lone surrogate");
                    }
                    put_utf8(out, cp);
                    break;
                }
                default: return fail("bad escape");
            }
        }
        return fail("unterminated string");
    }

    bool number(JsonValue& out) {
        const size_t start = pos_;
        if (pos_ < s_.size() && s_[pos_] == '-') pos_++;
        if (pos_ >= s_.size() || !isdigit(s_[pos_])) return fail("bad number");
        if (s_[pos_] == '0') {
            pos_++;
        } else {
            while (pos_ < s_.size() && isdigit(s_[pos_])) pos_++;
        }
        if (pos_ < s_.size() && s_[pos_] == '.') {
            pos_++;
            if (pos_ >= s_.size() || !isdigit(s_[pos_])) return fail("bad fraction");
            while (pos_ < s_.size() && isdigit(s_[pos_])) pos_++;
        }
        if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
            pos_++;
            if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) pos_++;
            if (pos_ >= s_.size() || !isdigit(s_[pos_])) return fail("bad exponent");
            while (pos_ < s_.size() && isdigit(s_[pos_])) pos_++;
        }
        std::string text(s_.substr(start, pos_ - start));
        errno = 0;
        double v = std::strtod(text.c_str(), nullptr);
        if (!std::isfinite(v)) return fail("number out of range");
        out.type = JsonValue::Type::Number;
        out.number = v;
        return true;
    }

    static bool isdigit(char c) { return c >= '0' && c <= '9'; }
};

// Length of the well-formed UTF-8 sequence starting at s[i], or 0.
size_t utf8_seq_len(std::string_view s, size_t i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t needed = 0;
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) {
        if (c < 0xC2) return 0;
        needed = 1;
    } else if ((c & 0xF0) == 0xE0) {
        needed = 2;
    } else if ((c & 0xF8) == 0xF0) {
        if (c > 0xF4) return 0;
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
        if (c == 0xE0 && c1 < 0xA0) return 0;
        if (c == 0xED && c1 >= 0xA0) return 0;
    }
    if (needed == 3) {
        if (c == 0xF0 && c1 < 0x90) return 0;
        if (c == 0xF4 && c1 >= 0x90) return 0;
    }
    return needed + 1;
}

std::timed_mutex g_emit_mtx;
std::function<void(const std::string&)> g_sink;

void write_all(const std::string& s) {
    const char* p = s.data();
    size_t left = s.size();
    while (left > 0) {
        ssize_t n = ::write(STDOUT_FILENO, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;  // EPIPE: the owner is gone; stdin EOF follows
        p += n;
        left -= static_cast<size_t>(n);
    }
}

}  // namespace

bool json_parse(std::string_view text, JsonValue& out, std::string& error) {
    out = JsonValue{};
    Parser p(text);
    return p.parse(out, error);
}

std::string json_escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
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

static std::string framed(const std::string& line) {
    if (line.size() > MAX_EMIT_LINE_BYTES)
        return "{\"event\":\"error\",\"reason\":\"oversize_line\",\"bytes\":" + std::to_string(line.size()) + "}";
    return line;
}

void emit_line(const std::string& line) {
    std::lock_guard<std::timed_mutex> lock(g_emit_mtx);
    std::string out = framed(line);
    if (g_sink) {
        g_sink(out);
        return;
    }
    out += '\n';
    write_all(out);
}

bool emit_line_within(const std::string& line, int timeout_ms) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    std::unique_lock<std::timed_mutex> lock(g_emit_mtx, deadline);
    if (!lock.owns_lock()) return false;
    std::string out = framed(line);
    if (g_sink) {
        g_sink(out);
        return true;
    }
    out += '\n';
    const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
    return write_within(STDOUT_FILENO, out, static_cast<int>(std::max<int64_t>(0, left.count())));
}

bool write_within(int fd, std::string_view data, int timeout_ms) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    // The file description may be shared with a thread blocked in a write
    // on it; flipping O_NONBLOCK affects that one too (callers are about
    // to exit). The flags are restored after.
    const int flags = ::fcntl(fd, F_GETFL);
    const bool set_nonblock = flags >= 0 && (flags & O_NONBLOCK) == 0;
    if (set_nonblock) ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    bool ok = true;
    while (!data.empty()) {
        const ssize_t n = ::write(fd, data.data(), data.size());
        if (n > 0) {
            data.remove_prefix(static_cast<size_t>(n));
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now());
            if (left.count() <= 0) {
                ok = false;
                break;
            }
            pollfd p{fd, POLLOUT, 0};
            (void)::poll(&p, 1, static_cast<int>(left.count()));
            continue;
        }
        ok = false;
        break;
    }
    if (set_nonblock) ::fcntl(fd, F_SETFL, flags);
    return ok;
}

void set_emit_sink(std::function<void(const std::string&)> sink) {
    std::lock_guard<std::timed_mutex> lock(g_emit_mtx);
    g_sink = std::move(sink);
}

}  // namespace md
