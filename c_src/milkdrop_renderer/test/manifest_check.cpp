// milkdrop_manifest_check MANIFEST [PACK_DIR]: run a pack's manifest.json
// through the renderer's own parser (parse_manifest). Prints one JSON line:
//   {"ok":true,"version":"...","presets":N,"rejected":R,"high_frequency":H,
//    "rpi3_skip":S,"missing":M}
// where `missing` counts entries whose presets/<id> isn't a file in PACK_DIR
// (0 without PACK_DIR). Exit 0 when the document parsed, 1 otherwise (with
// {"ok":false,"error":"..."}), 2 on usage. Used by tools/milkdrop_pack.
//
// Licensed under the Apache License, Version 2.0.

#include <sys/stat.h>

#include <cstdio>
#include <string>

#include "json.h"
#include "manifest.h"

int main(int argc, char** argv) {
    if (argc < 2 || argc > 3) {
        std::fprintf(stderr, "usage: milkdrop_manifest_check MANIFEST [PACK_DIR]\n");
        return 2;
    }
    std::string text, error;
    if (!md::read_file(argv[1], text)) {
        std::printf("{\"ok\":false,\"error\":\"cannot read manifest\"}\n");
        return 1;
    }
    md::Manifest manifest;
    if (!md::parse_manifest(text, manifest, error)) {
        std::printf("{\"ok\":false,\"error\":\"%s\"}\n", md::json_escape(error).c_str());
        return 1;
    }
    size_t high_frequency = 0, skip = 0, missing = 0;
    for (const auto& e : manifest.presets) {
        if (e.high_frequency) high_frequency++;
        if (e.rpi3_skip) skip++;
        if (argc == 3) {
            struct stat st {};
            const std::string path = std::string(argv[2]) + "/presets/" + e.file;
            if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) missing++;
        }
    }
    std::printf(
        "{\"ok\":true,\"version\":\"%s\",\"presets\":%zu,\"rejected\":%zu,\"high_frequency\":%zu,"
        "\"rpi3_skip\":%zu,\"missing\":%zu}\n",
        md::json_escape(manifest.version).c_str(), manifest.presets.size(), manifest.rejected, high_frequency,
        skip, missing);
    return 0;
}
