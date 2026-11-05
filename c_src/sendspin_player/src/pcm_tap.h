// PCM tap ring: the file layout shared by sendspin_player (the one writer)
// and readers in other processes (the milkdrop_renderer), plus the reader.
//
// Self-contained (C++20 standard library and POSIX only) so a reader can
// copy this header as is. The writer is in pcm_tap_writer.h.
//
// The file is one mmap'd region, little-endian, naturally aligned:
//
//   [0, 64)                 Header
//   [64, 64 + 24 * C)       ChunkRecord[C]      C = chunk_capacity
//   [.., .. + 4 * F)        int16_t[F][2]       F = capacity_frames
//
// Samples are interleaved stereo S16 in a ring of F frames: absolute frame
// index i lives in slot i % F. The frame counters never wrap, only the slot
// offsets do. Each committed chunk adds one ChunkRecord (slot n % C for the
// n-th chunk) naming its frames and the play time of its last frame.
//
// Concurrency: one writer, any number of readers, no locks.
//   * Before touching samples or a record the writer raises
//     frames_reserved / chunks_reserved past what it is about to write;
//     after, it publishes frames_written / chunks_written. A reader copies
//     what the *_written counters cover, then re-reads the *_reserved ones:
//     anything older than reserved - capacity may have been overwritten
//     during the copy and the read is discarded (Status::Retry).
//   * epoch and sample_rate change under `seq` (odd while changing), a
//     seqlock; a read that saw `seq` change is discarded too.
//   * The epoch bumps on every stream start, format change, flush and tap
//     disable. Records carry their epoch; a reader only uses the current
//     epoch's records, so a new epoch reads as no data until it has some.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace pcm_tap {

inline constexpr uint32_t MAGIC = 0x4D435055;  // "UPCM" in file byte order
inline constexpr uint16_t VERSION = 1;
inline constexpr uint16_t FORMAT_S16LE = 1;  // interleaved, signed 16-bit LE
inline constexpr uint16_t CHANNELS = 2;      // mono is duplicated, >2 keeps L/R
inline constexpr uint32_t DEFAULT_CAPACITY_FRAMES = 65536;  // ~1.4 s at 48 kHz
inline constexpr uint32_t DEFAULT_CHUNK_CAPACITY = 1024;

struct Header {
    uint32_t magic;            //  0  MAGIC, written last at init
    uint16_t version;          //  4  VERSION
    uint16_t header_bytes;     //  6  sizeof(Header)
    uint32_t seq;              //  8  seqlock over epoch + sample_rate (odd = changing)
    uint32_t epoch;            // 12
    uint32_t sample_rate;      // 16  Hz; 0 = no stream
    uint16_t channels;         // 20  CHANNELS
    uint16_t format;           // 22  FORMAT_S16LE
    uint32_t capacity_frames;  // 24  F, a power of two
    uint32_t chunk_capacity;   // 28  C, a power of two
    uint64_t frames_reserved;  // 32
    uint64_t frames_written;   // 40  the write index (total frames committed)
    uint64_t chunks_reserved;  // 48
    uint64_t chunks_written;   // 56  total chunks committed
};

struct ChunkRecord {
    uint64_t start_frame;  //  0  absolute index of the chunk's first frame
    int64_t t_end_us;      //  8  CLOCK_MONOTONIC_RAW play time of its last frame
    uint32_t frames;       // 16
    uint32_t epoch;        // 20
};

static_assert(sizeof(Header) == 64);
static_assert(offsetof(Header, magic) == 0);
static_assert(offsetof(Header, version) == 4);
static_assert(offsetof(Header, header_bytes) == 6);
static_assert(offsetof(Header, seq) == 8);
static_assert(offsetof(Header, epoch) == 12);
static_assert(offsetof(Header, sample_rate) == 16);
static_assert(offsetof(Header, channels) == 20);
static_assert(offsetof(Header, format) == 22);
static_assert(offsetof(Header, capacity_frames) == 24);
static_assert(offsetof(Header, chunk_capacity) == 28);
static_assert(offsetof(Header, frames_reserved) == 32);
static_assert(offsetof(Header, frames_written) == 40);
static_assert(offsetof(Header, chunks_reserved) == 48);
static_assert(offsetof(Header, chunks_written) == 56);
static_assert(sizeof(ChunkRecord) == 24);
static_assert(offsetof(ChunkRecord, start_frame) == 0);
static_assert(offsetof(ChunkRecord, t_end_us) == 8);
static_assert(offsetof(ChunkRecord, frames) == 16);
static_assert(offsetof(ChunkRecord, epoch) == 20);

// The counters are shared across processes, so they must be plain
// lock-free atomics. Loads compile to loads only (armv7 cortex-a53:
// ldrd/ldaexd), which is what lets the reader map the file read-only.
static_assert(std::atomic_ref<uint64_t>::is_always_lock_free);
static_assert(std::atomic_ref<uint32_t>::is_always_lock_free);
static_assert(std::atomic_ref<uint64_t>::required_alignment <= 8);

inline constexpr size_t records_offset() { return sizeof(Header); }

inline constexpr size_t samples_offset(uint32_t chunk_capacity) {
    return records_offset() + size_t{chunk_capacity} * sizeof(ChunkRecord);
}

inline constexpr size_t file_bytes(uint32_t capacity_frames, uint32_t chunk_capacity) {
    return samples_offset(chunk_capacity) +
           size_t{capacity_frames} * CHANNELS * sizeof(int16_t);
}

inline constexpr bool power_of_two(uint32_t v) { return v != 0 && (v & (v - 1)) == 0; }

template <typename T>
inline std::atomic_ref<T> atomic(T& field) {
    return std::atomic_ref<T>(field);
}

// Samples and records are copied with memcpy under the counters/seqlock
// above: a reader may copy bytes the writer is overwriting, and discards
// them by the after-copy check. The fences order those plain copies
// against the counters.

class Reader {
public:
    enum class Status {
        Ok,      // `out` holds the requested frames
        NoData,  // nothing covers that time in the current epoch (or no stream)
        Retry,   // the writer overtook the copy; try again or treat as no data
    };

    struct Info {
        uint32_t epoch = 0;
        uint32_t sample_rate = 0;
        uint64_t end_frame = 0;  // absolute index one past the last frame copied
    };

    Reader() = default;
    ~Reader() { close(); }
    Reader(const Reader&) = delete;
    Reader& operator=(const Reader&) = delete;

    // Maps `path` read-only. False when it is missing, not yet initialized
    // or not this layout; try again later.
    bool open(const char* path) {
        close();
        int fd = ::open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) return false;
        struct stat st {};
        if (::fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(sizeof(Header))) {
            ::close(fd);
            return false;
        }
        size_t size = static_cast<size_t>(st.st_size);
        void* base = ::mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
        ::close(fd);
        if (base == MAP_FAILED) return false;
        base_ = static_cast<uint8_t*>(base);
        size_ = size;
        if (!valid()) {
            close();
            return false;
        }
        return true;
    }

    void close() {
        if (base_ != nullptr) ::munmap(base_, size_);
        base_ = nullptr;
        size_ = 0;
    }

    bool is_open() const { return base_ != nullptr; }

    // The current epoch and rate, or false while they are being changed.
    bool format(Info& info) const {
        if (base_ == nullptr) return false;
        Header& h = header();
        uint32_t s1 = atomic(h.seq).load(std::memory_order_acquire);
        if (s1 & 1u) return false;
        info.epoch = atomic(h.epoch).load(std::memory_order_relaxed);
        info.sample_rate = atomic(h.sample_rate).load(std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        return atomic(h.seq).load(std::memory_order_relaxed) == s1;
    }

    // Copies into `out` (frames * CHANNELS samples) the `frames` frames
    // whose last one plays at `t_end_us` (CLOCK_MONOTONIC_RAW). Frames
    // before the current epoch's first are zero.
    Status read_ending_at(int64_t t_end_us, uint32_t frames, int16_t* out,
                          Info* info = nullptr) const {
        return read(false, t_end_us, frames, out, info);
    }

    // As read_ending_at, for the newest `frames` frames of the epoch.
    Status read_latest(uint32_t frames, int16_t* out, Info* info = nullptr) const {
        return read(true, 0, frames, out, info);
    }

private:
    uint8_t* base_ = nullptr;
    size_t size_ = 0;
    uint32_t capacity_ = 0;
    uint32_t chunk_capacity_ = 0;

    // The mapping is read-only; atomic_ref needs a non-const object but
    // only loads are ever issued through it.
    Header& header() const { return *reinterpret_cast<Header*>(base_); }

    const ChunkRecord* records() const {
        return reinterpret_cast<const ChunkRecord*>(base_ + records_offset());
    }

    const int16_t* samples() const {
        return reinterpret_cast<const int16_t*>(base_ + samples_offset(chunk_capacity_));
    }

    bool valid() {
        Header& h = header();
        if (atomic(h.magic).load(std::memory_order_acquire) != MAGIC) return false;
        if (h.version != VERSION || h.header_bytes != sizeof(Header)) return false;
        if (h.channels != CHANNELS || h.format != FORMAT_S16LE) return false;
        if (!power_of_two(h.capacity_frames) || !power_of_two(h.chunk_capacity)) return false;
        if (size_ < file_bytes(h.capacity_frames, h.chunk_capacity)) return false;
        capacity_ = h.capacity_frames;
        chunk_capacity_ = h.chunk_capacity;
        return true;
    }

    ChunkRecord record(uint64_t n) const {
        ChunkRecord r;
        std::memcpy(&r, &records()[n & (chunk_capacity_ - 1)], sizeof r);
        return r;
    }

    Status read(bool latest, int64_t t_end_us, uint32_t frames, int16_t* out,
                Info* info) const {
        if (base_ == nullptr || frames == 0 || frames > capacity_) return Status::NoData;
        Header& h = header();

        const uint32_t s1 = atomic(h.seq).load(std::memory_order_acquire);
        if (s1 & 1u) return Status::Retry;
        const uint32_t epoch = atomic(h.epoch).load(std::memory_order_relaxed);
        const uint32_t rate = atomic(h.sample_rate).load(std::memory_order_relaxed);
        const uint64_t written = atomic(h.chunks_written).load(std::memory_order_acquire);
        if (rate == 0 || written == 0) return Status::NoData;
        const uint64_t lo = written > chunk_capacity_ ? written - chunk_capacity_ : 0;

        // Newest to oldest. `best` ends up the oldest record ending at or
        // after the target time; `first` is the oldest frame of the
        // epoch's records read so far.
        uint64_t n = written - 1;
        ChunkRecord best = record(n);
        if (best.epoch != epoch) return Status::NoData;
        if (latest) t_end_us = best.t_end_us;
        if (best.t_end_us < t_end_us) return Status::NoData;  // not written yet
        uint64_t first = best.start_frame;
        bool has_older = false;
        while (!latest && n > lo) {
            ChunkRecord r = record(n - 1);
            if (r.epoch != epoch) break;
            --n;
            first = r.start_frame;
            if (r.t_end_us < t_end_us) {
                has_older = true;
                break;
            }
            best = r;
        }

        // Frames from the target time to the end of `best`, bounded so a
        // torn record cannot overflow the arithmetic (validated below).
        int64_t dt = best.t_end_us - t_end_us;
        if (dt > INT64_C(100000000)) dt = INT64_C(100000000);
        const uint64_t lag = static_cast<uint64_t>(
            (dt * static_cast<int64_t>(rate) + INT64_C(500000)) / INT64_C(1000000));
        uint64_t end = best.start_frame + best.frames;
        if (lag >= best.frames) {
            // Before `best`'s first frame: in a gap after an older chunk,
            // or before the epoch's first one.
            if (!has_older) return Status::NoData;
            end = best.start_frame;
        } else {
            end -= lag;
        }
        const uint64_t start = end > frames ? end - frames : 0;

        // Walk back until the window is covered or the epoch ends there.
        while (first > start && n > lo) {
            ChunkRecord r = record(n - 1);
            if (r.epoch != epoch) break;
            --n;
            first = r.start_frame;
        }
        if (first < start) first = start;
        if (first > end) first = end;

        // Zero what precedes the epoch (or frame 0), copy the rest.
        const uint32_t zeros = frames - static_cast<uint32_t>(end - first);
        if (zeros > 0) std::memset(out, 0, size_t{zeros} * CHANNELS * sizeof(int16_t));
        copy_frames(first, frames - zeros, out + size_t{zeros} * CHANNELS);

        std::atomic_thread_fence(std::memory_order_acquire);
        if (atomic(h.seq).load(std::memory_order_relaxed) != s1) return Status::Retry;
        if (atomic(h.chunks_reserved).load(std::memory_order_relaxed) > n + chunk_capacity_)
            return Status::Retry;
        if (atomic(h.frames_reserved).load(std::memory_order_relaxed) > first + capacity_)
            return Status::Retry;

        if (info != nullptr) {
            info->epoch = epoch;
            info->sample_rate = rate;
            info->end_frame = end;
        }
        return Status::Ok;
    }

    void copy_frames(uint64_t from, uint32_t count, int16_t* out) const {
        if (count == 0) return;
        const uint32_t slot = static_cast<uint32_t>(from & (capacity_ - 1));
        const uint32_t first = count < capacity_ - slot ? count : capacity_ - slot;
        std::memcpy(out, samples() + size_t{slot} * CHANNELS,
                    size_t{first} * CHANNELS * sizeof(int16_t));
        if (count > first)
            std::memcpy(out + size_t{first} * CHANNELS, samples(),
                        size_t{count - first} * CHANNELS * sizeof(int16_t));
    }
};

}  // namespace pcm_tap
