#pragma once

#include "sendspin/client.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// File-backed persistence provider
// ---------------------------------------------------------------------------
//
// Since sendspin-cpp v0.9.0 the player's identity is not configured: the
// library derives `client_id` from a static X25519 keypair it generates on
// first start and stores through a `SendspinPersistenceProvider`. Without a
// provider every respawn would mint a fresh identity, so this stores each
// library blob as one file under the per-output `--state-dir` the BEAM side
// hands us.
//
// The directory holds the private key, so it is created 0700 and every
// file 0600. Each save writes a temp file, fsyncs it and renames it over
// the old one, then fsyncs the directory, so a power cut leaves either the
// old blob or the new one and never a torn key. The library treats a blob
// of the wrong length as absent, so this stays a pure byte store and never
// interprets what it holds.
//
// The output delay key is deliberately not stored. The BEAM side already
// owns that value (persisted from the `static_delay` event and passed back
// as `--initial-static-delay-ms`), and a stored blob would take precedence
// over the CLI value, leaving two sources of truth.
class FilePersistence : public sendspin::SendspinPersistenceProvider {
public:
    explicit FilePersistence(std::string dir);
    ~FilePersistence() override;

    FilePersistence(const FilePersistence&) = delete;
    FilePersistence& operator=(const FilePersistence&) = delete;

    /// Create the directory (and any missing parents) and open it for the
    /// directory fsync. Must succeed before the provider is handed to the
    /// client. On failure `err` names the step and errno.
    bool init(std::string& err);

    std::optional<std::vector<uint8_t>> load_blob(const std::string& key) override;
    bool save_blob(const std::string& key, const uint8_t* data, size_t len) override;

    /// True if the most recent write of the identity keypair failed. The
    /// library only logs that failure and still starts, using a keypair the
    /// next launch will not find, so the caller checks this after start().
    /// A keypair file that exists but could not be read (open() failing
    /// with anything but ENOENT, or a read error) makes every later save of
    /// it fail without touching the file, so an unreadable identity is
    /// reported here rather than silently replaced.
    bool keypair_save_failed() const { return keypair_save_failed_; }

private:
    /// Library keys are short lowercase identifiers (`keypair`, `rec_0`,
    /// …). Anything else is refused rather than turned into a path.
    static bool valid_key(const std::string& key);
    std::string path_for(const std::string& key) const;

    bool write_blob(const std::string& key, const uint8_t* data, size_t len);

    std::string dir_;
    int dir_fd_ = -1;
    bool keypair_load_failed_ = false;
    bool keypair_save_failed_ = false;
};
