#include "display_roles.h"

#include "json_out.h"

#include "sendspin/types.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <sstream>
#include <sys/stat.h>
#include <utility>

using namespace sendspin;

namespace {

// Per-field budget for server-supplied text. sanitize_text leaves only `"`
// and `\` to escape, so the five metadata strings stay under ~2.6 KB on a
// line even in the worst case — inside MAX_EMIT_LINE_BYTES.
constexpr size_t MAX_TEXT_BYTES = 256;
constexpr size_t MAX_ID_BYTES = 128;

constexpr uint32_t ARTWORK_MAX_IMAGE_BYTES = 256U * 1024U;
// RAM budget for held frames; about a seventh of it is wire data, which is
// several seconds of 64-bin spectrum at 30 Hz (the server sends ahead).
constexpr size_t VISUALIZER_BUFFER_BYTES = 128U * 1024U;

const char* command_name(SendspinControllerCommand c) {
    switch (c) {
        case SendspinControllerCommand::PLAY: return "play";
        case SendspinControllerCommand::PAUSE: return "pause";
        case SendspinControllerCommand::STOP: return "stop";
        case SendspinControllerCommand::NEXT: return "next";
        case SendspinControllerCommand::PREVIOUS: return "previous";
        case SendspinControllerCommand::VOLUME: return "volume";
        case SendspinControllerCommand::MUTE: return "mute";
        case SendspinControllerCommand::REPEAT_OFF: return "repeat_off";
        case SendspinControllerCommand::REPEAT_ONE: return "repeat_one";
        case SendspinControllerCommand::REPEAT_ALL: return "repeat_all";
        case SendspinControllerCommand::SHUFFLE: return "shuffle";
        case SendspinControllerCommand::UNSHUFFLE: return "unshuffle";
        case SendspinControllerCommand::SWITCH: return "switch";
        case SendspinControllerCommand::SEEK: return "seek";
        case SendspinControllerCommand::SEEK_RELATIVE: return "seek_relative";
    }
    return "unknown";
}

const char* repeat_name(SendspinRepeatMode r) {
    switch (r) {
        case SendspinRepeatMode::OFF: return "off";
        case SendspinRepeatMode::ONE: return "one";
        case SendspinRepeatMode::ALL: return "all";
    }
    return "off";
}

void put_text(std::ostringstream& os, const char* key, const std::optional<std::string>& v,
              size_t max_bytes) {
    if (!v) return;
    os << ",\"" << key << "\":\"" << json_escape(sanitize_text(*v, max_bytes)) << '"';
}

void put_rgb(std::ostringstream& os, const char* key, const std::optional<RgbColor>& v) {
    if (!v) return;
    os << ",\"" << key << "\":[" << static_cast<int>((*v)[0]) << ','
       << static_cast<int>((*v)[1]) << ',' << static_cast<int>((*v)[2]) << ']';
}

bool make_dir(const std::string& dir) {
    for (size_t pos = 1; pos <= dir.size(); ++pos) {
        if (pos != dir.size() && dir[pos] != '/') continue;
        std::string part = dir.substr(0, pos);
        if (::mkdir(part.c_str(), 0755) != 0 && errno != EEXIST) return false;
    }
    struct stat st{};
    return ::stat(dir.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

}  // namespace

DisplayRoles::DisplayRoles(DisplayRolesOptions opts) : opts_(std::move(opts)) {
    artwork_.opts = &opts_;
    visualizer_.opts = &opts_;
}

void DisplayRoles::attach(SendspinClient& client) {
    if (!opts_.enabled) return;

    metadata_.client = &client;
    client.add_metadata().set_listener(&metadata_);

    controller_ = &client.add_controller();
    controller_->set_listener(&controller_listener_);

    client.add_color().set_listener(&color_);

    if (!opts_.artwork_dir.empty()) {
        if (!make_dir(opts_.artwork_dir)) {
            std::fprintf(stderr, "Error: --artwork-dir %s: %s\n", opts_.artwork_dir.c_str(),
                         std::strerror(errno));
            emit_json("{\"event\":\"error\",\"kind\":\"artwork_dir\","
                      "\"msg\":\"failed to create the artwork dir\"}");
        }
        ArtworkRoleConfig cfg;
        ImageSlotPreference slot{};
        slot.source = SendspinImageSource::ALBUM;
        slot.format = SendspinImageFormat::JPEG;
        slot.width = static_cast<uint16_t>(opts_.artwork_width);
        slot.height = static_cast<uint16_t>(opts_.artwork_height);
        slot.max_image_bytes = ARTWORK_MAX_IMAGE_BYTES;
        slot.require_frame_done = true;
        cfg.preferred_formats = {slot};
        artwork_.store = std::make_unique<ArtworkStore>(
            opts_.artwork_dir, static_cast<size_t>(opts_.artwork_keep));
        artwork_.role = &client.add_artwork(std::move(cfg));
        artwork_.role->set_listener(&artwork_);
    }

    VisualizerRoleConfig viz;
    viz.support.buffer_capacity = VISUALIZER_BUFFER_BYTES;
    viz.stream.types = {VisualizerDataType::SPECTRUM, VisualizerDataType::LOUDNESS};
    viz.stream.rate_max = static_cast<uint16_t>(opts_.viz_rate);
    viz.stream.spectrum = VisualizerSpectrumConfig{
        .n_disp_bins = static_cast<uint8_t>(opts_.viz_bins),
        .scale = VisualizerSpectrumScale::MEL,
        .f_min = 40,
        .f_max = 16000,
    };
    viz.display_offset_ms = opts_.viz_offset_ms;
    client.add_visualizer(std::move(viz)).set_listener(&visualizer_);
}

void DisplayRoles::emit_group(const SendspinClient& client) const {
    if (!opts_.enabled) return;
    const auto& g = client.get_group_state();
    std::ostringstream os;
    os << "{\"event\":\"group\"";
    if (g.playback_state) {
        os << ",\"playback_state\":\""
           << (*g.playback_state == SendspinPlaybackState::PLAYING ? "playing" : "stopped")
           << '"';
    }
    put_text(os, "group_id", g.group_id, MAX_ID_BYTES);
    put_text(os, "group_name", g.group_name, MAX_ID_BYTES);
    os << '}';
    emit_json(os.str());
}

bool DisplayRoles::handle_command(const std::string& cmd, const std::string& kind, int int_val,
                                  bool bool_val) {
    if (!opts_.enabled) return false;

    if (cmd == "controller" && kind == "int") {
        // Only the parameterless transport commands; the int is the
        // SendspinControllerCommand value (PLAY=0 .. PREVIOUS=4).
        if (int_val < static_cast<int>(SendspinControllerCommand::PLAY) ||
            int_val > static_cast<int>(SendspinControllerCommand::PREVIOUS) ||
            controller_ == nullptr) {
            return true;
        }
        auto c = static_cast<SendspinControllerCommand>(int_val);
        bool ok = controller_->send_command({.command = c});
        std::ostringstream os;
        os << "{\"event\":\"controller_result\",\"command\":\"" << command_name(c)
           << "\",\"ok\":" << (ok ? "true" : "false") << '}';
        emit_json(os.str());
        return true;
    }

    if (cmd == "viz_enable" && kind == "bool") {
        visualizer_.enabled.store(bool_val);
        std::ostringstream os;
        os << "{\"event\":\"viz_enable\",\"value\":" << (bool_val ? "true" : "false") << '}';
        emit_json(os.str());
        return true;
    }

    return false;
}

// -- Metadata ---------------------------------------------------------------

std::string metadata_json(const ServerMetadataStateObject& m, int64_t progress_age_ms) {
    std::ostringstream os;
    os << "{\"event\":\"metadata\"";
    put_text(os, "title", m.title, MAX_TEXT_BYTES);
    put_text(os, "artist", m.artist, MAX_TEXT_BYTES);
    put_text(os, "album_artist", m.album_artist, MAX_TEXT_BYTES);
    put_text(os, "album", m.album, MAX_TEXT_BYTES);
    if (m.year) os << ",\"year\":" << *m.year;
    if (m.track) os << ",\"track\":" << *m.track;
    if (m.progress) {
        os << ",\"progress\":{\"track_progress\":" << m.progress->track_progress
           << ",\"track_duration\":" << m.progress->track_duration
           << ",\"playback_speed\":" << m.progress->playback_speed
           << ",\"progress_age_ms\":" << progress_age_ms << '}';
    }
    os << '}';
    return os.str();
}

// track_progress is the position at the server's `timestamp`. The library
// normally delivers the update on that timestamp, but one delivered late
// (or before time sync) is older; the age lets a consumer extrapolate from
// the right instant with playback_speed.
void DisplayRoles::Metadata::on_metadata(const ServerMetadataStateObject& m) {
    int64_t age_ms = 0;
    if (client != nullptr) {
        int64_t at = client->get_client_time(m.timestamp);
        if (at != 0) age_ms = std::max<int64_t>(0, (SendspinClient::now_us() - at) / 1000);
    }
    emit_json(metadata_json(m, age_ms));
}

void DisplayRoles::Metadata::on_metadata_clear() {
    emit_json("{\"event\":\"metadata_clear\"}");
}

// -- Controller -------------------------------------------------------------

void DisplayRoles::Controller::on_controller_state(const ServerStateControllerObject& s) {
    std::ostringstream os;
    os << "{\"event\":\"controller_state\",\"supported_commands\":[";
    bool first = true;
    for (auto c : s.supported_commands) {
        if (!first) os << ',';
        first = false;
        os << '"' << command_name(c) << '"';
    }
    os << "],\"volume\":" << static_cast<int>(s.volume)
       << ",\"muted\":" << (s.muted ? "true" : "false")
       << ",\"repeat\":\"" << repeat_name(s.repeat) << '"'
       << ",\"shuffle\":" << (s.shuffle ? "true" : "false");
    if (s.seek_max_ms) os << ",\"seek_max_ms\":" << *s.seek_max_ms;
    os << '}';
    emit_json(os.str());
}

void DisplayRoles::Controller::on_controller_state_clear() {
    emit_json("{\"event\":\"controller_clear\"}");
}

// -- Color ------------------------------------------------------------------

void DisplayRoles::Color::on_color(const ServerColorStateObject& c) {
    std::ostringstream os;
    os << "{\"event\":\"color\"";
    put_rgb(os, "background_dark", c.background_dark);
    put_rgb(os, "background_light", c.background_light);
    put_rgb(os, "primary", c.primary);
    put_rgb(os, "accent", c.accent);
    put_rgb(os, "on_dark", c.on_dark);
    put_rgb(os, "on_light", c.on_light);
    os << '}';
    emit_json(os.str());
}

void DisplayRoles::Color::on_color_clear() { emit_json("{\"event\":\"color_clear\"}"); }

// -- Artwork ----------------------------------------------------------------

// Decode thread. The bytes go to a content-named file; the event waits for
// on_image_display so it lands at the server's timestamp.
void DisplayRoles::Artwork::on_image_decode(uint8_t slot, const uint8_t* data, size_t length,
                                            SendspinImageFormat format) {
    store->stage(slot, data, length, format == SendspinImageFormat::PNG);
}

void DisplayRoles::Artwork::on_image_display(uint8_t slot, uint32_t lateness_ms) {
    ArtworkStore::Image img = store->take(slot);
    if (!img.valid) {
        // The image could not be written: drop whatever was shown rather
        // than leave the previous track's art up.
        emit_clear(slot);
    } else {
        std::ostringstream os;
        os << "{\"event\":\"artwork\",\"slot\":" << static_cast<int>(slot) << ",\"path\":\""
           << json_escape(img.path) << "\",\"format\":\"" << img.format
           << "\",\"width\":" << opts->artwork_width << ",\"height\":" << opts->artwork_height
           << ",\"bytes\":" << img.bytes << ",\"seq\":" << img.seq
           << ",\"lateness_ms\":" << lateness_ms << '}';
        emit_json(os.str());
    }
    // Presentation is instant (the BEAM takes it from here), so ack now.
    role->frame_done(slot);
}

void DisplayRoles::Artwork::on_image_clear(uint8_t slot) {
    emit_clear(slot);
    role->frame_done(slot);
}

void DisplayRoles::Artwork::emit_clear(uint8_t slot) {
    std::ostringstream os;
    os << "{\"event\":\"artwork_clear\",\"slot\":" << static_cast<int>(slot) << '}';
    emit_json(os.str());
}

// -- Visualizer -------------------------------------------------------------

// Drain thread. A frame is emitted only while the BEAM asked for frames
// (viz_enable); the role itself cannot be unsubscribed at runtime, since
// its stream config is fixed in client/state.
bool DisplayRoles::Visualizer::due(int64_t now_us) {
    // The server honours rate_max; this only guards against a burst (e.g.
    // a backlog drained at once) flooding the pipe.
    const int64_t min_gap_us = 500'000 / std::max(opts->viz_rate, 1);
    if (now_us - last_emit_us < min_gap_us) return false;
    last_emit_us = now_us;
    return true;
}

void DisplayRoles::Visualizer::emit_frame(int64_t client_timestamp,
                                          const std::vector<uint16_t>* bins) {
    const int64_t now = SendspinClient::now_us();
    if (!due(now)) return;

    std::ostringstream os;
    // Relative only: the client clock (CLOCK_MONOTONIC_RAW) is not the
    // BEAM's, so an absolute timestamp would be meaningless there.
    os << "{\"event\":\"viz\",\"lead_ms\":" << (client_timestamp - now) / 1000
       << ",\"loudness\":" << (loudness.load() >> 8) << ",\"bins\":[";
    if (bins != nullptr && !bins->empty()) {
        // Max-pool down to the requested bin count (the server already
        // sends that many; this only matters if it chose more), scaled to
        // 0-255 to keep the line short.
        const size_t in = bins->size();
        const size_t out = std::min(in, static_cast<size_t>(opts->viz_bins));
        for (size_t i = 0; i < out; i++) {
            size_t lo = i * in / out;
            size_t hi = std::max(lo + 1, (i + 1) * in / out);
            uint16_t v = *std::max_element(bins->begin() + static_cast<std::ptrdiff_t>(lo),
                                           bins->begin() + static_cast<std::ptrdiff_t>(hi));
            if (i != 0) os << ',';
            os << (v >> 8);
        }
    }
    os << "]}";
    emit_json(os.str());
}

void DisplayRoles::Visualizer::on_loudness(int64_t client_timestamp, uint16_t value) {
    loudness.store(value);
    // With spectrum, the spectrum frame carries the latest loudness.
    if (enabled.load() && !has_spectrum.load()) emit_frame(client_timestamp, nullptr);
}

void DisplayRoles::Visualizer::on_spectrum(int64_t client_timestamp,
                                           const std::vector<uint16_t>& bins) {
    if (enabled.load()) emit_frame(client_timestamp, &bins);
}

void DisplayRoles::Visualizer::on_visualizer_stream_start(const ServerVisualizerStreamObject& s) {
    has_spectrum.store(std::find(s.types.begin(), s.types.end(), VisualizerDataType::SPECTRUM) !=
                       s.types.end());
}

void DisplayRoles::Visualizer::on_visualizer_stream_end() {
    loudness.store(0);
    emit_json("{\"event\":\"viz_clear\"}");
}

void DisplayRoles::Visualizer::on_visualizer_stream_clear() {
    loudness.store(0);
    emit_json("{\"event\":\"viz_clear\"}");
}
