// PCM tap writer: the single producer of the ring laid out in pcm_tap.h.
//
// open() (file creation, sizing, mmap, header init) runs on the main
// thread. Everything else runs on one thread at a time, the playback
// thread while the tap is published to the sink: it never blocks,
// allocates or makes a syscall.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "pcm_tap.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <memory>
#include <string>

namespace pcm_tap {

// Converts `frames` interleaved frames of the sink's input format to
// interleaved stereo S16 in `out` (frames * CHANNELS samples). Formats as
// AlsaPipeSink opens them: 16 = S16_LE, 24 = S24_3LE (packed), 32 =
// S32_LE; deeper samples keep their top 16 bits. Mono is duplicated, more
// than two channels keep the first two. False for any other format.
inline bool to_s16_stereo(const uint8_t* in, uint32_t frames, uint8_t bits_per_sample,
                          uint8_t channels, int16_t* out) {
    if (channels == 0) return false;
    const size_t bytes = bits_per_sample / 8;
    if (bits_per_sample != 16 && bits_per_sample != 24 && bits_per_sample != 32) return false;
    const size_t stride = bytes * channels;
    const size_t right = channels > 1 ? bytes : 0;
    for (uint32_t i = 0; i < frames; ++i) {
        const uint8_t* f = in + size_t{i} * stride;
        for (size_t c = 0; c < CHANNELS; ++c) {
            // Little-endian: the top 16 bits are the last two bytes.
            const uint8_t* p = f + (c == 0 ? 0 : right) + bytes - 2;
            out[size_t{i} * CHANNELS + c] =
                static_cast<int16_t>(static_cast<uint16_t>(p[0] | (p[1] << 8)));
        }
    }
    return true;
}

class Writer {
public:
    // Creates (or reuses) and maps the ring file at `path`. An existing
    // file of this layout keeps its counters and moves to a new epoch, so
    // a reader that still has it mapped resyncs; anything else is
    // resized and zeroed. Null with `err` set on failure.
    static std::unique_ptr<Writer> open(const std::string& path, std::string& err,
                                        uint32_t capacity_frames = DEFAULT_CAPACITY_FRAMES,
                                        uint32_t chunk_capacity = DEFAULT_CHUNK_CAPACITY) {
        if (!power_of_two(capacity_frames) || !power_of_two(chunk_capacity)) {
            err = "capacities must be powers of two";
            return nullptr;
        }
        const size_t bytes = file_bytes(capacity_frames, chunk_capacity);
        int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
        if (fd < 0) {
            err = std::string("open: ") + std::strerror(errno);
            return nullptr;
        }
        struct stat st {};
        if (::fstat(fd, &st) != 0) {
            err = std::string("fstat: ") + std::strerror(errno);
            ::close(fd);
            return nullptr;
        }
        const bool sized = st.st_size == static_cast<off_t>(bytes);
        if (!sized && ::ftruncate(fd, static_cast<off_t>(bytes)) != 0) {
            err = std::string("ftruncate: ") + std::strerror(errno);
            ::close(fd);
            return nullptr;
        }
        int flags = MAP_SHARED;
#ifdef MAP_POPULATE
        flags |= MAP_POPULATE;  // fault the pages in now, not on the playback thread
#endif
        void* base = ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, flags, fd, 0);
        ::close(fd);
        if (base == MAP_FAILED) {
            err = std::string("mmap: ") + std::strerror(errno);
            return nullptr;
        }
        std::unique_ptr<Writer> w(new Writer(static_cast<uint8_t*>(base), bytes,
                                             capacity_frames, chunk_capacity));
        w->init(sized);
        return w;
    }

    ~Writer() { ::munmap(base_, bytes_); }
    Writer(const Writer&) = delete;
    Writer& operator=(const Writer&) = delete;

    // Starts a new epoch for stream `stream` (any id other than the
    // current one) at `sample_rate`.
    void begin_stream(uint64_t stream, uint32_t sample_rate) {
        stream_ = stream;
        rate_ = sample_rate;
        set_format(sample_rate);
    }

    // A new epoch with no stream: readers see no data until the next one.
    void end_stream() { begin_stream(0, 0); }

    // Appends `frames` stereo S16 frames whose last plays at `t_end_us`. A
    // stream id or rate other than the current one starts a new epoch
    // first. Keeps only the newest capacity_frames of an oversize chunk.
    void commit(uint64_t stream, uint32_t sample_rate, const int16_t* stereo, uint32_t frames,
                int64_t t_end_us) {
        if (stream != stream_ || sample_rate != rate_) begin_stream(stream, sample_rate);
        if (frames == 0) return;
        if (frames > capacity_) {
            stereo += size_t{frames - capacity_} * CHANNELS;
            frames = capacity_;
        }
        Header& h = header();
        const uint64_t f0 = frames_;
        const uint64_t f1 = f0 + frames;
        const uint64_t c = chunks_;

        atomic(h.frames_reserved).store(f1, std::memory_order_relaxed);
        atomic(h.chunks_reserved).store(c + 1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);

        const uint32_t slot = static_cast<uint32_t>(f0 & (capacity_ - 1));
        const uint32_t first = frames < capacity_ - slot ? frames : capacity_ - slot;
        std::memcpy(samples() + size_t{slot} * CHANNELS, stereo,
                    size_t{first} * CHANNELS * sizeof(int16_t));
        if (frames > first)
            std::memcpy(samples(), stereo + size_t{first} * CHANNELS,
                        size_t{frames - first} * CHANNELS * sizeof(int16_t));
        const ChunkRecord rec{f0, t_end_us, frames, epoch_};
        std::memcpy(&records()[c & (chunk_capacity_ - 1)], &rec, sizeof rec);

        frames_ = f1;
        chunks_ = c + 1;
        atomic(h.frames_written).store(f1, std::memory_order_release);
        atomic(h.chunks_written).store(c + 1, std::memory_order_release);
    }

    uint32_t epoch() const { return epoch_; }

private:
    uint8_t* base_;
    size_t bytes_;
    uint32_t capacity_;
    uint32_t chunk_capacity_;
    // Writer-side copies of the shared counters.
    uint32_t seq_ = 0;
    uint32_t epoch_ = 0;
    uint64_t frames_ = 0;
    uint64_t chunks_ = 0;
    uint64_t stream_ = 0;
    uint32_t rate_ = 0;

    Writer(uint8_t* base, size_t bytes, uint32_t capacity, uint32_t chunk_capacity)
        : base_(base), bytes_(bytes), capacity_(capacity), chunk_capacity_(chunk_capacity) {}

    Header& header() { return *reinterpret_cast<Header*>(base_); }
    ChunkRecord* records() { return reinterpret_cast<ChunkRecord*>(base_ + records_offset()); }
    int16_t* samples() { return reinterpret_cast<int16_t*>(base_ + samples_offset(chunk_capacity_)); }

    void init(bool sized) {
        Header& h = header();
        const bool reuse = sized && atomic(h.magic).load(std::memory_order_acquire) == MAGIC &&
                           h.version == VERSION && h.header_bytes == sizeof(Header) &&
                           h.channels == CHANNELS && h.format == FORMAT_S16LE &&
                           h.capacity_frames == capacity_ && h.chunk_capacity == chunk_capacity_;
        if (reuse) {
            // Counters stay monotonic for readers that kept the mapping.
            // A writer killed mid-commit leaves the reserved counters past
            // the written ones, over samples it may have overwritten; they
            // are what makes a reader discard those, so this continues
            // from them and never lowers them.
            seq_ = atomic(h.seq).load(std::memory_order_relaxed) & ~1u;
            epoch_ = atomic(h.epoch).load(std::memory_order_relaxed);
            frames_ = std::max(atomic(h.frames_reserved).load(std::memory_order_relaxed),
                               atomic(h.frames_written).load(std::memory_order_relaxed));
            chunks_ = std::max(atomic(h.chunks_reserved).load(std::memory_order_relaxed),
                               atomic(h.chunks_written).load(std::memory_order_relaxed));
            end_stream();
            return;
        }
        atomic(h.magic).store(0, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        std::memset(base_ + sizeof(uint32_t), 0, bytes_ - sizeof(uint32_t));
        h.version = VERSION;
        h.header_bytes = sizeof(Header);
        h.channels = CHANNELS;
        h.format = FORMAT_S16LE;
        h.capacity_frames = capacity_;
        h.chunk_capacity = chunk_capacity_;
        atomic(h.magic).store(MAGIC, std::memory_order_release);
    }

    void set_format(uint32_t sample_rate) {
        Header& h = header();
        atomic(h.seq).store(++seq_, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        atomic(h.epoch).store(++epoch_, std::memory_order_relaxed);
        atomic(h.sample_rate).store(sample_rate, std::memory_order_relaxed);
        atomic(h.seq).store(++seq_, std::memory_order_release);
    }
};

}  // namespace pcm_tap
