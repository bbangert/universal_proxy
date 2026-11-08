#include "manifest.h"

#include "json.h"
#include "protocol.h"

#include <cerrno>
#include <cmath>
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

FileStatus read_file_status(const std::string& path, std::string& out, size_t max_bytes, std::string& error) {
    out.clear();
    FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        if (errno == ENOENT || errno == ENOTDIR) return FileStatus::Missing;
        error = "cannot open " + path;
        return FileStatus::Invalid;
    }
    char buf[65536];
    size_t n;
    bool ok = true;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
        if (out.size() + n > max_bytes) {
            error = path + " is over " + std::to_string(max_bytes) + " bytes";
            ok = false;
            break;
        }
        out.append(buf, n);
    }
    if (ok && std::ferror(f)) {
        error = "cannot read " + path;
        ok = false;
    }
    std::fclose(f);
    if (!ok) out.clear();
    return ok ? FileStatus::Ok : FileStatus::Invalid;
}

bool read_file(const std::string& path, std::string& out, size_t max_bytes) {
    std::string error;
    return read_file_status(path, out, max_bytes, error) == FileStatus::Ok;
}

bool is_user_id(std::string_view id) { return id.substr(0, USER_PREFIX.size()) == USER_PREFIX; }

size_t drop_user_ids(Manifest& pack) {
    const size_t before = pack.presets.size();
    std::erase_if(pack.presets, [](const PresetEntry& e) { return is_user_id(e.file); });
    const size_t dropped = before - pack.presets.size();
    pack.rejected += dropped;
    return dropped;
}

FileStatus load_user_manifest(const std::string& dir, Manifest& out, std::string& error) {
    out = Manifest{};
    if (dir.empty()) return FileStatus::Missing;
    std::string text;
    const FileStatus st = read_file_status(dir + "/manifest.json", text, MAX_USER_MANIFEST_BYTES, error);
    if (st != FileStatus::Ok) return st;
    Manifest parsed;
    if (!parse_manifest(text, parsed, error)) return FileStatus::Invalid;
    out.version = parsed.version;
    out.format = parsed.format;
    out.rejected = parsed.rejected;
    for (PresetEntry& e : parsed.presets) {
        e.file = std::string(USER_PREFIX) + e.file;
        if (!valid_preset_file(e.file)) {
            out.rejected++;
            continue;
        }
        out.presets.push_back(std::move(e));
    }
    return FileStatus::Ok;
}

std::string preset_file_path(std::string_view pack_dir, std::string_view user_dir, std::string_view id) {
    if (!is_user_id(id)) return std::string(pack_dir) + "/presets/" + std::string(id);
    if (user_dir.empty()) return {};
    return std::string(user_dir) + "/presets/" + std::string(id.substr(USER_PREFIX.size()));
}

std::vector<std::string> texture_search_paths(std::string_view pack_dir, std::string_view user_dir) {
    std::vector<std::string> out{std::string(pack_dir) + "/textures"};
    if (!user_dir.empty()) out.push_back(std::string(user_dir) + "/textures");
    return out;
}

namespace {

bool id_list(const JsonValue& doc, std::string_view key, std::set<std::string, std::less<>>& out,
             std::string& error) {
    const JsonValue* v = doc.get(key);
    if (v == nullptr || v->is_null()) return true;
    if (!v->is_array()) {
        error = std::string(key) + " is not an array";
        return false;
    }
    for (const JsonValue& id : v->array) {
        if (!id.is_string()) {
            error = std::string(key) + " has a non-string id";
            return false;
        }
        if (valid_preset_file(id.string)) out.insert(id.string);
    }
    return true;
}

}  // namespace

bool parse_selection(std::string_view text, UserSelection& out, std::string& error) {
    JsonValue doc;
    if (!json_parse(text, doc, error)) return false;
    if (!doc.is_object()) {
        error = "selection is not an object";
        return false;
    }
    UserSelection sel;
    if (const JsonValue* gen = doc.get("gen"); gen != nullptr) {
        // Integral and exactly representable.
        if (!gen->is_number() || gen->number != std::floor(gen->number) || gen->number < 0 ||
            gen->number > 9007199254740992.0) {
            error = "bad gen";
            return false;
        }
        sel.gen = static_cast<int64_t>(gen->number);
    }
    if (const JsonValue* en = doc.get("playlist_enabled"); en != nullptr) {
        if (!en->is_bool()) {
            error = "bad playlist_enabled";
            return false;
        }
        sel.playlist_enabled = en->boolean;
    }
    if (!id_list(doc, "favourites", sel.favourites, error) || !id_list(doc, "hidden", sel.hidden, error) ||
        !id_list(doc, "playlist", sel.playlist, error))
        return false;
    out = std::move(sel);
    return true;
}

FileStatus load_selection(const std::string& path, UserSelection& out, std::string& error) {
    if (path.empty()) {
        out = UserSelection{};
        return FileStatus::Missing;
    }
    std::string text;
    const FileStatus st = read_file_status(path, text, MAX_SELECTION_BYTES, error);
    if (st == FileStatus::Missing) out = UserSelection{};
    if (st != FileStatus::Ok) return st;
    return parse_selection(text, out, error) ? FileStatus::Ok : FileStatus::Invalid;
}

}  // namespace md
