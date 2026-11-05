#include "artwork_store.h"

#include "sha256.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <utility>

namespace {

bool write_file_atomic(const std::string& tmp, const std::string& dest, const uint8_t* data,
                       size_t len) {
    int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return false;
    bool ok = true;
    while (len > 0) {
        ssize_t n = ::write(fd, data, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            ok = false;
            break;
        }
        data += n;
        len -= static_cast<size_t>(n);
    }
    if (::close(fd) != 0) ok = false;
    if (ok && ::rename(tmp.c_str(), dest.c_str()) != 0) ok = false;
    if (!ok) ::unlink(tmp.c_str());
    return ok;
}

}  // namespace

ArtworkStore::ArtworkStore(std::string dir, size_t keep)
    : dir_(std::move(dir)), keep_(std::max<size_t>(keep, 1)) {}

bool ArtworkStore::pending_path(const std::string& path) const {
    return std::any_of(pending_.begin(), pending_.end(),
                       [&](const Image& p) { return p.valid && p.path == path; });
}

bool ArtworkStore::shown_path(const std::string& path) const {
    return std::find(shown_.begin(), shown_.end(), path) != shown_.end();
}

bool ArtworkStore::stage(uint8_t slot, const uint8_t* data, size_t length, bool png) {
    if (slot >= SLOTS) return false;
    const char* ext = png ? "png" : "jpg";
    std::string sha = sha256_hex(data, length);
    std::string path = dir_ + "/" + sha + "." + ext;
    std::string tmp = dir_ + "/." + sha + "." + ext + ".tmp";

    // Under the lock, so a concurrent take() cannot evict (unlink) this
    // path between the write and it becoming pending.
    std::lock_guard<std::mutex> lock(mtx_);
    bool ok = write_file_atomic(tmp, path, data, length);
    if (!ok) {
        std::fprintf(stderr, "sendspin_player: failed to write artwork %s: %s\n", path.c_str(),
                     std::strerror(errno));
    }

    Image old = std::exchange(pending_[slot], Image{});
    if (old.valid && old.path != path && !shown_path(old.path) && !pending_path(old.path)) {
        ::unlink(old.path.c_str());
    }

    Image& p = pending_[slot];
    p.valid = ok;
    p.path = std::move(path);
    p.format = png ? "png" : "jpeg";
    p.bytes = length;
    p.seq = ++next_seq_;
    return ok;
}

ArtworkStore::Image ArtworkStore::take(uint8_t slot) {
    if (slot >= SLOTS) return {};
    std::lock_guard<std::mutex> lock(mtx_);
    Image img = std::exchange(pending_[slot], Image{});
    if (!img.valid) return img;

    shown_.erase(std::remove(shown_.begin(), shown_.end(), img.path), shown_.end());
    shown_.push_front(img.path);
    while (shown_.size() > keep_) {
        std::string victim = std::move(shown_.back());
        shown_.pop_back();
        if (!pending_path(victim)) ::unlink(victim.c_str());
    }
    return img;
}
