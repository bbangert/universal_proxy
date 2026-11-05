// Artwork files for the display roles: written on decode, handed out on
// display, and pruned here — the one place that knows both which files are
// shown and which are about to be.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>

class ArtworkStore {
public:
    static constexpr size_t SLOTS = 4;

    struct Image {
        bool valid = false;
        std::string path;
        const char* format = "";
        size_t bytes = 0;
        uint64_t seq = 0;
    };

    // Keeps the `keep` most recently displayed files in `dir`.
    ArtworkStore(std::string dir, size_t keep);

    // Decode thread: writes the image to <dir>/<sha256>.<jpg|png> (dot-temp +
    // rename) as the slot's pending image. A pending image it replaces that
    // was never displayed is deleted. Returns false if the write failed.
    bool stage(uint8_t slot, const uint8_t* data, size_t length, bool png);

    // Display time: takes the slot's pending image (invalid if none, or if
    // its write failed) and makes it the most recently displayed file,
    // deleting displayed files beyond `keep` unless one is pending again.
    Image take(uint8_t slot);

private:
    bool pending_path(const std::string& path) const;  // mtx_ held
    bool shown_path(const std::string& path) const;    // mtx_ held

    std::string dir_;
    size_t keep_;
    std::mutex mtx_;
    std::array<Image, SLOTS> pending_{};
    std::deque<std::string> shown_;  // most recent first
    uint64_t next_seq_ = 0;
};
