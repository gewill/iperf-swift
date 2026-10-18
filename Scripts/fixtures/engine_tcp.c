#include "iperf_config.h"
#include <assert.h>
#include <fcntl.h>
#include "iperf.h"
#include "iperf_api.h"

static int fail_socket_options;
static int injected_sockopts(struct iperf_test *test, int socket);
#define iperf_common_sockopts injected_sockopts
#include "iperf_tcp.c"
#undef iperf_common_sockopts

static int injected_sockopts(struct iperf_test *test, int socket)
{
    if (fail_socket_options) {
        iperf_set_error(IESETTOS);
        errno = EINVAL;
        return -1;
    }
    return iperf_common_sockopts(test, socket);
}

void verify_tcp_listener_option_failure_cleanup(void)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    iperf_set_test_role(test, 's');
    test->listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(test->listener >= 0);
    int listener = test->listener;
    /* Both fields can refer to the same socket. Cleanup must clear both so a
     * later free cannot close an unrelated FD that reuses this descriptor. */
    test->prot_listener = listener;
    fail_socket_options = 1;
    assert(iperf_tcp_listen(test) == -1);
    assert(iperf_get_error() == IESETTOS && errno == EINVAL);
    assert(test->listener == -1 && test->prot_listener == -1);
    assert(fcntl(listener, F_GETFD) == -1 && errno == EBADF);
    int replacement = open("/dev/null", O_RDONLY);
    assert(replacement >= 0);
    assert(dup2(replacement, listener) == listener);
    iperf_free_test(test);
    assert(fcntl(listener, F_GETFD) >= 0);
    if (replacement != listener) close(replacement);
    close(listener);
    fail_socket_options = 0;
}
