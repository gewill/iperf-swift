#ifndef IPERF_BOUNDED_OUTPUT_H
#define IPERF_BOUNDED_OUTPUT_H

#include <stddef.h>
#include <stdint.h>
#include "cjson.h"

/* Opt-in limits, independent of the logfile and of the measurement duration.
 * Core JSON allows ample headroom for MAX_STREAMS=128 and both directions.
 * The larger wire limit lets us discard optional output without losing core
 * statistics. It is not an allocation size. */
#define IPERF_OUTPUT_MAX_BYTES (1024U * 1024U)
#define IPERF_RESULT_CORE_MAX_BYTES (1024U * 1024U)
#define IPERF_RESULT_FRAME_MAX_BYTES 67108864U /* 64 MiB; also importable by Swift. */
#define IPERF_RESULT_MAX_DEPTH 64U
#define IPERF_RESULT_CORE_MAX_VALUES 16384U
#define IPERF_RESULT_MAX_VALUES 1048576U
#define IPERF_RESULT_READ_TIMEOUT_MS 30000U

enum iperf_output_state {
    IPERF_OUTPUT_MISSING,
    IPERF_OUTPUT_COMPLETE,
    IPERF_OUTPUT_TRUNCATED,
    IPERF_OUTPUT_DISCARDED,
    IPERF_OUTPUT_INVALID
};

enum iperf_output_format {
    IPERF_OUTPUT_NONE,
    IPERF_OUTPUT_TEXT,
    IPERF_OUTPUT_JSON
};

enum iperf_output_reason {
    IPERF_OUTPUT_REASON_NONE,
    IPERF_OUTPUT_BYTE_LIMIT,
    IPERF_OUTPUT_NODE_LIMIT,
    IPERF_OUTPUT_DEPTH_LIMIT,
    IPERF_OUTPUT_INVALID_DATA,
    IPERF_OUTPUT_ALLOCATION_FAILURE,
    IPERF_OUTPUT_READ_FAILURE
};

struct iperf_server_output {
    char *value;
    size_t length;
    uint64_t observed_bytes;
    enum iperf_output_state state;
    enum iperf_output_format format;
    enum iperf_output_reason reason;
    /* False when discarded JSON prevents knowing the complete encoded size. */
    int observed_bytes_complete;
};

struct iperf_result_read_metrics {
    uint64_t bytes_read;
    size_t core_json_bytes;
    size_t core_values;
    size_t maximum_depth;
    /* Requested heap capacity of the parser's byte buffers, excluding cJSON
     * nodes, allocator overhead and the fixed 4096-byte input buffer. */
    size_t peak_buffer_capacity;
};

/* Return 1...capacity bytes, zero for EOF, or -1 with errno. The callback must
 * implement its own absolute time limit and cancellation; a memory reader can
 * be used to test the same parser independently of socket scheduling. */
typedef int (*iperf_result_read_function)(void *context, unsigned char *bytes,
                                         size_t capacity);
typedef int (*iperf_result_cancel_function)(void *context);

/* Reads exactly one declared frame, never its next control-channel byte.
 * The returned tree contains core fields only, owned by the caller. Optional
 * output is separately owned by output and must be cleared by the caller.
 * output/metrics must be zero-initialized. On failure no partial output is
 * delivered; errno is EFBIG for a limit, EPROTO for invalid input, or the
 * reader/allocation error. A frame over the wire limit is rejected before read.
 * UTF-8 scalars and surrogate pairs are validated even in discarded output.
 * JSON output is compact, complete raw JSON, never a truncated JSON fragment. */
cJSON *iperf_read_bounded_results(uint32_t frame_length, size_t output_limit,
                                  iperf_result_read_function read_function,
                                  void *context,
                                  struct iperf_server_output *output,
                                  struct iperf_result_read_metrics *metrics);
void iperf_clear_server_output(struct iperf_server_output *output);

/* Engine-queue socket adapter, including the network-order 32-bit header.
 * timeout_ms is an absolute header+body deadline, in 1...30,000 ms. Cancellation
 * is polled at most every 100 ms while waiting and before each chunk. The caller
 * owns the socket and cancellation context; this function never closes the fd.
 * The engine-owned fd is temporarily nonblocking, with flags restored on exit;
 * no other thread may use or change it during this call.
 * On failure the caller must abandon the control connection, not attempt to
 * resume at an unknown frame boundary. metrics.bytes_read counts payload only.
 * Cancellation must represent explicit stop intent, not libiperf's normal
 * measurement-done flag, which is also set before successful result exchange. */
cJSON *iperf_read_bounded_results_socket(int fd, size_t output_limit,
                                         uint32_t timeout_ms,
                                         iperf_result_cancel_function cancelled,
                                         void *cancel_context,
                                         struct iperf_server_output *output,
                                         struct iperf_result_read_metrics *metrics);

/* Same absolute deadline/cancellation contract for a bounded serialized frame. */
int iperf_write_bounded_results_socket(int fd, const char *bytes, uint32_t length,
                                       uint32_t timeout_ms,
                                       iperf_result_cancel_function cancelled,
                                       void *cancel_context);

#endif
