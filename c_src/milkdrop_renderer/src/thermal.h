// Thermal guard (plan P10) and the sysfs readers behind it and `stats`.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <optional>
#include <string>

namespace md {

class ThermalGuard {
public:
    struct Config {
        double drop_c = 78.0;      // sustained this hot ...
        double drop_after_s = 10;  // ... for this long drops one rung (once)
        double exit_c = 83.0;      // this hot exits
    };

    enum class Action { None, DropRung, Exit };

    ThermalGuard() : ThermalGuard(Config{}) {}
    explicit ThermalGuard(Config config) : config_(config) {}

    // One reading at `now_s` (any monotonic seconds).
    Action update(double now_s, double temp_c);

    bool dropped() const { return dropped_; }

private:
    Config config_;
    double hot_since_ = -1;
    bool dropped_ = false;
};

// /sys/class/thermal/thermal_zone0/temp (millidegrees) in degrees C.
std::optional<double> read_temp_c(const std::string& path = "/sys/class/thermal/thermal_zone0/temp");

// /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq (kHz) in MHz.
std::optional<int> read_cpu_mhz(
    const std::string& path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq");

}  // namespace md
