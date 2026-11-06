#include "manifest.h"

#include "json.h"
#include "protocol.h"

#include <cstdio>

namespace md {

bool valid_preset_file(std::string_view file) {
    if (file.empty() || file.size() > MAX_PRESET_NAME_BYTES) return false;
    if (file.front() == '/') return false;
    if (file.size() < 6 || file.substr(file.size() - 5) != ".milk") return false;
    for (unsigned char c : file) {
        if (c < 0x20 || c == 0x7F) return false;
    }
    // No ".." path segment.
    size_t start = 0;
    while (start <= file.size()) {
        size_t slash = file.find('/', start);
        std::string_view seg = file.substr(start, slash == file.npos ? file.npos : slash - start);
        if (seg == ".." || seg == "." || seg.empty()) return false;
        if (slash == file.npos) break;
        start = slash + 1;
    }
    return sanitize_text(file, MAX_PRESET_NAME_BYTES).size() == file.size();
}

namespace {

double number_or(const JsonValue* v, double fallback) {
    return v != nullptr && v->is_number() ? v->number : fallback;
}

bool parse_entry(const JsonValue& v, PresetEntry& e) {
    if (!v.is_object()) return false;
    const JsonValue* file = v.get("file");
    if (file == nullptr || !file->is_string() || !valid_preset_file(file->string)) return false;
    e.file = file->string;
    if (const JsonValue* tags = v.get("tags")) {
        if (!tags->is_array()) return false;
        for (const JsonValue& t : tags->array) {
            if (!t.is_string()) return false;
            e.tags.push_back(t.string);
            if (t.string == "high_frequency") e.high_frequency = true;
        }
    }
    if (e.file.rfind("high_frequency/", 0) == 0) e.high_frequency = true;
    if (const JsonValue* rpi3 = v.get("rpi3")) {
        if (rpi3->is_string()) {
            // Shorthand: "skip" or a rung.
            if (rpi3->string == "skip") {
                e.rpi3_skip = true;
            } else if (auto r = parse_resolution(rpi3->string)) {
                e.rpi3_rung = *r;
            } else {
                return false;
            }
        } else if (rpi3->is_object()) {
            const JsonValue* rung = rpi3->get("rung");
            if (rung != nullptr && rung->is_string()) {
                if (rung->string == "skip") {
                    e.rpi3_skip = true;
                } else if (auto r = parse_resolution(rung->string)) {
                    e.rpi3_rung = *r;
                } else {
                    return false;
                }
            } else if (rung != nullptr && !rung->is_null()) {
                return false;
            }
            if (const JsonValue* reason = rpi3->get("reason"); reason != nullptr && reason->is_string())
                e.rpi3_reason = sanitize_text(reason->string, 64);
            e.rpi3_frame_ms = number_or(rpi3->get("frame_ms"), -1);
        } else if (!rpi3->is_null()) {
            return false;
        }
    }
    e.compile_ms = number_or(v.get("compile_ms"), -1);
    e.eval_ms = number_or(v.get("eval_ms"), -1);
    return true;
}

}  // namespace

bool parse_manifest(std::string_view text, Manifest& out, std::string& error) {
    out = Manifest{};
    JsonValue doc;
    if (!json_parse(text, doc, error)) return false;
    if (!doc.is_object()) {
        error = "manifest is not an object";
        return false;
    }
    if (const JsonValue* fmt = doc.get("format"); fmt != nullptr) {
        if (!fmt->is_number() || fmt->number != 1) {
            error = "unsupported manifest format";
            return false;
        }
    }
    if (const JsonValue* ver = doc.get("version"); ver != nullptr && ver->is_string())
        out.version = sanitize_text(ver->string, 64);
    const JsonValue* presets = doc.get("presets");
    if (presets == nullptr || !presets->is_array()) {
        error = "manifest has no presets array";
        return false;
    }
    std::set<std::string, std::less<>> seen;
    for (const JsonValue& v : presets->array) {
        PresetEntry e;
        if (!parse_entry(v, e) || !seen.insert(e.file).second) {
            out.rejected++;
            continue;
        }
        out.presets.push_back(std::move(e));
    }
    return true;
}

std::set<std::string, std::less<>> parse_skip_list(std::string_view text) {
    std::set<std::string, std::less<>> out;
    size_t start = 0;
    while (start < text.size()) {
        size_t nl = text.find('\n', start);
        std::string_view line = text.substr(start, nl == text.npos ? text.npos : nl - start);
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
        if (!line.empty()) out.emplace(line);
        if (nl == text.npos) break;
        start = nl + 1;
    }
    return out;
}

bool read_file(const std::string& path, std::string& out, size_t max_bytes) {
    out.clear();
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) return false;
    char buf[65536];
    size_t n;
    bool ok = true;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
        if (out.size() + n > max_bytes) {
            ok = false;
            break;
        }
        out.append(buf, n);
    }
    if (std::ferror(f)) ok = false;
    std::fclose(f);
    return ok;
}

}  // namespace md
