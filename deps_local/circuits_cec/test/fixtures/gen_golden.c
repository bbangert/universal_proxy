// SPDX-FileCopyrightText: 2026 Ben Bangert
// SPDX-License-Identifier: Apache-2.0
//
// Generates test/fixtures/golden.txt: kernel CEC structs built in C with the
// vendored header and the kernel's own cec-funcs.h message builders, so the
// Elixir codecs are checked against what the compiler lays out rather than
// against hand-written bytes. Replace or extend with structs captured from
// real hardware when available.
//
//   cc -std=c11 -I c_src -o /tmp/gen_golden test/fixtures/gen_golden.c
//   /tmp/gen_golden > test/fixtures/golden.txt
//
// cec-funcs.h comes from the system's kernel headers (linux-libc-dev);
// -I c_src makes it pick up the vendored linux/cec.h.

#include <stdio.h>
#include <string.h>

#include <linux/cec.h>
#include <linux/cec-funcs.h>

static void dump(const char *name, const void *p, size_t len)
{
    const unsigned char *b = p;
    printf("%s ", name);
    for (size_t i = 0; i < len; i++)
        printf("%02x", b[i]);
    printf("\n");
}

int main(void)
{
    struct cec_msg msg;

    // Transmit requests, as the adapter will build them.
    cec_msg_init(&msg, CEC_LOG_ADDR_PLAYBACK_1, CEC_LOG_ADDR_BROADCAST);
    cec_msg_active_source(&msg, 0x1000);
    dump("msg_tx_active_source", &msg, sizeof(msg));

    cec_msg_init(&msg, CEC_LOG_ADDR_PLAYBACK_1, CEC_LOG_ADDR_TV);
    cec_msg_give_device_power_status(&msg, 1);
    msg.timeout = 1000;
    dump("msg_tx_give_device_power_status", &msg, sizeof(msg));

    cec_msg_init(&msg, CEC_LOG_ADDR_UNREGISTERED, CEC_LOG_ADDR_TV);
    cec_msg_image_view_on(&msg);
    dump("msg_tx_image_view_on_unregistered", &msg, sizeof(msg));

    // Received: transmit result (sequence set, tx_status set, rx_status 0).
    cec_msg_init(&msg, CEC_LOG_ADDR_PLAYBACK_1, CEC_LOG_ADDR_TV);
    cec_msg_image_view_on(&msg);
    msg.sequence = 7;
    msg.tx_ts = 123456789012ULL;
    msg.tx_status = CEC_TX_STATUS_OK;
    dump("msg_rx_tx_result_ok", &msg, sizeof(msg));

    // Received: transmit result that nobody acked.
    cec_msg_init(&msg, CEC_LOG_ADDR_PLAYBACK_1, CEC_LOG_ADDR_AUDIOSYSTEM);
    cec_msg_give_audio_status(&msg, 1);
    msg.sequence = 8;
    msg.tx_status = CEC_TX_STATUS_NACK | CEC_TX_STATUS_MAX_RETRIES;
    msg.tx_nack_cnt = 2;
    dump("msg_rx_tx_result_nack", &msg, sizeof(msg));

    // Received: reply to a request (sequence set, tx_status 0, rx_status set).
    cec_msg_init(&msg, CEC_LOG_ADDR_TV, CEC_LOG_ADDR_PLAYBACK_1);
    cec_msg_report_power_status(&msg, CEC_OP_POWER_STATUS_STANDBY);
    msg.sequence = 7;
    msg.rx_ts = 223456789012ULL;
    msg.rx_status = CEC_RX_STATUS_OK;
    dump("msg_rx_reply_report_power_status", &msg, sizeof(msg));

    // Received: the request was answered with <Feature Abort>.
    cec_msg_init(&msg, CEC_LOG_ADDR_AUDIOSYSTEM, CEC_LOG_ADDR_PLAYBACK_1);
    cec_msg_feature_abort(&msg, CEC_MSG_GIVE_AUDIO_STATUS, CEC_OP_ABORT_REFUSED);
    msg.sequence = 9;
    msg.rx_status = CEC_RX_STATUS_OK | CEC_RX_STATUS_FEATURE_ABORT;
    dump("msg_rx_reply_feature_abort", &msg, sizeof(msg));

    // Received: unsolicited broadcast.
    cec_msg_init(&msg, CEC_LOG_ADDR_TV, CEC_LOG_ADDR_BROADCAST);
    cec_msg_standby(&msg);
    msg.rx_ts = 323456789012ULL;
    msg.rx_status = CEC_RX_STATUS_OK;
    dump("msg_rx_unsolicited_standby", &msg, sizeof(msg));

    struct cec_log_addrs las;
    memset(&las, 0, sizeof(las));
    memset(las.log_addr, CEC_LOG_ADDR_INVALID, sizeof(las.log_addr));
    dump("log_addrs_empty", &las, sizeof(las));

    memset(&las, 0, sizeof(las));
    memset(las.log_addr, CEC_LOG_ADDR_INVALID, sizeof(las.log_addr));
    las.log_addr[0] = CEC_LOG_ADDR_PLAYBACK_1;
    las.log_addr_mask = CEC_LOG_ADDR_MASK_PLAYBACK & (1 << CEC_LOG_ADDR_PLAYBACK_1);
    las.cec_version = CEC_OP_CEC_VERSION_1_4;
    las.num_log_addrs = 1;
    las.vendor_id = CEC_VENDOR_ID_NONE;
    las.flags = CEC_LOG_ADDRS_FL_ALLOW_UNREG_FALLBACK;
    strcpy(las.osd_name, "Universal Prox");
    las.primary_device_type[0] = CEC_OP_PRIM_DEVTYPE_PLAYBACK;
    las.log_addr_type[0] = CEC_LOG_ADDR_TYPE_PLAYBACK;
    las.all_device_types[0] = CEC_OP_ALL_DEVTYPE_PLAYBACK;
    dump("log_addrs_playback", &las, sizeof(las));

    struct cec_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.ts = 1000000000ULL;
    ev.event = CEC_EVENT_STATE_CHANGE;
    ev.flags = CEC_EVENT_FL_INITIAL_STATE;
    ev.state_change.phys_addr = 0x1000;
    ev.state_change.log_addr_mask = 1 << CEC_LOG_ADDR_PLAYBACK_1;
    ev.state_change.have_conn_info = 1;
    dump("event_state_change_initial", &ev, sizeof(ev));

    memset(&ev, 0, sizeof(ev));
    ev.ts = 2000000000ULL;
    ev.event = CEC_EVENT_STATE_CHANGE;
    ev.state_change.phys_addr = CEC_PHYS_ADDR_INVALID;
    dump("event_state_change_unplugged", &ev, sizeof(ev));

    memset(&ev, 0, sizeof(ev));
    ev.ts = 3000000000ULL;
    ev.event = CEC_EVENT_LOST_MSGS;
    ev.flags = CEC_EVENT_FL_DROPPED_EVENTS;
    ev.lost_msgs.lost_msgs = 5;
    dump("event_lost_msgs", &ev, sizeof(ev));

    struct cec_caps caps;
    memset(&caps, 0, sizeof(caps));
    strcpy(caps.driver, "vc4_hdmi");
    strcpy(caps.name, "vc4-hdmi");
    caps.available_log_addrs = 1;
    caps.capabilities = CEC_CAP_LOG_ADDRS | CEC_CAP_TRANSMIT | CEC_CAP_PASSTHROUGH | CEC_CAP_RC |
                        CEC_CAP_CONNECTOR_INFO;
    caps.version = (6 << 16) | (18 << 8);
    dump("caps_vc4", &caps, sizeof(caps));

    struct cec_connector_info conn;
    memset(&conn, 0, sizeof(conn));
    conn.type = CEC_CONNECTOR_TYPE_DRM;
    conn.drm.card_no = 1;
    conn.drm.connector_id = 32;
    dump("connector_info_drm", &conn, sizeof(conn));

    return 0;
}
