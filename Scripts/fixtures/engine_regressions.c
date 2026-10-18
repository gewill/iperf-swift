#include "iperf_config.h"
#include <assert.h>
#include <stdlib.h>
#include "iperf.h"
#include "iperf_api.h"

void verify_remote_parameters(void);
void verify_stream_failure_cleanup(void);
void verify_watchdog_joins_before_free(void);
void verify_tcp_listener_option_failure_cleanup(void);
void verify_udp_invalid_stride(void);
void verify_udp_socket_option_failure_cleanup(void);
void verify_udp_first_reply_tos(void);

static int observed_finish;
extern int observed_test_end;
static void check_finished_timers(struct iperf_test *test)
{
    assert(test->stats_timer == NULL && test->reporter_timer == NULL);
    observed_finish = 1;
}

int main(int argc, char **argv)
{
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
    verify_tcp_listener_option_failure_cleanup();
    verify_udp_invalid_stride();
    verify_udp_socket_option_failure_cleanup();
    verify_udp_first_reply_tos();
    puts("PASS: remote parameters, FD cleanup, watchdog ownership, TCP/UDP failure cleanup, UDP stride and first-packet TOS");
    return 0;
}
