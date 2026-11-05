// Display roles (metadata, controller, color, artwork, visualizer) for the
// one sendspin_player instance that drives the HDMI TV UI. Enabled only by
// --display-roles; without it nothing here is registered with the client
// and no display event is ever emitted.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "artwork_store.h"

#include "sendspin/client.h"
#include "sendspin/artwork_role.h"
#include "sendspin/color_role.h"
#include "sendspin/controller_role.h"
#include "sendspin/metadata_role.h"
#include "sendspin/visualizer_role.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>

struct DisplayRolesOptions {
    bool enabled = false;
    // Where decoded artwork is written as <sha256>.<jpg|png>. Empty = no
    // artwork role.
    std::string artwork_dir;
    int artwork_width = 480;
    int artwork_height = 480;
    // Displayed artwork files kept in artwork_dir; older ones are deleted.
    int artwork_keep = 8;
    int viz_bins = 32;
    int viz_rate = 20;
    // Visualizer callbacks fire this far ahead of each frame's display
    // time; it shows up as the frame's `lead_ms`.
    int viz_offset_ms = 0;
};

// The `metadata` event line. `progress_age_ms` is how long ago, on the
// client clock, the progress position held.
std::string metadata_json(const sendspin::ServerMetadataStateObject& m, int64_t progress_age_ms);

class DisplayRoles {
public:
    explicit DisplayRoles(DisplayRolesOptions opts);
    DisplayRoles(const DisplayRoles&) = delete;
    DisplayRoles& operator=(const DisplayRoles&) = delete;

    bool enabled() const { return opts_.enabled; }

    // Adds the roles to `client` and wires their listeners. Call before
    // client.start(). A no-op when not enabled.
    void attach(sendspin::SendspinClient& client);

    // Main loop: the client's group state changed.
    void emit_group(const sendspin::SendspinClient& client) const;

    // Handles the display stdin commands (`controller`, `viz_enable`).
    // Returns false for anything else, or when not enabled.
    bool handle_command(const std::string& cmd, const std::string& kind, int int_val,
                        bool bool_val);

private:
    struct Metadata : sendspin::MetadataRoleListener {
        const sendspin::SendspinClient* client = nullptr;
        void on_metadata(const sendspin::ServerMetadataStateObject& m) override;
        void on_metadata_clear() override;
    };

    struct Controller : sendspin::ControllerRoleListener {
        void on_controller_state(const sendspin::ServerStateControllerObject& s) override;
        void on_controller_state_clear() override;
    };

    struct Color : sendspin::ColorRoleListener {
        void on_color(const sendspin::ServerColorStateObject& c) override;
        void on_color_clear() override;
    };

    // Every slot is ack-gated (require_frame_done): the library holds the
    // next image's decode until the current delivery is acked, so a decode
    // can never overwrite the pending image between its display deadline
    // and the on_image_display() that reads it.
    struct Artwork : sendspin::ArtworkRoleListener {
        const DisplayRolesOptions* opts = nullptr;
        sendspin::ArtworkRole* role = nullptr;
        std::unique_ptr<ArtworkStore> store;

        void on_image_decode(uint8_t slot, const uint8_t* data, size_t length,
                             sendspin::SendspinImageFormat format) override;
        void on_image_display(uint8_t slot, uint32_t lateness_ms) override;
        void on_image_clear(uint8_t slot) override;
        void emit_clear(uint8_t slot);
    };

    struct Visualizer : sendspin::VisualizerRoleListener {
        const DisplayRolesOptions* opts = nullptr;
        std::atomic<bool> enabled{false};
        std::atomic<bool> has_spectrum{true};
        std::atomic<uint16_t> loudness{0};
        // Drain-thread only.
        int64_t last_emit_us = 0;

        void on_loudness(int64_t client_timestamp, uint16_t loudness) override;
        void on_spectrum(int64_t client_timestamp, const std::vector<uint16_t>& bins) override;
        void on_visualizer_stream_start(const sendspin::ServerVisualizerStreamObject& s) override;
        void on_visualizer_stream_end() override;
        void on_visualizer_stream_clear() override;

        bool due(int64_t now_us);
        void emit_frame(int64_t client_timestamp, const std::vector<uint16_t>* bins);
    };

    DisplayRolesOptions opts_;
    Metadata metadata_;
    Controller controller_listener_;
    Color color_;
    Artwork artwork_;
    Visualizer visualizer_;
    sendspin::ControllerRole* controller_ = nullptr;
};
