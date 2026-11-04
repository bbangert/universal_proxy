// SPDX-FileCopyrightText: 2026 Ben Bangert
// SPDX-License-Identifier: Apache-2.0
//
// cec_port: a dumb ioctl pump between an Erlang port and /dev/cecN.
//
// Usage: cec_port /dev/cecN
//
// It knows no CEC opcodes. Erlang sends raw kernel structs, the helper runs
// the ioctl and sends the struct back; everything else lives in Elixir.
//
// Framing is {:packet, 2}. Every frame is <<tag::8, req_id::16-big, body>>.
// Integers inside bodies (errno, u16 physical address, u32 mode) and the
// kernel structs are native byte order, which is little-endian on every
// supported target (asserted below).
//
// Requests (Erlang -> helper), each answered with OK or ERR and the same
// req_id:
//   0x01 caps                      OK <struct cec_caps>
//   0x02 g_phys                    OK <u16>
//   0x03 g_log                     OK <struct cec_log_addrs>
//   0x04 s_log <cec_log_addrs>     OK <struct cec_log_addrs>
//   0x05 g_mode                    OK <u32>
//   0x06 s_mode <u32>              OK <>
//   0x07 transmit <cec_msg>        OK <struct cec_msg> (sequence filled in)
//   0x08 g_conn                    OK <struct cec_connector_info>
//   0x80 OK <bytes>                0x81 ERR <errno::32>
//
// Unsolicited (helper -> Erlang, req_id 0):
//   0x90 ready <struct cec_caps>   device opened; sent once, first
//   0x91 open_error <errno::32>    then exit 1
//   0x92 msg <struct cec_msg>      CEC_RECEIVE
//   0x93 event <struct cec_event>  CEC_DQEVENT
//   0x94 gone                      adapter unregistered; then exit 0
//
// Exit status: 0 on stdin EOF or gone, 1 open failure, 2 protocol error,
// 3 I/O error on stdin/stdout.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <unistd.h>

#include "linux/cec.h"

// The Elixir codecs decode these layouts with fixed offsets. A header or ABI
// change has to fail the build on every target, not misparse at runtime.
_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "little-endian only");
_Static_assert(sizeof(struct cec_msg) == 56, "cec_msg size");
_Static_assert(offsetof(struct cec_msg, len) == 16, "cec_msg.len");
_Static_assert(offsetof(struct cec_msg, sequence) == 24, "cec_msg.sequence");
_Static_assert(offsetof(struct cec_msg, msg) == 32, "cec_msg.msg");
_Static_assert(offsetof(struct cec_msg, reply) == 48, "cec_msg.reply");
_Static_assert(offsetof(struct cec_msg, tx_error_cnt) == 54, "cec_msg.tx_error_cnt");
_Static_assert(sizeof(struct cec_log_addrs) == 92, "cec_log_addrs size");
_Static_assert(offsetof(struct cec_log_addrs, vendor_id) == 8, "cec_log_addrs.vendor_id");
_Static_assert(offsetof(struct cec_log_addrs, osd_name) == 16, "cec_log_addrs.osd_name");
_Static_assert(offsetof(struct cec_log_addrs, primary_device_type) == 31,
               "cec_log_addrs.primary_device_type");
_Static_assert(offsetof(struct cec_log_addrs, features) == 43, "cec_log_addrs.features");
_Static_assert(sizeof(struct cec_event) == 80, "cec_event size");
_Static_assert(offsetof(struct cec_event, state_change) == 16, "cec_event union");
_Static_assert(sizeof(struct cec_caps) == 76, "cec_caps size");
_Static_assert(offsetof(struct cec_caps, available_log_addrs) == 64, "cec_caps.available_log_addrs");
_Static_assert(sizeof(struct cec_connector_info) == 68, "cec_connector_info size");
_Static_assert(offsetof(struct cec_connector_info, drm) == 4, "cec_connector_info union");

enum {
    REQ_CAPS = 0x01,
    REQ_G_PHYS = 0x02,
    REQ_G_LOG = 0x03,
    REQ_S_LOG = 0x04,
    REQ_G_MODE = 0x05,
    REQ_S_MODE = 0x06,
    REQ_TRANSMIT = 0x07,
    REQ_G_CONN = 0x08,

    RSP_OK = 0x80,
    RSP_ERR = 0x81,

    EVT_READY = 0x90,
    EVT_OPEN_ERROR = 0x91,
    EVT_MSG = 0x92,
    EVT_EVENT = 0x93,
    EVT_GONE = 0x94,
};

enum { EXIT_OK = 0, EXIT_OPEN = 1, EXIT_PROTOCOL = 2, EXIT_IO = 3 };

#ifdef CEC_PORT_TEST_BACKEND
#include "test_backend.h"
#else
#define dev_open(path) open((path), O_RDWR | O_NONBLOCK | O_CLOEXEC)
#define dev_ioctl ioctl
// The kernel signals queued events with POLLPRI.
#define EVENT_POLL_BITS POLLPRI
#endif

// Largest request is s_log: 3 header bytes + 92.
#define MAX_FRAME 256
// Bound one drain pass so stdin stays responsive under a message flood.
#define MAX_DRAIN 64

static uint8_t inbuf[2 + MAX_FRAME];
static size_t inlen;

static void write_all(const uint8_t *buf, size_t len)
{
    while (len > 0) {
        ssize_t n = write(STDOUT_FILENO, buf, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            _exit(EXIT_IO);
        }
        buf += n;
        len -= (size_t) n;
    }
}

static void send_frame(uint8_t tag, uint16_t req_id, const void *body, size_t len)
{
    uint8_t frame[5 + MAX_FRAME];
    size_t total = 3 + len;

    frame[0] = (uint8_t) (total >> 8);
    frame[1] = (uint8_t) total;
    frame[2] = tag;
    frame[3] = (uint8_t) (req_id >> 8);
    frame[4] = (uint8_t) req_id;
    if (len > 0)
        memcpy(&frame[5], body, len);
    write_all(frame, 5 + len);
}

static void send_errno(uint8_t tag, uint16_t req_id, int err)
{
    uint32_t e = (uint32_t) err;
    send_frame(tag, req_id, &e, sizeof(e));
}

static int do_ioctl(int fd, unsigned long request, void *arg)
{
    int rc;
    do {
        rc = dev_ioctl(fd, request, arg);
    } while (rc < 0 && errno == EINTR);
    return rc;
}

// Run one ioctl and answer with the (possibly kernel-updated) argument.
static void ioctl_reply(int fd, uint16_t req_id, unsigned long request, void *arg,
                        size_t reply_len)
{
    if (do_ioctl(fd, request, arg) < 0)
        send_errno(RSP_ERR, req_id, errno);
    else
        send_frame(RSP_OK, req_id, arg, reply_len);
}

static void handle_request(int fd, uint8_t tag, uint16_t req_id, const uint8_t *body, size_t len)
{
    union {
        struct cec_caps caps;
        struct cec_log_addrs log_addrs;
        struct cec_msg msg;
        struct cec_connector_info conn;
        uint16_t phys_addr;
        uint32_t mode;
    } arg;
    size_t want;

    memset(&arg, 0, sizeof(arg));

    switch (tag) {
    case REQ_S_LOG:
        want = sizeof(arg.log_addrs);
        break;
    case REQ_S_MODE:
        want = sizeof(arg.mode);
        break;
    case REQ_TRANSMIT:
        want = sizeof(arg.msg);
        break;
    default:
        want = 0;
        break;
    }
    if (len != want) {
        send_errno(RSP_ERR, req_id, EINVAL);
        return;
    }
    if (len > 0)
        memcpy(&arg, body, len);

    switch (tag) {
    case REQ_CAPS:
        ioctl_reply(fd, req_id, CEC_ADAP_G_CAPS, &arg.caps, sizeof(arg.caps));
        break;
    case REQ_G_PHYS:
        ioctl_reply(fd, req_id, CEC_ADAP_G_PHYS_ADDR, &arg.phys_addr, sizeof(arg.phys_addr));
        break;
    case REQ_G_LOG:
        ioctl_reply(fd, req_id, CEC_ADAP_G_LOG_ADDRS, &arg.log_addrs, sizeof(arg.log_addrs));
        break;
    case REQ_S_LOG:
        ioctl_reply(fd, req_id, CEC_ADAP_S_LOG_ADDRS, &arg.log_addrs, sizeof(arg.log_addrs));
        break;
    case REQ_G_MODE:
        ioctl_reply(fd, req_id, CEC_G_MODE, &arg.mode, sizeof(arg.mode));
        break;
    case REQ_S_MODE:
        ioctl_reply(fd, req_id, CEC_S_MODE, &arg.mode, 0);
        break;
    case REQ_TRANSMIT:
        ioctl_reply(fd, req_id, CEC_TRANSMIT, &arg.msg, sizeof(arg.msg));
        break;
    case REQ_G_CONN:
        ioctl_reply(fd, req_id, CEC_ADAP_G_CONNECTOR_INFO, &arg.conn, sizeof(arg.conn));
        break;
    default:
        send_errno(RSP_ERR, req_id, ENOSYS);
        break;
    }
}

// Read what stdin has and handle every complete frame. Exits on EOF.
static void process_stdin(int fd)
{
    ssize_t n;

    do {
        n = read(STDIN_FILENO, inbuf + inlen, sizeof(inbuf) - inlen);
    } while (n < 0 && errno == EINTR);

    if (n == 0)
        _exit(EXIT_OK); // The Erlang side closed the port.
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return;
        _exit(EXIT_IO);
    }
    inlen += (size_t) n;

    while (inlen >= 2) {
        size_t flen = ((size_t) inbuf[0] << 8) | inbuf[1];
        if (flen < 3 || flen > MAX_FRAME)
            _exit(EXIT_PROTOCOL);
        if (inlen < 2 + flen)
            break;

        uint16_t req_id = (uint16_t) ((inbuf[3] << 8) | inbuf[4]);
        handle_request(fd, inbuf[2], req_id, &inbuf[5], flen - 3);

        inlen -= 2 + flen;
        memmove(inbuf, inbuf + 2 + flen, inlen);
    }
}

// Forward queued structs until the kernel says EAGAIN. Returns -1 if the
// adapter went away.
static int drain(int fd, unsigned long request, uint8_t tag, size_t size)
{
    union {
        struct cec_msg msg;
        struct cec_event event;
    } buf;

    for (int i = 0; i < MAX_DRAIN; i++) {
        memset(&buf, 0, sizeof(buf));
        if (do_ioctl(fd, request, &buf) < 0) {
            if (errno == ENODEV)
                return -1;
            // EAGAIN means the queue is empty. Anything else is transient
            // from our point of view; poll() reports a dead adapter as HUP.
            return 0;
        }
        send_frame(tag, 0, &buf, size);
    }
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: cec_port /dev/cecN\n");
        return EXIT_PROTOCOL;
    }

    // Belt and braces: stdin EOF already ends us when the owner dies, but
    // die with the parent even if something keeps the pipe open.
    pid_t parent = getppid();
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) == 0 && getppid() != parent)
        return EXIT_OK;
    signal(SIGPIPE, SIG_IGN);

    int fd = dev_open(argv[1]);
    if (fd < 0) {
        send_errno(EVT_OPEN_ERROR, 0, errno);
        return EXIT_OPEN;
    }

    // G_CAPS doubles as the "is this really a CEC device" check (ENOTTY).
    struct cec_caps caps;
    memset(&caps, 0, sizeof(caps));
    if (do_ioctl(fd, CEC_ADAP_G_CAPS, &caps) < 0) {
        send_errno(EVT_OPEN_ERROR, 0, errno);
        return EXIT_OPEN;
    }
    send_frame(EVT_READY, 0, &caps, sizeof(caps));

    struct pollfd fds[2] = {
        {.fd = STDIN_FILENO, .events = POLLIN},
        {.fd = fd, .events = POLLIN | POLLPRI},
    };

    for (;;) {
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            return EXIT_IO;
        }

        short dev = fds[1].revents;
        if (dev & (POLLERR | POLLHUP | POLLNVAL)) {
            send_frame(EVT_GONE, 0, NULL, 0);
            return EXIT_OK;
        }
        if ((dev & EVENT_POLL_BITS) &&
            drain(fd, CEC_DQEVENT, EVT_EVENT, sizeof(struct cec_event)) < 0) {
            send_frame(EVT_GONE, 0, NULL, 0);
            return EXIT_OK;
        }
        if ((dev & POLLIN) && drain(fd, CEC_RECEIVE, EVT_MSG, sizeof(struct cec_msg)) < 0) {
            send_frame(EVT_GONE, 0, NULL, 0);
            return EXIT_OK;
        }

        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR))
            process_stdin(fd);
    }
}
