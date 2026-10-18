#include "iperf_config.h"
#include <assert.h>
#include "iperf.h"
#include "iperf_api.h"
#include "net.h"

static int fail_socket_options;
static int inject_datagram;
static int injected_sockopts(struct iperf_test *test, int socket);
static int injected_receive(int fd, char *buffer, size_t size, int protocol, int options);
#define iperf_common_sockopts injected_sockopts
#define Nrecv_no_select injected_receive
#include "iperf_udp.c"
#undef iperf_common_sockopts
#undef Nrecv_no_select

static int injected_receive(int fd, char *buffer, size_t size, int protocol, int options)
{
    /* Force a received header with an invalid negotiated stride. Without the
     * 3.22 guard, zero loops forever and a negative stride walks the buffer. */
    if (inject_datagram) return 16;
    return Nrecv_no_select(fd, buffer, size, protocol, options);
}

void verify_udp_invalid_stride(void)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    char buffer[16] = {0};
    struct iperf_stream_result result = {0};
    struct iperf_stream stream = {.test = test, .settings = test->settings,
                                 .buffer = buffer, .result = &result};
    __atomic_store_n(&test->state, TEST_RUNNING, __ATOMIC_SEQ_CST);
    inject_datagram = 1;
    for (int stride = -1; stride <= 0; ++stride) {
        test->settings->blksize = stride;
        assert(iperf_udp_recv(&stream) == -1);
        assert(result.bytes_received == 0 && stream.packet_count == 0);
    }
    inject_datagram = 0;
    iperf_free_test(test);
}

static int injected_sockopts(struct iperf_test *test, int socket)
{
    if (fail_socket_options) {
        iperf_set_error(IESETTOS);
        errno = EINVAL;
        return -1;
    }
    return iperf_common_sockopts(test, socket);
}

static int bound_udp(struct sockaddr_in *address)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);
    *address = (struct sockaddr_in){.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(bind(fd, (struct sockaddr *)address, sizeof(*address)) == 0);
    socklen_t length = sizeof(*address);
    assert(getsockname(fd, (struct sockaddr *)address, &length) == 0);
    return fd;
}

void verify_udp_socket_option_failure_cleanup(void)
{
    struct sockaddr_in server, client;
    int peer = bound_udp(&server);
    int reservation = bound_udp(&client);
    close(reservation);
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    iperf_set_test_role(test, 'c');
    test->settings->domain = AF_INET;
    iperf_set_test_server_hostname(test, "127.0.0.1");
    iperf_set_test_bind_address(test, "127.0.0.1");
    iperf_set_test_server_port(test, ntohs(server.sin_port));
    iperf_set_test_bind_port(test, ntohs(client.sin_port));
    iperf_set_test_blksize(test, 1400);
    fail_socket_options = 1;
    assert(iperf_udp_connect(test) == -1);
    assert(iperf_get_error() == IESETTOS && errno == EINVAL);
    int rebound = socket(AF_INET, SOCK_DGRAM, 0);
    assert(bind(rebound, (struct sockaddr *)&client, sizeof(client)) == 0);
    close(rebound); close(peer);
    fail_socket_options = 0;
    iperf_free_test(test);
}

void verify_udp_first_reply_tos(void)
{
    struct sockaddr_in server, client;
    int listener = bound_udp(&server), peer = bound_udp(&client);
    int yes = 1;
    assert(setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) == 0);
    assert(setsockopt(peer, IPPROTO_IP, IP_RECVTOS, &yes, sizeof(yes)) == 0);
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    test->settings->domain = AF_INET;
    iperf_set_test_role(test, 's');
    iperf_set_test_bind_address(test, "127.0.0.1");
    test->server_port = ntohs(server.sin_port);
    test->settings->blksize = 1400;
    test->settings->tos = 46 << 2;
    test->prot_listener = listener;
    unsigned int message = UDP_CONNECT_MSG;
    assert(sendto(peer, &message, sizeof(message), 0, (struct sockaddr *)&server, sizeof(server)) == sizeof(message));
    int accepted = iperf_udp_accept(test);
    assert(accepted == listener);
    union { struct cmsghdr alignment; char bytes[128]; } control;
    struct iovec vector = {&message, sizeof(message)};
    struct msghdr header = {.msg_iov = &vector, .msg_iovlen = 1,
                           .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes)};
    assert(recvmsg(peer, &header, 0) == sizeof(message));
    assert(message == UDP_CONNECT_REPLY);
    int tos = -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&header); c; c = CMSG_NXTHDR(&header, c))
        if (c->cmsg_level == IPPROTO_IP && c->cmsg_type == IP_RECVTOS)
            tos = *(unsigned char *)CMSG_DATA(c);
    assert(tos == (46 << 2));
    close(accepted); close(test->prot_listener); close(peer);
    test->prot_listener = -1;
    iperf_free_test(test);
}
