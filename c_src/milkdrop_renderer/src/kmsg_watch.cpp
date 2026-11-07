#include "kmsg_watch.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace md {

namespace {
// /dev/kmsg fails a read with EINVAL when the buffer can't hold a record.
constexpr size_t READ_BUF = 8192;
constexpr int MAX_READS = 64;
constexpr size_t MAX_PARTIAL = 16384;
}  // namespace

bool is_gpu_reset(std::string_view line) { return line.find("Resetting GPU") != std::string_view::npos; }

std::string_view kmsg_message(std::string_view line) {
    const size_t semi = line.find(';');
    if (semi == std::string_view::npos) return line;
    // "prio,seq,usec,flags[,caller=...]" before the ';'.
    const std::string_view head = line.substr(0, semi);
    const size_t comma = head.find(',');
    if (comma == 0 || comma == std::string_view::npos ||
        head.substr(0, comma).find_first_not_of("0123456789") != std::string_view::npos)
        return line;
    return line.substr(semi + 1);
}

KmsgWatch::~KmsgWatch() { close(); }

bool KmsgWatch::open(const std::string& path, std::string& err) {
    close();
    fd_ = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd_ < 0) {
        err = path + ": " + std::strerror(errno);
        return false;
    }
    // Only what is logged from now on (/dev/kmsg: after the last record).
    ::lseek(fd_, 0, SEEK_END);
    return true;
}

void KmsgWatch::close() {
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
    partial_.clear();
}

int KmsgWatch::poll_resets(std::string* message) {
    if (fd_ < 0) return 0;
    int resets = 0;
    char buf[READ_BUF];
    for (int reads = 0; reads < MAX_READS; reads++) {
        const ssize_t n = ::read(fd_, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR || errno == EPIPE) continue;  // EPIPE: records overwritten; read on
            break;                                           // EAGAIN: nothing new
        }
        if (n == 0) break;  // a file at its end
        partial_.append(buf, static_cast<size_t>(n));
        size_t start = 0;
        for (size_t nl; (nl = partial_.find('\n', start)) != std::string::npos; start = nl + 1) {
            const std::string_view line(partial_.data() + start, nl - start);
            if (!is_gpu_reset(line)) continue;
            resets++;
            if (message != nullptr) *message = std::string(kmsg_message(line));
        }
        partial_.erase(0, start);
        if (partial_.size() > MAX_PARTIAL) partial_.clear();
    }
    return resets;
}

bool GpuResetThrottle::report(std::string_view preset, int64_t now_us) {
    const bool same_hang = seen_ && now_us - last_us_ < window_us_;
    seen_ = true;
    last_us_ = now_us;
    if (same_hang || reported_.find(preset) != reported_.end()) return false;
    reported_.emplace(preset);
    return true;
}

}  // namespace md
