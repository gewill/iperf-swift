#ifndef IPERF_OUTPUT_BUDGET_H
#define IPERF_OUTPUT_BUDGET_H
#include "iperf_bounded_output.h"
#include <stdarg.h>
struct iperf_test;

int iperf_set_test_server_output_byte_limit(struct iperf_test *test, size_t limit);
void iperf_output_budget_reset(struct iperf_test *test);
int iperf_output_stop_requested(void *test);
void iperf_output_collect_printf(struct iperf_test *test, const char *prefix,
                                  const char *format, va_list arguments);
void iperf_output_collect_interval(struct iperf_test *test, const cJSON *interval);
int iperf_output_add_server_results(struct iperf_test *test, cJSON *results);
void iperf_output_apply_peer_status(struct iperf_server_output *output, const cJSON *results);
int iperf_output_write_results(struct iperf_test *test, cJSON *results);
void iperf_output_get_local_status(struct iperf_test *test, struct iperf_server_output *status);
void iperf_output_print_received(struct iperf_test *test);
void iperf_output_add_received_json(struct iperf_test *test);
#endif
