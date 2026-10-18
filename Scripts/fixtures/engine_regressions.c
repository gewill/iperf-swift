#include "iperf_config.h"
#include <assert.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include "iperf.h"
#include "iperf_api.h"

void verify_remote_parameters(void);
void verify_stream_failure_cleanup(void);
void verify_entropy_under_descriptor_pressure(void);
void verify_watchdog_joins_before_free(void);
void verify_teardown_unblocks_zerocopy_sender(void);
void verify_released_stream_descriptors_stay_untouched(void);
void verify_client_stream_failure_closes_socket(void);
void verify_tcp_listener_option_failure_cleanup(void);
void verify_udp_invalid_stride(void);
void verify_udp_socket_option_failure_cleanup(void);
void verify_udp_first_reply_tos(void);

static int descriptors_below(int limit)
{
    int count = 0;
    for (int fd = 0; fd < limit; ++fd)
        if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

/* One server run as IperfRunner drives it, with `stream_slots` descriptors left
 * after the listener and control socket. Each stream holds its socket and its
 * buffer file, so an odd budget runs out in mkstemp() right after accept() and
 * an even one in the next accept(). Both must fail the run, not the process,
 * and leave no descriptor behind. */
static int serve_under_descriptor_pressure(int port, int stream_slots)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    iperf_set_test_role(test, 's');
    iperf_set_test_server_port(test, port);
    iperf_set_test_bind_address(test, "127.0.0.1");
    int baseline = descriptors_below(1024);
    struct rlimit limit;
    assert(getrlimit(RLIMIT_NOFILE, &limit) == 0);
    int cap = 3;
    while (cap - descriptors_below(cap) < stream_slots + 2)
        ++cap;
    limit.rlim_cur = cap;
    assert(setrlimit(RLIMIT_NOFILE, &limit) == 0);
    iperf_set_error(IENONE);
    assert(iperf_run_server(test) == -1);
    assert(iperf_get_error() == (stream_slots % 2 ? IECREATESTREAM : IESTREAMCONNECT));
    iperf_reset_test(test);
    assert(descriptors_below(1024) == baseline);
    iperf_free_test(test);
    printf("PASS: server with %d stream descriptors failed the run and kept none\n", stream_slots);
    return 0;
}

static int observed_finish;
extern int observed_test_end;
static void check_finished_timers(struct iperf_test *test)
{
    assert(test->stats_timer == NULL && test->reporter_timer == NULL);
    observed_finish = 1;
}

int main(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "server") == 0)
        return serve_under_descriptor_pressure(atoi(argv[3]), atoi(argv[2]));
    if (argc == 2) {
        struct iperf_test *test = iperf_new_test();
        assert(test && iperf_defaults(test) == 0);
        iperf_set_test_role(test, 'c');
        iperf_set_test_server_hostname(test, "127.0.0.1");
        iperf_set_test_server_port(test, atoi(argv[1]));
        iperf_set_test_duration(test, 1);
        iperf_set_test_num_streams(test, 3);
        iperf_set_test_bidirectional(test, 1);
        iperf_set_test_stats_interval(test, .1);
        iperf_set_test_reporter_interval(test, .1);
        test->on_test_finish = check_finished_timers;
        assert(iperf_run_client(test) == 0);
        assert(observed_test_end && observed_finish);
        struct iperf_stream *stream;
        SLIST_FOREACH(stream, &test->streams, streams)
            assert(stream->buffer_fd == -1);
        iperf_free_test(test);
        puts("PASS: parallel bidirectional TCP and periodic timer cancellation");
        return 0;
    }
    verify_remote_parameters();
    verify_stream_failure_cleanup();
    verify_watchdog_joins_before_free();
    verify_teardown_unblocks_zerocopy_sender();
    verify_released_stream_descriptors_stay_untouched();
    verify_client_stream_failure_closes_socket();
    verify_tcp_listener_option_failure_cleanup();
    verify_udp_invalid_stride();
    verify_udp_socket_option_failure_cleanup();
    verify_udp_first_reply_tos();
    verify_entropy_under_descriptor_pressure();
    puts("PASS: remote parameters, FD cleanup, watchdog ownership, zerocopy teardown, released stream descriptors, client stream failure, TCP/UDP failure cleanup, UDP stride, first-packet TOS and entropy under descriptor pressure");
    return 0;
}
