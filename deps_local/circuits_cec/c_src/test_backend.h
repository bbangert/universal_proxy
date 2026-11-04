// SPDX-FileCopyrightText: 2026 Ben Bangert
// SPDX-License-Identifier: Apache-2.0
//
// Stub "device" for the cec_port_test binary (built with
// -DCEC_PORT_TEST_BACKEND, never shipped). It lets the library's host tests
// drive the real framing, poll loop and exit paths without /dev/cecN.
//
// Device paths:
//   "test"      opens; queues the initial STATE_CHANGE like the kernel does
//   "test-hup"  opens, then reports HUP at once (adapter unregistered)
//   otherwise   ENOENT
//
// The fd is the read end of a pipe. Each queued message or event writes one
// byte to it, so poll() sees POLLIN for both; EVENT_POLL_BITS makes the main
// loop drain events on POLLIN too.

#define EVENT_POLL_BITS (POLLPRI | POLLIN)

#define TEST_QUEUE 32

static int test_pipe[2] = {-1, -1};
static struct cec_msg test_msgs[TEST_QUEUE];
static int test_nmsgs;
static struct cec_event test_events[TEST_QUEUE];
static int test_nevents;
static struct cec_log_addrs test_log_addrs;
static uint32_t test_mode;
static uint32_t test_sequence;
static const uint16_t test_phys_addr = 0x1000;

static void test_signal(void)
{
    uint8_t b = 1;
    if (write(test_pipe[1], &b, 1) != 1)
        _exit(EXIT_IO);
}

static void test_consume(void)
{
    uint8_t b;
    if (read(test_pipe[0], &b, 1) != 1)
        _exit(EXIT_IO);
}

static void test_queue_state_change(uint32_t flags)
{
    if (test_nevents == TEST_QUEUE)
        return;
    struct cec_event *ev = &test_events[test_nevents++];
    memset(ev, 0, sizeof(*ev));
    ev->event = CEC_EVENT_STATE_CHANGE;
    ev->flags = flags;
    ev->state_change.phys_addr = test_phys_addr;
    ev->state_change.log_addr_mask = test_log_addrs.log_addr_mask;
    ev->state_change.have_conn_info = 1;
    test_signal();
}

static int dev_open(const char *path)
{
    int hup = strcmp(path, "test-hup") == 0;
    if (!hup && strcmp(path, "test") != 0) {
        errno = ENOENT;
        return -1;
    }
    if (pipe2(test_pipe, O_NONBLOCK | O_CLOEXEC) < 0)
        return -1;

    memset(test_log_addrs.log_addr, CEC_LOG_ADDR_INVALID, sizeof(test_log_addrs.log_addr));
    if (hup) {
        close(test_pipe[1]);
        test_pipe[1] = -1;
    } else {
        test_queue_state_change(CEC_EVENT_FL_INITIAL_STATE);
    }
    return test_pipe[0];
}

static int test_mode_valid(uint32_t mode)
{
    uint32_t follower = mode & CEC_MODE_FOLLOWER_MSK;
    if ((mode & ~(CEC_MODE_INITIATOR_MSK | CEC_MODE_FOLLOWER_MSK)) != 0)
        return 0;
    if ((mode & CEC_MODE_INITIATOR_MSK) > CEC_MODE_EXCL_INITIATOR)
        return 0;
    return follower <= CEC_MODE_EXCL_FOLLOWER_PASSTHRU || follower >= CEC_MODE_MONITOR_PIN;
}

static int dev_ioctl(int fd, unsigned long request, void *arg)
{
    (void) fd;

    switch (request) {
    case CEC_ADAP_G_CAPS: {
        struct cec_caps *caps = arg;
        strcpy(caps->driver, "cec_port_test");
        strcpy(caps->name, "test adapter");
        caps->available_log_addrs = 1;
        caps->capabilities = CEC_CAP_LOG_ADDRS | CEC_CAP_TRANSMIT | CEC_CAP_PASSTHROUGH |
                             CEC_CAP_RC | CEC_CAP_CONNECTOR_INFO;
        caps->version = 0x061200;
        return 0;
    }
    case CEC_ADAP_G_PHYS_ADDR:
        *(uint16_t *) arg = test_phys_addr;
        return 0;
    case CEC_ADAP_G_LOG_ADDRS:
        memcpy(arg, &test_log_addrs, sizeof(test_log_addrs));
        return 0;
    case CEC_ADAP_S_LOG_ADDRS: {
        struct cec_log_addrs *las = arg;
        if (las->num_log_addrs > 1) {
            errno = EINVAL;
            return -1;
        }
        memset(las->log_addr, CEC_LOG_ADDR_INVALID, sizeof(las->log_addr));
        las->log_addr_mask = 0;
        if (las->num_log_addrs == 1) {
            las->log_addr[0] = CEC_LOG_ADDR_PLAYBACK_1;
            las->log_addr_mask = 1 << CEC_LOG_ADDR_PLAYBACK_1;
        }
        memcpy(&test_log_addrs, las, sizeof(test_log_addrs));
        test_queue_state_change(0);
        return 0;
    }
    case CEC_G_MODE:
        *(uint32_t *) arg = test_mode;
        return 0;
    case CEC_S_MODE: {
        uint32_t mode = *(uint32_t *) arg;
        if (!test_mode_valid(mode)) {
            errno = EINVAL;
            return -1;
        }
        test_mode = mode;
        return 0;
    }
    case CEC_TRANSMIT: {
        struct cec_msg *msg = arg;
        if (msg->len < 1 || msg->len > CEC_MAX_MSG_SIZE) {
            errno = EINVAL;
            return -1;
        }
        msg->sequence = ++test_sequence;
        if (test_nmsgs < TEST_QUEUE) {
            struct cec_msg *res = &test_msgs[test_nmsgs++];
            *res = *msg;
            res->tx_status = CEC_TX_STATUS_OK;
            test_signal();
        }
        return 0;
    }
    case CEC_RECEIVE:
        if (test_nmsgs == 0) {
            errno = EAGAIN;
            return -1;
        }
        memcpy(arg, &test_msgs[0], sizeof(struct cec_msg));
        memmove(&test_msgs[0], &test_msgs[1], (size_t) --test_nmsgs * sizeof(struct cec_msg));
        test_consume();
        return 0;
    case CEC_DQEVENT:
        if (test_nevents == 0) {
            errno = EAGAIN;
            return -1;
        }
        memcpy(arg, &test_events[0], sizeof(struct cec_event));
        memmove(&test_events[0], &test_events[1],
                (size_t) --test_nevents * sizeof(struct cec_event));
        test_consume();
        return 0;
    case CEC_ADAP_G_CONNECTOR_INFO: {
        struct cec_connector_info *conn = arg;
        conn->type = CEC_CONNECTOR_TYPE_DRM;
        conn->drm.card_no = 0;
        conn->drm.connector_id = 32;
        return 0;
    }
    default:
        errno = ENOTTY;
        return -1;
    }
}
