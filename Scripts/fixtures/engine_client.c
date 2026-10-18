#include "iperf_config.h"
#include <assert.h>
#include "iperf.h"
#include "iperf_api.h"

int observed_test_end;
static int checked_send_state(struct iperf_test *test, signed char state);
#define iperf_set_send_state checked_send_state
#include "iperf_client_api.c"
#undef iperf_set_send_state

static int checked_send_state(struct iperf_test *test, signed char state)
{
    if (state == TEST_END) {
        /* Timers must be cancelled before waiting for the server's results,
         * not merely during final cleanup after the exchange. */
        assert(test->stats_timer == NULL && test->reporter_timer == NULL);
        observed_test_end = 1;
    }
    return iperf_set_send_state(test, state);
}

/* A stream that fails after its TCP connect never reaches test->streams, so
 * iperf_client_end() cannot close it. The server must see the connection end
 * rather than keep a half-open stream until the host process exits. */
void verify_client_stream_failure_closes_socket(void)
{
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t length = sizeof(address);
    assert(listener >= 0 && bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0 && getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    iperf_set_test_role(test, 'c');
    test->settings->domain = AF_INET;
    iperf_set_test_server_hostname(test, "127.0.0.1");
    iperf_set_test_server_port(test, ntohs(address.sin_port));
    /* Zero-length mmap fails after the stream has connected and sent its cookie. */
    test->settings->blksize = 0;
    iperf_set_error(IENONE);
    assert(iperf_create_streams(test, 1) == -1 && iperf_get_error() == IECREATESTREAM);
    int accepted = accept(listener, NULL, NULL);
    assert(accepted >= 0);
    struct timeval timeout = {.tv_sec = 5};
    assert(setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0);
    char cookie[COOKIE_SIZE], extra;
    assert(recv(accepted, cookie, sizeof(cookie), MSG_WAITALL) == sizeof(cookie));
    assert(recv(accepted, &extra, 1, 0) == 0);
    close(accepted);
    close(listener);
    iperf_free_test(test);
}
