#include "iperf_bounded_output.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>

struct socket_reader {
    int fd;
    uint64_t deadline_ns;
    iperf_result_cancel_function cancelled;
    void *cancel_context;
};

static int monotonic_ns(uint64_t *value)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    *value = (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
    return 1;
}

static int socket_read(void *context, unsigned char *bytes, size_t capacity)
{
    struct socket_reader *reader = context;
    for (;;) {
        uint64_t now;
        if (reader->cancelled && reader->cancelled(reader->cancel_context)) {
            errno = ECANCELED;
            return -1;
        }
        if (!monotonic_ns(&now)) return -1;
        if (now >= reader->deadline_ns) { errno = ETIMEDOUT; return -1; }
        uint64_t remaining_ms = (reader->deadline_ns - now + 999999) / 1000000;
        int wait_ms = remaining_ms < 100 ? (int)remaining_ms : 100;
        struct pollfd descriptor = { .fd = reader->fd, .events = POLLIN };
        int ready = poll(&descriptor, 1, wait_ms);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (!ready) continue;
        if (descriptor.revents & POLLNVAL) { errno = EBADF; return -1; }
        /* The adapter also sets O_NONBLOCK, so a readiness race cannot escape
         * the absolute deadline or cancellation checks. */
        ssize_t count = recv(reader->fd, bytes, capacity, MSG_DONTWAIT);
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        return (int)count;
    }
}

static cJSON *read_results_socket(int fd, size_t output_limit,
                                         uint32_t timeout_ms,
                                         iperf_result_cancel_function cancelled,
                                         void *cancel_context,
                                         struct iperf_server_output *output,
                                         struct iperf_result_read_metrics *metrics)
{
    if (!output || !metrics || !output_limit || output_limit > IPERF_OUTPUT_MAX_BYTES ||
        !timeout_ms || timeout_ms > IPERF_RESULT_READ_TIMEOUT_MS || fd < 0) {
        if (output) { output->state = IPERF_OUTPUT_INVALID; output->reason = IPERF_OUTPUT_READ_FAILURE; }
        errno = fd < 0 ? EBADF : EINVAL;
        return NULL;
    }
    struct socket_reader reader = { .fd = fd, .cancelled = cancelled, .cancel_context = cancel_context };
    uint64_t now;
    if (!monotonic_ns(&now)) {
        output->state = IPERF_OUTPUT_INVALID; output->reason = IPERF_OUTPUT_READ_FAILURE; return NULL;
    }
    reader.deadline_ns = now + (uint64_t)timeout_ms * 1000000;
    uint32_t header;
    size_t received = 0;
    while (received < sizeof(header)) {
        int count = socket_read(&reader, (unsigned char *)&header + received, sizeof(header) - received);
        if (count <= 0) {
            output->state = IPERF_OUTPUT_INVALID;
            output->reason = IPERF_OUTPUT_READ_FAILURE;
            if (!count) errno = EPROTO;
            return NULL;
        }
        received += (size_t)count;
    }
    return iperf_read_bounded_results(ntohl(header), output_limit, socket_read,
                                      &reader, output, metrics);
}

static int socket_write(struct socket_reader *writer, const char *bytes, size_t length)
{
    size_t sent = 0;
    while (sent < length) {
        uint64_t now;
        if (writer->cancelled && writer->cancelled(writer->cancel_context)) {
            errno = ECANCELED; return -1;
        }
        if (!monotonic_ns(&now)) return -1;
        if (now >= writer->deadline_ns) { errno = ETIMEDOUT; return -1; }
        uint64_t remaining_ms = (writer->deadline_ns - now + 999999) / 1000000;
        struct pollfd descriptor = { .fd = writer->fd, .events = POLLOUT };
        int ready = poll(&descriptor, 1, remaining_ms < 100 ? (int)remaining_ms : 100);
        if (ready < 0) { if (errno == EINTR) continue; return -1; }
        if (!ready) continue;
        if (descriptor.revents & POLLNVAL) { errno = EBADF; return -1; }
        int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
        flags |= MSG_NOSIGNAL;
#endif
        size_t chunk = length - sent < 4096 ? length - sent : 4096;
        ssize_t count = send(writer->fd, bytes + sent, chunk, flags);
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) continue;
        if (count <= 0) { if (!count) errno = EPIPE; return -1; }
        sent += (size_t)count;
    }
    return 0;
}

static int write_results_socket(int fd, const char *bytes, uint32_t length,
                                       uint32_t timeout_ms,
                                       iperf_result_cancel_function cancelled,
                                       void *cancel_context)
{
    if (fd < 0 || !bytes || !length || length > IPERF_RESULT_FRAME_MAX_BYTES ||
        !timeout_ms || timeout_ms > IPERF_RESULT_READ_TIMEOUT_MS) {
        errno = EINVAL; return -1;
    }
    struct socket_reader writer = { .fd = fd, .cancelled = cancelled, .cancel_context = cancel_context };
    uint64_t now;
    if (!monotonic_ns(&now)) return -1;
    writer.deadline_ns = now + (uint64_t)timeout_ms * 1000000;
    uint32_t header = htonl(length);
    if (socket_write(&writer, (char *)&header, sizeof(header))) return -1;
    return socket_write(&writer, bytes, length);
}

/* poll readiness and MSG_DONTWAIT alone did not prevent a large AF_UNIX send
 * from blocking on the tested Darwin runtime. Explicit nonblocking mode covers
 * the syscall itself; restore the engine-owned control fd before returning.
 * No other thread may use or change this fd during either adapter call. */
static int nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (!(flags & O_NONBLOCK) && fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return flags;
}

static int restore(int fd, int flags, int saved_errno)
{
    if (!(flags & O_NONBLOCK) && fcntl(fd, F_SETFL, flags) < 0) return -1;
    errno = saved_errno;
    return 0;
}

cJSON *iperf_read_bounded_results_socket(int fd, size_t output_limit,
                                         uint32_t timeout_ms,
                                         iperf_result_cancel_function cancelled,
                                         void *cancel_context,
                                         struct iperf_server_output *output,
                                         struct iperf_result_read_metrics *metrics)
{
    int flags = nonblocking(fd);
    if (flags < 0) {
        if (output) { output->state = IPERF_OUTPUT_INVALID; output->reason = IPERF_OUTPUT_READ_FAILURE; }
        return NULL;
    }
    cJSON *result = read_results_socket(fd, output_limit, timeout_ms, cancelled, cancel_context, output, metrics);
    int saved_errno = errno;
    if (restore(fd, flags, saved_errno) < 0) {
        int restore_errno = errno;
        cJSON_Delete(result);
        if (output) {
            iperf_clear_server_output(output);
            output->state = IPERF_OUTPUT_INVALID;
            output->reason = IPERF_OUTPUT_READ_FAILURE;
        }
        errno = restore_errno;
        return NULL;
    }
    return result;
}

int iperf_write_bounded_results_socket(int fd, const char *bytes, uint32_t length,
                                       uint32_t timeout_ms,
                                       iperf_result_cancel_function cancelled,
                                       void *cancel_context)
{
    int flags = nonblocking(fd);
    if (flags < 0) return -1;
    int result = write_results_socket(fd, bytes, length, timeout_ms, cancelled, cancel_context);
    return restore(fd, flags, errno) < 0 ? -1 : result;
}
