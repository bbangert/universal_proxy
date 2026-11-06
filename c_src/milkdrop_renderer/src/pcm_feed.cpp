#include "pcm_feed.h"

#include <cstring>
#include <ctime>
#include <sys/stat.h>
#include <utility>

namespace md {

namespace {

int64_t clock_us(clockid_t id) {
    timespec ts{};
    clock_gettime(id, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000 + ts.tv_nsec / 1000;
}

}  // namespace

int64_t monotonic_us() { return clock_us(CLOCK_MONOTONIC); }
int64_t monotonic_raw_us() { return clock_us(CLOCK_MONOTONIC_RAW); }

int64_t sample_raw_offset_us() {
    // The tightest of a few bracketed samples.
    int64_t best_offset = 0, best_span = INT64_MAX;
    for (int i = 0; i < 5; i++) {
        int64_t m1 = monotonic_us();
        int64_t r = monotonic_raw_us();
        int64_t m2 = monotonic_us();
        if (m2 - m1 < best_span) {
            best_span = m2 - m1;
            best_offset = r - (m1 + (m2 - m1) / 2);
        }
    }
    return best_offset;
}

PcmFeed::PcmFeed(std::string path, int64_t av_offset_us)
    : path_(std::move(path)), av_offset_us_(av_offset_us) {}

bool PcmFeed::try_open() {
    struct stat st {};
    if (::stat(path_.c_str(), &st) != 0) return false;
    if (!reader_.open(path_.c_str())) return false;
    dev_ = st.st_dev;
    ino_ = st.st_ino;
    return true;
}

void PcmFeed::maintain(int64_t now_mono_us) {
    if (!fixed_offset_ && (last_offset_sample_us_ == 0 || now_mono_us - last_offset_sample_us_ >= 10000000)) {
        offset_us_ = sample_raw_offset_us();
        last_offset_sample_us_ = now_mono_us;
    }
    if (path_.empty()) return;
    if (reader_.is_open()) {
        // The writer may have replaced the file (a new inode): remap it.
        struct stat st {};
        if (::stat(path_.c_str(), &st) == 0 && st.st_dev == dev_ && st.st_ino == ino_) return;
        reader_.close();
    }
    if (last_open_try_us_ >= 0 && now_mono_us - last_open_try_us_ < 1000000) return;
    last_open_try_us_ = now_mono_us;
    try_open();
}

PcmFeed::Result PcmFeed::read(int64_t t_mono_us, int16_t* out) {
    using Status = pcm_tap::Reader::Status;
    if (reader_.is_open()) {
        const int64_t t_raw = t_mono_us + offset_us_ + av_offset_us_;
        Status st = reader_.read_ending_at(t_raw, FRAMES, out);
        for (int i = 0; st == Status::Retry && i < RETRIES; i++) st = reader_.read_ending_at(t_raw, FRAMES, out);
        if (st == Status::Ok) {
            ok++;
            return Result::Ok;
        }
    }
    std::memset(out, 0, size_t{FRAMES} * 2 * sizeof(int16_t));
    silent++;
    return Result::Silent;
}

}  // namespace md
