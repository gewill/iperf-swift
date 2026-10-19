#include "iperf.h"
#include "iperf_api.h"
#include "iperf_output_budget.h"
#include "net.h"
#include <arpa/inet.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <math.h>

static void discard(struct iperf_server_output *output, enum iperf_output_reason reason)
{
    free(output->value);
    output->value = NULL;
    output->length = 0;
    output->state = reason == IPERF_OUTPUT_INVALID_DATA ? IPERF_OUTPUT_INVALID : IPERF_OUTPUT_DISCARDED;
    output->reason = reason;
}

int iperf_set_test_server_output_byte_limit(struct iperf_test *test, size_t limit)
{
    if (!test || limit > IPERF_OUTPUT_MAX_BYTES) { errno = EINVAL; return -1; }
    test->server_output_byte_limit = limit;
    return 0;
}

void iperf_output_budget_reset(struct iperf_test *test)
{
    /* Early server errors can return before iperf_json_finish. A persistent
     * restart must not overwrite the previous root and leak its start/end data.
     * Budgeted payload references in this tree never own the output bytes. */
    if (test->server_output_byte_limit) {
        cJSON_Delete(test->json_top);
        test->json_top = test->json_start = test->json_connected = NULL;
        test->json_intervals = test->json_end = test->json_server_output = NULL;
    }
    iperf_clear_server_output(&test->collected_server_output);
    iperf_clear_server_output(&test->received_server_output);
    memset(&test->output_read_metrics, 0, sizeof(test->output_read_metrics));
    free(test->output_scratch);
    test->output_scratch = NULL;
    test->output_json_values = 0;
    test->output_json_intervals = 0;
    test->output_finalized = 0;
    test->received_server_output_ready = 0;
    /* Explicit stop is sticky for this native object's lifetime. A normal
     * persistent-server reset must never erase a concurrent stop request. */
}

int iperf_output_stop_requested(void *context)
{
    struct iperf_test *test = context;
    return __atomic_load_n(&test->output_stop_requested, __ATOMIC_SEQ_CST);
}

static int begin(struct iperf_test *test, enum iperf_output_format format)
{
    struct iperf_server_output *output = &test->collected_server_output;
    if (output->state != IPERF_OUTPUT_MISSING) return output->state == IPERF_OUTPUT_COMPLETE;
    output->format = format;
    output->observed_bytes_complete = format == IPERF_OUTPUT_TEXT;
    output->value = malloc(test->server_output_byte_limit + 1);
    if (!output->value) { discard(output, IPERF_OUTPUT_ALLOCATION_FAILURE); return 0; }
    output->value[0] = 0;
    output->state = IPERF_OUTPUT_COMPLETE;
    return 1;
}

/* Validate a UTF-8 prefix without interpreting user text as C terminators. An
 * incomplete final scalar is permitted only if a byte limit cut the input. */
static int utf8_prefix(const unsigned char *text, size_t length, int cut, size_t *valid)
{
    size_t i = 0;
    *valid = 0;
    while (i < length) {
        unsigned char c = text[i];
        size_t n;
        uint32_t scalar, minimum;
        if (c && c < 0x80) { n = 1; scalar = c; minimum = 0; }
        else if (c >= 0xc2 && c <= 0xdf) { n = 2; scalar = c & 31; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { n = 3; scalar = c & 15; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { n = 4; scalar = c & 7; minimum = 0x10000; }
        else return 0;
        if (n > length - i) return cut;
        for (size_t j = 1; j < n; ++j) {
            unsigned char next = text[i + j];
            if (next < 0x80 || next > 0xbf) return 0;
            scalar = (scalar << 6) | (next & 63);
        }
        if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return 0;
        i += n;
        *valid = i;
    }
    return 1;
}

static void count_bytes(struct iperf_server_output *output, size_t count)
{
    if (count > UINT64_MAX - output->observed_bytes) {
        output->observed_bytes = UINT64_MAX;
        output->observed_bytes_complete = 0;
    } else output->observed_bytes += count;
}

static void append_format(struct iperf_test *test, const char *format, va_list arguments)
{
    struct iperf_server_output *output = &test->collected_server_output;
    va_list copy;
    va_copy(copy, arguments);
    int required = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (required < 0) { discard(output, IPERF_OUTPUT_INVALID_DATA); output->observed_bytes_complete = 0; return; }
    count_bytes(output, (size_t)required);
    if (output->state != IPERF_OUTPUT_COMPLETE) return;
    size_t available = test->server_output_byte_limit - output->length;
    va_copy(copy, arguments);
    int written = vsnprintf(output->value + output->length, available + 1, format, copy);
    va_end(copy);
    if (written != required) { discard(output, IPERF_OUTPUT_INVALID_DATA); return; }
    size_t count = (size_t)required < available ? (size_t)required : available, valid;
    int cut = (size_t)required > available;
    if (!utf8_prefix((unsigned char *)output->value + output->length, count, cut, &valid)) {
        discard(output, IPERF_OUTPUT_INVALID_DATA);
        return;
    }
    output->length += valid;
    output->value[output->length] = 0;
    if (cut) { output->state = IPERF_OUTPUT_TRUNCATED; output->reason = IPERF_OUTPUT_BYTE_LIMIT; }
}

static void append(struct iperf_test *test, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    append_format(test, format, arguments);
    va_end(arguments);
}

void iperf_output_collect_printf(struct iperf_test *test, const char *prefix,
                                  const char *format, va_list arguments)
{
    /* Called with print_mutex held. Capture independently of libiperf's 1024
     * byte display buffer, so long lines can use the selected output budget. */
    if (test->output_finalized) return;
    begin(test, IPERF_OUTPUT_TEXT);
    if (prefix) append(test, "%s", prefix);
    append_format(test, format, arguments);
}

static int shape(const cJSON *value, size_t depth, size_t *nodes, enum iperf_output_reason *reason)
{
    if (!value) { *reason = IPERF_OUTPUT_INVALID_DATA; return 0; }
    if (depth > IPERF_RESULT_MAX_DEPTH) { *reason = IPERF_OUTPUT_DEPTH_LIMIT; return 0; }
    if (++*nodes > IPERF_RESULT_CORE_MAX_VALUES) { *reason = IPERF_OUTPUT_NODE_LIMIT; return 0; }
    for (const cJSON *child = value->child; child; child = child->next)
        if (!shape(child, depth + 1, nodes, reason)) return 0;
    return 1;
}

static int scratch(struct iperf_test *test)
{
    if (!test->output_scratch) test->output_scratch = malloc(test->server_output_byte_limit + 5);
    if (!test->output_scratch) { discard(&test->collected_server_output, IPERF_OUTPUT_ALLOCATION_FAILURE); return 0; }
    return 1;
}

void iperf_output_collect_interval(struct iperf_test *test, const cJSON *interval)
{
    struct iperf_server_output *output = &test->collected_server_output;
    if (test->output_finalized || !begin(test, IPERF_OUTPUT_JSON)) return;
    size_t nodes = test->output_json_values;
    enum iperf_output_reason reason = IPERF_OUTPUT_REASON_NONE;
    if (!shape(interval, 3, &nodes, &reason)) { discard(output, reason); return; }
    if (!scratch(test)) return;
    if (!cJSON_PrintPreallocated((cJSON *)interval, test->output_scratch,
                                (int)test->server_output_byte_limit + 5, 0)) {
        discard(output, IPERF_OUTPUT_BYTE_LIMIT); return;
    }
    size_t bytes = strlen(test->output_scratch);
    /* Keep enough room for '[' / ']' and commas; the enclosing document's
     * start/end fields are checked before the complete output is sent. */
    size_t extra = test->output_json_intervals ? 1 : 0;
    if (test->server_output_byte_limit < 2 ||
        output->length > test->server_output_byte_limit - 2 ||
        bytes + extra > test->server_output_byte_limit - 2 - output->length) {
        discard(output, IPERF_OUTPUT_BYTE_LIMIT); return;
    }
    if (extra) output->value[output->length++] = ',';
    memcpy(output->value + output->length, test->output_scratch, bytes + 1);
    output->length += bytes;
    test->output_json_values = nodes;
    ++test->output_json_intervals;
}

static cJSON *raw_reference(const char *text)
{
    cJSON *node = cJSON_CreateStringReference(text);
    if (node) node->type = cJSON_Raw | cJSON_IsReference;
    return node;
}

static void finalize_json(struct iperf_test *test)
{
    struct iperf_server_output *output = &test->collected_server_output;
    if (!begin(test, IPERF_OUTPUT_JSON) || !scratch(test)) return;
    if (!test->json_top || !test->json_intervals) {
        discard(output, IPERF_OUTPUT_INVALID_DATA); return;
    }
    if (test->server_output_byte_limit < 2) { discard(output, IPERF_OUTPUT_BYTE_LIMIT); return; }
    /* At most limit-2 bytes of intervals were retained. Shift in place; no
     * unbounded array or full-history cJSON tree is ever constructed. */
    memmove(output->value + 1, output->value, output->length);
    output->value[0] = '[';
    output->value[++output->length] = ']';
    output->value[++output->length] = 0;
    cJSON *raw = raw_reference(output->value);
    if (!raw) { discard(output, IPERF_OUTPUT_ALLOCATION_FAILURE); return; }
    cJSON *original = cJSON_DetachItemViaPointer(test->json_top, test->json_intervals);
    cJSON_AddItemToObjectCS(test->json_top, "intervals", raw);
    size_t nodes = test->output_json_values;
    enum iperf_output_reason reason = IPERF_OUTPUT_REASON_NONE;
    int valid = shape(test->json_top, 1, &nodes, &reason);
    if (valid && !cJSON_PrintPreallocated(test->json_top, test->output_scratch,
                                         (int)test->server_output_byte_limit + 5, 0)) {
        valid = 0; reason = IPERF_OUTPUT_BYTE_LIMIT;
    }
    size_t bytes = valid ? strlen(test->output_scratch) : 0;
    if (bytes > test->server_output_byte_limit) { valid = 0; reason = IPERF_OUTPUT_BYTE_LIMIT; }
    cJSON_DetachItemViaPointer(test->json_top, raw);
    cJSON_Delete(raw);
    if (original) cJSON_AddItemToObjectCS(test->json_top, "intervals", original);
    if (!valid) { discard(output, reason); return; }
    size_t checked;
    if (!utf8_prefix((unsigned char *)test->output_scratch, bytes, 0, &checked)) {
        discard(output, IPERF_OUTPUT_INVALID_DATA); return;
    }
    memcpy(output->value, test->output_scratch, bytes + 1);
    output->length = bytes;
    output->observed_bytes = bytes;
    output->observed_bytes_complete = 1;
}

int iperf_output_add_server_results(struct iperf_test *test, cJSON *results)
{
    if (!test->output_finalized) {
        if (test->json_output) finalize_json(test);
        else begin(test, IPERF_OUTPUT_TEXT);
        test->output_finalized = 1;
    }
    struct iperf_server_output *output = &test->collected_server_output;
    if (output->value) {
        cJSON *value = output->format == IPERF_OUTPUT_JSON ? raw_reference(output->value) : cJSON_CreateStringReference(output->value);
        if (!value) return -1;
        cJSON_AddItemToObjectCS(results, output->format == IPERF_OUTPUT_JSON ? "server_output_json" : "server_output_text", value);
    }
    cJSON *status = cJSON_AddObjectToObject(results, "iperf_swift_server_output");
    if (!status || !cJSON_AddNumberToObject(status, "version", 1) ||
        !cJSON_AddNumberToObject(status, "state", output->state) ||
        !cJSON_AddNumberToObject(status, "format", output->format) ||
        !cJSON_AddNumberToObject(status, "reason", output->reason)) return -1;
    /* JSON numbers cannot safely represent every UInt64; omit an inexact total. */
    if (output->observed_bytes_complete && output->observed_bytes <= 9007199254740991ULL &&
        !cJSON_AddNumberToObject(status, "observed_bytes", (double)output->observed_bytes)) return -1;
    return 0;
}

void iperf_output_apply_peer_status(struct iperf_server_output *output, const cJSON *results)
{
    const cJSON *status = cJSON_GetObjectItemCaseSensitive(results, "iperf_swift_server_output");
    if (!status) return; /* Unmodified CLI: local receive status is authoritative. */
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(status, "version");
    const cJSON *state = cJSON_GetObjectItemCaseSensitive(status, "state");
    const cJSON *format = cJSON_GetObjectItemCaseSensitive(status, "format");
    const cJSON *reason = cJSON_GetObjectItemCaseSensitive(status, "reason");
    const cJSON *bytes = cJSON_GetObjectItemCaseSensitive(status, "observed_bytes");
    if (!cJSON_IsObject(status) || !cJSON_IsNumber(version) || version->valuedouble != 1 ||
        !cJSON_IsNumber(state) || state->valuedouble != state->valueint ||
        state->valueint < IPERF_OUTPUT_COMPLETE || state->valueint > IPERF_OUTPUT_INVALID ||
        !cJSON_IsNumber(format) || (format->valueint != IPERF_OUTPUT_TEXT && format->valueint != IPERF_OUTPUT_JSON) ||
        format->valuedouble != format->valueint || !cJSON_IsNumber(reason) || reason->valuedouble != reason->valueint ||
        reason->valueint < IPERF_OUTPUT_REASON_NONE || reason->valueint > IPERF_OUTPUT_READ_FAILURE) {
        discard(output, IPERF_OUTPUT_INVALID_DATA); return;
    }
    /* Peer metadata can only worsen local state, never turn locally truncated
     * or invalid data into a complete result. Missing output is valid only for
     * a peer-declared discarded/invalid output. */
    if (output->format != IPERF_OUTPUT_NONE && output->format != format->valueint) {
        discard(output, IPERF_OUTPUT_INVALID_DATA); return;
    }
    if (output->state == IPERF_OUTPUT_MISSING && state->valueint < IPERF_OUTPUT_DISCARDED) {
        discard(output, IPERF_OUTPUT_INVALID_DATA); return;
    }
    if ((state->valueint == IPERF_OUTPUT_COMPLETE && reason->valueint != IPERF_OUTPUT_REASON_NONE) ||
        (state->valueint == IPERF_OUTPUT_TRUNCATED &&
         (format->valueint != IPERF_OUTPUT_TEXT || reason->valueint != IPERF_OUTPUT_BYTE_LIMIT)) ||
        (state->valueint >= IPERF_OUTPUT_DISCARDED && reason->valueint == IPERF_OUTPUT_REASON_NONE)) {
        discard(output, IPERF_OUTPUT_INVALID_DATA); return;
    }
    const char *keys[] = {"version", "state", "format", "reason", "observed_bytes"};
    unsigned seen = 0;
    for (const cJSON *child = status->child; child; child = child->next) {
        for (size_t i = 0; i < sizeof(keys) / sizeof(*keys); ++i) {
            if (child->string && strcmp(child->string, keys[i]) == 0) {
                if (seen & (1U << i)) { discard(output, IPERF_OUTPUT_INVALID_DATA); return; }
                seen |= 1U << i;
            }
        }
    }
    if (output->state != IPERF_OUTPUT_INVALID && state->valueint >= IPERF_OUTPUT_DISCARDED) {
        discard(output, (enum iperf_output_reason)reason->valueint);
        output->state = (enum iperf_output_state)state->valueint;
    } else if (output->state == IPERF_OUTPUT_COMPLETE && state->valueint == IPERF_OUTPUT_TRUNCATED) {
        output->state = IPERF_OUTPUT_TRUNCATED;
        output->reason = (enum iperf_output_reason)reason->valueint;
    }
    output->format = (enum iperf_output_format)format->valueint;
    output->observed_bytes_complete = 0;
    if (cJSON_IsNumber(bytes) && isfinite(bytes->valuedouble) && bytes->valuedouble >= output->observed_bytes &&
        bytes->valuedouble <= 9007199254740991.0 && floor(bytes->valuedouble) == bytes->valuedouble) {
        output->observed_bytes = (uint64_t)bytes->valuedouble;
        output->observed_bytes_complete = 1;
    }
}

int iperf_output_write_results(struct iperf_test *test, cJSON *results)
{
    /* Text escaping expands each byte by at most six. Core statistics have a
     * separate 1 MiB allowance; the extra KiB covers fixed status/framing keys. */
    size_t capacity = IPERF_RESULT_CORE_MAX_BYTES + 6 * test->server_output_byte_limit + 1024 + 5;
    char *bytes = malloc(capacity);
    if (!bytes) return -1;
    int result = -1;
    if (cJSON_PrintPreallocated(results, bytes, (int)capacity, 0)) {
        size_t size = strlen(bytes);
        result = iperf_write_bounded_results_socket(test->ctrl_sck, bytes, (uint32_t)size,
            IPERF_RESULT_READ_TIMEOUT_MS, iperf_output_stop_requested, test);
    } else errno = EFBIG;
    free(bytes);
    return result;
}

void iperf_output_get_local_status(struct iperf_test *test, struct iperf_server_output *status)
{
    pthread_mutex_lock(&test->print_mutex);
    *status = test->collected_server_output;
    status->value = NULL; /* Metadata only; no borrowed buffer crosses threads. */
    pthread_mutex_unlock(&test->print_mutex);
}

void iperf_output_print_received(struct iperf_test *test)
{
    if (test->received_server_output.value)
        iperf_printf(test, "\nServer output:\n%s\n", test->received_server_output.value);
}

void iperf_output_add_received_json(struct iperf_test *test)
{
    struct iperf_server_output *output = &test->received_server_output;
    if (!output->value) return;
    cJSON *value = output->format == IPERF_OUTPUT_JSON ? raw_reference(output->value) : cJSON_CreateStringReference(output->value);
    if (value) cJSON_AddItemToObjectCS(test->json_top,
        output->format == IPERF_OUTPUT_JSON ? "server_output_json" : "server_output_text", value);
}
