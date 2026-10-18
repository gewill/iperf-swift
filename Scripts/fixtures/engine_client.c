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
