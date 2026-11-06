// md_scale IN OUT MAX [QUALITY]: write IN to OUT with its longest side at most
// MAX pixels (area-averaged, aspect kept). OUT's extension picks the format
// (.jpg at QUALITY, default 90, or .png). Prints "WxH -> WxH". Exit 1 on an
// unreadable input or a failed write, 2 on usage.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "stb_image.h"  // the fork's stb_image object library
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

namespace {

// One axis of an area-averaging resample: weights of source cells per output cell.
struct Tap {
    int first;
    std::vector<double> weights;
};

std::vector<Tap> taps(int src, int dst) {
    std::vector<Tap> out(dst);
    const double scale = static_cast<double>(src) / dst;
    for (int o = 0; o < dst; o++) {
        const double lo = o * scale, hi = (o + 1) * scale;
        Tap& t = out[o];
        t.first = static_cast<int>(std::floor(lo));
        for (int s = t.first; s < src && s < hi; s++) {
            const double cover = std::fmin(hi, s + 1.0) - std::fmax(lo, static_cast<double>(s));
            t.weights.push_back(cover / scale);
        }
    }
    return out;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 4 || argc > 5) {
        std::fprintf(stderr, "usage: md_scale IN OUT MAX [QUALITY]\n");
        return 2;
    }
    const std::string in = argv[1], out = argv[2];
    const int max = std::atoi(argv[3]);
    const int quality = argc == 5 ? std::atoi(argv[4]) : 90;
    if (max < 1 || quality < 1 || quality > 100) {
        std::fprintf(stderr, "bad MAX or QUALITY\n");
        return 2;
    }
    int w = 0, h = 0, n = 0;
    unsigned char* src = stbi_load(in.c_str(), &w, &h, &n, 3);
    if (src == nullptr) {
        std::fprintf(stderr, "cannot read %s: %s\n", in.c_str(), stbi_failure_reason());
        return 1;
    }
    int ow = w, oh = h;
    if (w > max || h > max) {
        const double f = static_cast<double>(max) / (w > h ? w : h);
        ow = std::max(1, static_cast<int>(std::lround(w * f)));
        oh = std::max(1, static_cast<int>(std::lround(h * f)));
    }
    std::vector<unsigned char> dst(static_cast<size_t>(ow) * oh * 3);
    if (ow == w && oh == h) {
        dst.assign(src, src + dst.size());
    } else {
        const auto tx = taps(w, ow), ty = taps(h, oh);
        std::vector<double> row(static_cast<size_t>(ow) * 3);
        for (int oy = 0; oy < oh; oy++) {
            std::fill(row.begin(), row.end(), 0.0);
            for (size_t j = 0; j < ty[oy].weights.size(); j++) {
                const unsigned char* line = src + static_cast<size_t>(ty[oy].first + j) * w * 3;
                const double wy = ty[oy].weights[j];
                for (int ox = 0; ox < ow; ox++) {
                    for (size_t i = 0; i < tx[ox].weights.size(); i++) {
                        const unsigned char* p = line + static_cast<size_t>(tx[ox].first + i) * 3;
                        const double wgt = wy * tx[ox].weights[i];
                        for (int k = 0; k < 3; k++) row[ox * 3 + k] += wgt * p[k];
                    }
                }
            }
            for (int i = 0; i < ow * 3; i++)
                dst[static_cast<size_t>(oy) * ow * 3 + i] =
                    static_cast<unsigned char>(std::lround(std::fmin(255.0, std::fmax(0.0, row[i]))));
        }
    }
    stbi_image_free(src);
    const bool png = out.size() > 4 && out.compare(out.size() - 4, 4, ".png") == 0;
    const int ok = png ? stbi_write_png(out.c_str(), ow, oh, 3, dst.data(), ow * 3)
                       : stbi_write_jpg(out.c_str(), ow, oh, 3, dst.data(), quality);
    if (!ok) {
        std::fprintf(stderr, "cannot write %s\n", out.c_str());
        return 1;
    }
    std::printf("%dx%d -> %dx%d\n", w, h, ow, oh);
    return 0;
}
