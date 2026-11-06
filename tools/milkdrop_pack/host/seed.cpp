// LD_PRELOAD shim: a deterministic std::random_device (projectM seeds its
// RNGs from it) and a fixed system_clock (MilkdropNoise seeds its noise
// textures from it), so two runs of a preset render the same frames.
#include <chrono>
#include <random>

unsigned int std::random_device::_M_getval() {
    static unsigned s = 0x2545F491u;
    s = s * 1103515245u + 12345u;
    return s;
}

namespace std {
namespace chrono {
inline namespace _V2 {
system_clock::time_point system_clock::now() noexcept {
    return time_point(duration(1700000000LL * 1000000000LL));
}
}  // namespace _V2
}  // namespace chrono
}  // namespace std
