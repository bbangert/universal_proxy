#include "thermal.h"

#include <cerrno>
#include <cstdio>
#include <cstdlib>

namespace md {

ThermalGuard::Action ThermalGuard::update(double now_s, double temp_c) {
    if (temp_c >= config_.exit_c) return Action::Exit;
    if (temp_c < config_.drop_c) {
        hot_since_ = -1;
        return Action::None;
    }
    if (hot_since_ < 0) hot_since_ = now_s;
    if (!dropped_ && now_s - hot_since_ >= config_.drop_after_s) {
        dropped_ = true;
        return Action::DropRung;
    }
    return Action::None;
}

namespace {

std::optional<long> read_long(const std::string& path) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (f == nullptr) return std::nullopt;
    char buf[64] = {0};
    size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    if (n == 0) return std::nullopt;
    char* end = nullptr;
    errno = 0;
    long v = std::strtol(buf, &end, 10);
    if (errno != 0 || end == buf) return std::nullopt;
    return v;
}

}  // namespace

std::optional<double> read_temp_c(const std::string& path) {
    auto v = read_long(path);
    if (!v) return std::nullopt;
    return static_cast<double>(*v) / 1000.0;
}

std::optional<int> read_cpu_mhz(const std::string& path) {
    auto v = read_long(path);
    if (!v) return std::nullopt;
    return static_cast<int>(*v / 1000);
}

}  // namespace md
