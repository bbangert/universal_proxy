#include "stderr_capture.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>

namespace md {

namespace {

std::atomic<int> g_log_fd{2};

constexpr std::string_view MARKER_PREFIX = "\x1emilkdrop-sync ";

bool starts_with(std::string_view s, std::string_view p) { return s.substr(0, p.size()) == p; }

}  // namespace

void set_log_fd(int fd) { g_log_fd.store(fd); }

void log_msg(const char* fmt, ...) {
    char buf[1024];
    int n = std::snprintf(buf, sizeof(buf), "milkdrop_renderer: ");
    va_list args;
    va_start(args, fmt);
    int m = std::vsnprintf(buf + n, sizeof(buf) - static_cast<size_t>(n) - 1, fmt, args);
    va_end(args);
    size_t len = static_cast<size_t>(n) + (m < 0 ? 0 : std::min<size_t>(static_cast<size_t>(m), sizeof(buf) - static_cast<size_t>(n) - 2));
    buf[len++] = '\n';
    ssize_t w = ::write(g_log_fd.load(), buf, len);
    (void)w;
}

std::string StderrClassifier::marker_line(uint64_t n) {
    return std::string(MARKER_PREFIX) + std::to_string(n) + "\n";
}

void StderrClassifier::finish_line(std::vector<StderrFinding>& out) {
    std::string_view l(line_);
    if (starts_with(l, MARKER_PREFIX)) {
        uint64_t n = 0;
        for (char c : l.substr(MARKER_PREFIX.size())) {
            if (c < '0' || c > '9') break;
            n = n * 10 + static_cast<uint64_t>(c - '0');
        }
        out.push_back({StderrFinding::Kind::Marker, {}, n});
    } else if (l.find("Failed to register allocate") != l.npos) {
        out.push_back({StderrFinding::Kind::RegisterAllocate, line_, 0});
    } else if (starts_with(l, "MESA: error") || starts_with(l, "MESA-LOADER") ||
               starts_with(l, "libEGL error") || starts_with(l, "libEGL fatal") ||
               starts_with(l, "EGL error")) {
        out.push_back({StderrFinding::Kind::DriverError, line_, 0});
    } else {
        discarded_ += line_.size() + 1;
    }
    line_.clear();
}

void StderrClassifier::feed(const char* data, size_t n, std::vector<StderrFinding>& out) {
    for (size_t i = 0; i < n; i++) {
        char c = data[i];
        if (c == '\n') {
            finish_line(out);
            continue;
        }
        if (line_.size() < MAX_LINE) {
            line_ += c;
        } else {
            discarded_++;
        }
    }
}

bool StderrCapture::start() {
    int fds[2];
    if (::pipe2(fds, O_CLOEXEC) != 0) return false;
    int saved = ::fcntl(2, F_DUPFD_CLOEXEC, 3);
    if (saved < 0) {
        ::close(fds[0]);
        ::close(fds[1]);
        return false;
    }
    if (::dup2(fds[1], 2) < 0) {
        ::close(saved);
        ::close(fds[0]);
        ::close(fds[1]);
        return false;
    }
    ::close(fds[1]);
    read_fd_ = fds[0];
    log_fd_ = saved;
    set_log_fd(saved);
    thread_ = std::thread([this] { run(); });
    return true;
}

void StderrCapture::stop() {
    if (read_fd_ < 0) return;
    // Pointing fd 2 back at the original stderr closes the pipe's last
    // write end, so the reader sees EOF.
    ::dup2(log_fd_, 2);
    if (thread_.joinable()) thread_.join();
    ::close(read_fd_);
    read_fd_ = -1;
    set_log_fd(2);
    ::close(log_fd_);
    log_fd_ = -1;
}

void StderrCapture::run() {
    StderrClassifier classifier;
    std::vector<StderrFinding> found;
    char buf[16384];
    while (true) {
        ssize_t n = ::read(read_fd_, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        found.clear();
        classifier.feed(buf, static_cast<size_t>(n), found);
        discarded_.store(classifier.discarded_bytes());
        if (found.empty()) continue;
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& f : found) {
            switch (f.kind) {
                case StderrFinding::Kind::Marker:
                    if (f.marker > marker_seen_) marker_seen_ = f.marker;
                    break;
                case StderrFinding::Kind::RegisterAllocate:
                    ra_failures_++;
                    [[fallthrough]];
                case StderrFinding::Kind::DriverError:
                    if (findings_.size() < 64) findings_.push_back(std::move(f));
                    break;
            }
        }
        cv_.notify_all();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    marker_seen_ = UINT64_MAX;  // nothing more will come; release waiters
    cv_.notify_all();
}

bool StderrCapture::sync(int timeout_ms) {
    if (read_fd_ < 0) return true;
    uint64_t n;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        n = ++marker_sent_;
    }
    std::string line = StderrClassifier::marker_line(n);
    if (::write(2, line.data(), line.size()) != static_cast<ssize_t>(line.size())) return false;
    std::unique_lock<std::mutex> lock(mutex_);
    return cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return marker_seen_ >= n; });
}

std::vector<StderrFinding> StderrCapture::take_findings() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<StderrFinding> out(std::make_move_iterator(findings_.begin()),
                                   std::make_move_iterator(findings_.end()));
    findings_.clear();
    return out;
}

}  // namespace md
