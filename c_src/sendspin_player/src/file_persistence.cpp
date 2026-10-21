#include "file_persistence.h"

#include "sendspin/persistence_keys.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace {

// Larger than any library blob (the biggest, `rec_order`, is at most 255
// bytes). A file past this is not something the library wrote.
constexpr size_t MAX_BLOB_BYTES = 4096;

constexpr size_t MAX_KEY_LEN = 32;

std::string errno_str(const char* what, const std::string& path) {
    return std::string(what) + " " + path + ": " + std::strerror(errno);
}

// mkdir -p, creating each missing component 0700. An existing component
// is left as it is, except the leaf, which is forced to 0700 because it
// holds the private key.
bool make_dirs(const std::string& dir, std::string& err) {
    if (dir.empty()) {
        err = "state dir is empty";
        return false;
    }
    for (size_t pos = 1; pos <= dir.size(); ++pos) {
        if (pos != dir.size() && dir[pos] != '/') continue;
        std::string part = dir.substr(0, pos);
        if (::mkdir(part.c_str(), 0700) != 0 && errno != EEXIST) {
            err = errno_str("mkdir", part);
            return false;
        }
    }
    struct stat st{};
    if (::stat(dir.c_str(), &st) != 0) {
        err = errno_str("stat", dir);
        return false;
    }
    if (!S_ISDIR(st.st_mode)) {
        err = "state dir " + dir + " is not a directory";
        return false;
    }
    if (::chmod(dir.c_str(), 0700) != 0) {
        err = errno_str("chmod", dir);
        return false;
    }
    return true;
}

bool write_all(int fd, const uint8_t* data, size_t len) {
    while (len > 0) {
        ssize_t n = ::write(fd, data, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        data += n;
        len -= static_cast<size_t>(n);
    }
    return true;
}

}  // namespace

FilePersistence::FilePersistence(std::string dir) : dir_(std::move(dir)) {
    while (dir_.size() > 1 && dir_.back() == '/') dir_.pop_back();
}

FilePersistence::~FilePersistence() {
    if (dir_fd_ >= 0) ::close(dir_fd_);
}

bool FilePersistence::init(std::string& err) {
    if (!make_dirs(dir_, err)) return false;
    dir_fd_ = ::open(dir_.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir_fd_ < 0) {
        err = errno_str("open", dir_);
        return false;
    }
    return true;
}

bool FilePersistence::valid_key(const std::string& key) {
    if (key.empty() || key.size() > MAX_KEY_LEN) return false;
    for (char c : key) {
        bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
        if (!ok) return false;
    }
    return true;
}

std::string FilePersistence::path_for(const std::string& key) const {
    return dir_ + "/" + key;
}

std::optional<std::vector<uint8_t>> FilePersistence::load_blob(const std::string& key) {
    if (key == sendspin::persistence_keys::OUTPUT_DELAY) return std::nullopt;
    if (!valid_key(key)) {
        std::fprintf(stderr, "sendspin_player: refusing persistence key '%s'\n", key.c_str());
        return std::nullopt;
    }
    const std::string path = path_for(key);
    const bool is_keypair = key == sendspin::persistence_keys::KEYPAIR;
    int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (errno != ENOENT) {
            std::fprintf(stderr, "sendspin_player: %s\n", errno_str("open", path).c_str());
            if (is_keypair) keypair_load_failed_ = true;
        }
        return std::nullopt;
    }
    std::vector<uint8_t> out;
    uint8_t buf[512];
    bool ok = true;
    for (;;) {
        ssize_t n = ::read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            std::fprintf(stderr, "sendspin_player: %s\n", errno_str("read", path).c_str());
            if (is_keypair) keypair_load_failed_ = true;
            ok = false;
            break;
        }
        if (n == 0) break;
        out.insert(out.end(), buf, buf + n);
        if (out.size() > MAX_BLOB_BYTES) {
            std::fprintf(stderr, "sendspin_player: %s exceeds %zu bytes, ignoring\n",
                         path.c_str(), MAX_BLOB_BYTES);
            ok = false;
            break;
        }
    }
    ::close(fd);
    if (!ok) return std::nullopt;
    return out;
}

bool FilePersistence::save_blob(const std::string& key, const uint8_t* data, size_t len) {
    // Accepted and dropped: the BEAM side owns the output delay (see the
    // header comment).
    if (key == sendspin::persistence_keys::OUTPUT_DELAY) return true;
    if (key != sendspin::persistence_keys::KEYPAIR) return write_blob(key, data, len);
    // A keypair file that exists but could not be read still holds the
    // identity; the library would replace it with the one it just minted.
    if (keypair_load_failed_) {
        std::fprintf(stderr, "sendspin_player: not overwriting unreadable %s\n",
                     path_for(key).c_str());
        keypair_save_failed_ = true;
        return false;
    }
    keypair_save_failed_ = !write_blob(key, data, len);
    return !keypair_save_failed_;
}

bool FilePersistence::write_file(const std::string& name, const std::string& data) {
    return write_blob(name, reinterpret_cast<const uint8_t*>(data.data()), data.size());
}

bool FilePersistence::write_blob(const std::string& key, const uint8_t* data, size_t len) {
    if (!valid_key(key) || dir_fd_ < 0) {
        std::fprintf(stderr, "sendspin_player: refusing persistence key '%s'\n", key.c_str());
        return false;
    }
    const std::string path = path_for(key);
    const std::string tmp = dir_ + "/." + key + ".tmp";

    int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) {
        std::fprintf(stderr, "sendspin_player: %s\n", errno_str("open", tmp).c_str());
        return false;
    }
    bool ok = write_all(fd, data, len) && ::fsync(fd) == 0;
    if (!ok) std::fprintf(stderr, "sendspin_player: %s\n", errno_str("write", tmp).c_str());
    if (::close(fd) != 0 && ok) {
        std::fprintf(stderr, "sendspin_player: %s\n", errno_str("close", tmp).c_str());
        ok = false;
    }
    if (ok && ::rename(tmp.c_str(), path.c_str()) != 0) {
        std::fprintf(stderr, "sendspin_player: %s\n", errno_str("rename", tmp).c_str());
        ok = false;
    }
    if (!ok) {
        ::unlink(tmp.c_str());
        return false;
    }
    // Make the rename itself durable before reporting the write accepted;
    // the library only calls commit() after pairing material, and writing
    // through here keeps every key equally safe.
    if (::fsync(dir_fd_) != 0) {
        std::fprintf(stderr, "sendspin_player: %s\n", errno_str("fsync", dir_).c_str());
        return false;
    }
    return true;
}
