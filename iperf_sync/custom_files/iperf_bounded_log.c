#include "iperf_bounded_log.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char marker[] = "\n[iperf log truncated]\n";
#define MARKER_SIZE (sizeof(marker) - 1)
/* Reserve the marker plus enough bytes to move a cut to a UTF-8 boundary. */
#define TAIL_SIZE (MARKER_SIZE + 3)

struct bounded_log {
    FILE *sink;
    struct iperf_log_status *status;
    uint64_t capacity;
    uint64_t accepted;
    unsigned char tail[TAIL_SIZE];
    size_t tail_size;
};

const char *iperf_log_truncation_marker(void) { return marker; }
uint64_t iperf_log_minimum_limit(void) { return MARKER_SIZE; }

static void remember_error(int *slot, int error)
{
    if (*slot == 0)
        *slot = error != 0 ? error : EIO;
}

static void write_bytes(struct bounded_log *log, const void *bytes, size_t count)
{
    if (count == 0 || !log->sink || log->status->write_errno)
        return;
    int saved_errno = errno;
    errno = 0;
    size_t written = fwrite(bytes, 1, count, log->sink);
    log->status->bytes_written += written;
    log->status->file_bytes += written;
    if (written != count || ferror(log->sink))
        remember_error(&log->status->write_errno, errno);
    /* A deliberately non-fatal logging error must not replace the engine's
     * errno while it is producing an error report. */
    errno = saved_errno;
}

/* Streaming prefix with constant storage. Holding the last few bytes until
 * close distinguishes an exactly full file from actual discarded output. */
static void retain_prefix(struct bounded_log *log, const unsigned char *bytes,
                          size_t count)
{
    size_t flush = log->tail_size + count > TAIL_SIZE
        ? log->tail_size + count - TAIL_SIZE : 0;
    size_t old = flush < log->tail_size ? flush : log->tail_size;
    write_bytes(log, log->tail, old);
    memmove(log->tail, log->tail + old, log->tail_size - old);
    log->tail_size -= old;
    flush -= old;
    write_bytes(log, bytes, flush);
    bytes += flush;
    count -= flush;
    memcpy(log->tail + log->tail_size, bytes, count);
    log->tail_size += count;
}

/* For valid UTF-8 input, omit an incomplete final scalar. Earlier bytes may
 * already be on disk, so the extra three reserved bytes are essential. */
static size_t utf8_prefix(const unsigned char *bytes, size_t count)
{
    if (!count)
        return 0;
    size_t start = count - 1;
    while (start > 0 && (bytes[start] & 0xc0) == 0x80)
        --start;
    unsigned char lead = bytes[start];
    size_t width = lead >= 0xf0 && lead <= 0xf4 ? 4
        : lead >= 0xe0 && lead <= 0xef ? 3
        : lead >= 0xc2 && lead <= 0xdf ? 2 : 1;
    return count - start < width ? start : count;
}

static int bounded_write(void *cookie, const char *bytes, int count)
{
    struct bounded_log *log = cookie;
    if (count <= 0)
        return count;
    if (log->status->truncated || log->status->open_errno ||
        log->status->write_errno)
        return count;

    /* An existing file with less than a marker's space cannot gain a useful
     * prefix plus marker. Leave it intact and report truncation out of band. */
    if (log->capacity < MARKER_SIZE) {
        log->status->truncated = 1;
        return count;
    }
    uint64_t remaining = log->capacity - log->accepted;
    size_t keep = (uint64_t)count < remaining ? (size_t)count : (size_t)remaining;
    retain_prefix(log, (const unsigned char *)bytes, keep);
    log->accepted += keep;
    if ((uint64_t)count > remaining) {
        log->status->truncated = 1;
        size_t prefix = utf8_prefix(log->tail, log->tail_size - MARKER_SIZE);
        write_bytes(log, log->tail, prefix);
        write_bytes(log, marker, MARKER_SIZE);
        log->tail_size = 0;
    }
    /* Logging is optional: a full or failed sink must not fail a measurement.
     * Preserve the failure in status instead of repeatedly retrying writes. */
    return count;
}

static int bounded_close(void *cookie)
{
    struct bounded_log *log = cookie;
    write_bytes(log, log->tail, log->tail_size);
    int result = 0;
    if (log->sink) {
        errno = 0;
        result = fclose(log->sink);
        if (result != 0)
            remember_error(&log->status->close_errno, errno);
    }
    int error = log->status->close_errno;
    free(log);
    if (result != 0)
        errno = error;
    return result;
}

FILE *iperf_bounded_log_wrap(FILE *sink, uint64_t existing_bytes,
                             struct iperf_log_status *status)
{
    status->attempted = 1;
    status->file_bytes = existing_bytes;
    if (sink)
        status->file_size_known = 1;
    struct bounded_log *log = calloc(1, sizeof(*log));
    if (!log) {
        if (sink)
            fclose(sink);
        remember_error(&status->open_errno, ENOMEM);
        errno = ENOMEM;
        return NULL;
    }
    log->sink = sink;
    log->status = status;
    if (status->limit < MARKER_SIZE || existing_bytes > status->limit)
        remember_error(&status->open_errno, existing_bytes > status->limit ? EFBIG : EINVAL);
    else
        log->capacity = status->limit - existing_bytes;
    if (sink && setvbuf(sink, NULL, _IONBF, 0) != 0)
        remember_error(&status->open_errno, errno);
    FILE *file = funopen(log, NULL, bounded_write, NULL, bounded_close);
    if (!file) {
        int error = errno;
        bounded_close(log);
        remember_error(&status->open_errno, error);
        errno = error;
    }
    return file;
}

FILE *iperf_bounded_log_open(const char *path, struct iperf_log_status *status)
{
    /* Persistent servers reset between clients. Once output is disabled, keep
     * it disabled without retrying a failed path or reopening a full file. */
    if (status->attempted && (status->truncated || status->open_errno ||
                             status->write_errno || status->close_errno))
        return iperf_bounded_log_wrap(NULL, status->file_bytes, status);
    FILE *sink = NULL;
    uint64_t existing = 0;
    /* Nonblocking open avoids hanging on a caller-supplied FIFO. Only regular
     * files are supported. New optional logfiles are private to their owner. */
    int descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        remember_error(&status->open_errno, errno);
    } else {
        struct stat info;
        if (fstat(descriptor, &info) != 0) {
            remember_error(&status->open_errno, errno);
        } else if (!S_ISREG(info.st_mode) || info.st_size < 0) {
            remember_error(&status->open_errno, EINVAL);
        } else {
            existing = (uint64_t)info.st_size;
            status->file_size_known = 1;
            sink = fdopen(descriptor, "a");
            if (!sink)
                remember_error(&status->open_errno, errno);
        }
        if (!sink)
            close(descriptor);
    }
    return iperf_bounded_log_wrap(sink, existing, status);
}
