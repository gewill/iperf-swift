#ifndef IPERF_BOUNDED_LOG_H
#define IPERF_BOUNDED_LOG_H

#include <stdint.h>
#include <stdio.h>

/* Owned by the engine thread. Read only after the output FILE is closed. */
struct iperf_log_status {
    uint64_t limit;
    uint64_t bytes_written;
    uint64_t file_bytes;
    int attempted;
    int file_size_known;
    int truncated;
    int open_errno;
    int write_errno;
    int close_errno;
};

const char *iperf_log_truncation_marker(void);
uint64_t iperf_log_minimum_limit(void);
FILE *iperf_bounded_log_open(const char *path, struct iperf_log_status *status);

/* Takes ownership of sink, including on failure; NULL creates a discard sink.
 * status must outlive the returned FILE. Existing bytes are never rewritten.
 * Kept separate from opening a path to exercise real stdio failure behavior. */
FILE *iperf_bounded_log_wrap(FILE *sink, uint64_t existing_bytes,
                             struct iperf_log_status *status);

#endif
