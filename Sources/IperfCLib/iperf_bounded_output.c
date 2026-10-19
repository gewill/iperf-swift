#include "iperf_bounded_output.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

enum capture { DISCARD, CORE, OUTPUT_JSON };

struct parser {
    iperf_result_read_function read;
    void *context;
    uint32_t remaining;
    unsigned char input[4096];
    size_t cursor, available;
    char *core;
    size_t core_length, limit;
    enum capture capture;
    struct iperf_server_output *output;
    struct iperf_result_read_metrics *metrics;
    size_t values, output_values;
    int error;
};

struct decoded {
    char *key;
    size_t length;
    int output_text;
    int is_key;
};

void iperf_clear_server_output(struct iperf_server_output *output)
{
    free(output->value);
    memset(output, 0, sizeof(*output));
}

static int fail(struct parser *p, int error)
{
    if (!p->error)
        p->error = error;
    return 0;
}

static int peek(struct parser *p)
{
    if (p->error)
        return -1;
    if (p->cursor == p->available) {
        if (!p->remaining)
            return -1;
        size_t count = p->remaining < sizeof(p->input) ? p->remaining : sizeof(p->input);
        int n = p->read(p->context, p->input, count);
        if (n <= 0 || (size_t)n > count) {
            fail(p, n < 0 && errno ? errno : EPROTO);
            return -1;
        }
        p->remaining -= (uint32_t)n;
        p->metrics->bytes_read += (size_t)n;
        p->cursor = 0;
        p->available = (size_t)n;
    }
    return p->input[p->cursor];
}

static void discard_output(struct parser *p, enum iperf_output_state state)
{
    free(p->output->value);
    p->output->value = NULL;
    p->output->length = 0;
    p->output->state = state;
}

static int emit(struct parser *p, unsigned char byte)
{
    if (p->capture == CORE) {
        if (p->core_length == IPERF_RESULT_CORE_MAX_BYTES)
            return fail(p, EFBIG);
        p->core[p->core_length++] = (char)byte;
    } else if (p->capture == OUTPUT_JSON) {
        ++p->output->observed_bytes;
        if (p->output->state == IPERF_OUTPUT_COMPLETE) {
            if (p->output->length == p->limit)
            {
                discard_output(p, IPERF_OUTPUT_DISCARDED);
                p->output->reason = IPERF_OUTPUT_BYTE_LIMIT;
            }
            else
                p->output->value[p->output->length++] = (char)byte;
        }
    }
    return 1;
}

static int take(struct parser *p)
{
    int c = peek(p);
    if (c < 0) {
        fail(p, EPROTO);
        return -1;
    }
    ++p->cursor;
    return emit(p, (unsigned char)c) ? c : -1;
}

static int expect(struct parser *p, int expected)
{
    return take(p) == expected ? 1 : fail(p, EPROTO);
}

static void whitespace(struct parser *p)
{
    int c;
    while ((c = peek(p)) == ' ' || c == '\t' || c == '\r' || c == '\n')
        ++p->cursor;
}

static int decoded_scalar(struct parser *p, struct decoded *destination, uint32_t scalar)
{
    if (!destination)
        return 1;
    if (destination->is_key && !scalar)
        return fail(p, EPROTO);
    unsigned char bytes[4];
    size_t n;
    if (scalar <= 0x7f) {
        bytes[0] = (unsigned char)scalar; n = 1;
    } else if (scalar <= 0x7ff) {
        bytes[0] = 0xc0 | (scalar >> 6); bytes[1] = 0x80 | (scalar & 0x3f); n = 2;
    } else if (scalar <= 0xffff) {
        bytes[0] = 0xe0 | (scalar >> 12); bytes[1] = 0x80 | ((scalar >> 6) & 0x3f);
        bytes[2] = 0x80 | (scalar & 0x3f); n = 3;
    } else {
        bytes[0] = 0xf0 | (scalar >> 18); bytes[1] = 0x80 | ((scalar >> 12) & 0x3f);
        bytes[2] = 0x80 | ((scalar >> 6) & 0x3f); bytes[3] = 0x80 | (scalar & 0x3f); n = 4;
    }
    if (destination->key) {
        /* Protocol keys cannot contain an embedded C terminator. */
        if (!scalar || destination->length + n > 127)
            return fail(p, scalar ? EFBIG : EPROTO);
        memcpy(destination->key + destination->length, bytes, n);
        destination->length += n;
    } else if (destination->output_text) {
        p->output->observed_bytes += n;
        /* libiperf exposes textual output as a C string. Report a value it
         * cannot represent as invalid, rather than silently cutting at NUL. */
        if (!scalar) {
            discard_output(p, IPERF_OUTPUT_INVALID);
            p->output->reason = IPERF_OUTPUT_INVALID_DATA;
        } else if (p->output->state == IPERF_OUTPUT_COMPLETE) {
            if (p->output->length + n > p->limit) {
                p->output->state = IPERF_OUTPUT_TRUNCATED;
                p->output->reason = IPERF_OUTPUT_BYTE_LIMIT;
            }
            else {
                memcpy(p->output->value + p->output->length, bytes, n);
                p->output->length += n;
            }
        }
    }
    return 1;
}

static int hex4(struct parser *p, uint32_t *result)
{
    *result = 0;
    for (int i = 0; i < 4; ++i) {
        int c = take(p), digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return fail(p, EPROTO);
        *result = (*result << 4) | (uint32_t)digit;
    }
    return 1;
}

static int string(struct parser *p, struct decoded *destination)
{
    if (!expect(p, '"')) return 0;
    while (!p->error) {
        int c = take(p);
        uint32_t scalar;
        if (c == '"') return 1;
        if (c < 0x20) return fail(p, EPROTO);
        if (c == '\\') {
            c = take(p);
            switch (c) {
            case '"': case '\\': case '/': scalar = (uint32_t)c; break;
            case 'b': scalar = '\b'; break;
            case 'f': scalar = '\f'; break;
            case 'n': scalar = '\n'; break;
            case 'r': scalar = '\r'; break;
            case 't': scalar = '\t'; break;
            case 'u':
                if (!hex4(p, &scalar)) return 0;
                if (scalar >= 0xd800 && scalar <= 0xdbff) {
                    uint32_t low;
                    if (!expect(p, '\\') || !expect(p, 'u') || !hex4(p, &low)) return 0;
                    if (low < 0xdc00 || low > 0xdfff) return fail(p, EPROTO);
                    scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
                } else if (scalar >= 0xdc00 && scalar <= 0xdfff) return fail(p, EPROTO);
                break;
            default: return fail(p, EPROTO);
            }
        } else if (c < 0x80) {
            scalar = (uint32_t)c;
        } else {
            int following;
            uint32_t minimum;
            if (c >= 0xc2 && c <= 0xdf) { following = 1; scalar = c & 0x1f; minimum = 0x80; }
            else if (c >= 0xe0 && c <= 0xef) { following = 2; scalar = c & 0x0f; minimum = 0x800; }
            else if (c >= 0xf0 && c <= 0xf4) { following = 3; scalar = c & 0x07; minimum = 0x10000; }
            else return fail(p, EPROTO);
            for (int i = 0; i < following; ++i) {
                c = take(p);
                if (c < 0x80 || c > 0xbf) return fail(p, EPROTO);
                scalar = (scalar << 6) | (uint32_t)(c & 0x3f);
            }
            if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff))
                return fail(p, EPROTO);
        }
        if (!decoded_scalar(p, destination, scalar)) return 0;
    }
    return 0;
}

static int digit(int c) { return c >= '0' && c <= '9'; }

static int number(struct parser *p)
{
    /* Count every character, as cJSON's parse_number does. A number ends in
     * one of the checked digit loops unless it is "0" or "-0". */
    const size_t maximum = IPERF_RESULT_MAX_NUMBER_LENGTH;
    size_t count = 0;
    if (peek(p) == '-') { take(p); ++count; }
    if (peek(p) == '0') { take(p); ++count; }
    else {
        if (peek(p) < '1' || peek(p) > '9') return fail(p, EPROTO);
        do { take(p); if (++count > maximum) return fail(p, EPROTO); } while (digit(peek(p)));
    }
    if (peek(p) == '.') {
        take(p); ++count;
        if (!digit(peek(p))) return fail(p, EPROTO);
        do { take(p); if (++count > maximum) return fail(p, EPROTO); } while (digit(peek(p)));
    }
    if (peek(p) == 'e' || peek(p) == 'E') {
        take(p); ++count;
        if (peek(p) == '+' || peek(p) == '-') { take(p); ++count; }
        if (!digit(peek(p))) return fail(p, EPROTO);
        do { take(p); if (++count > maximum) return fail(p, EPROTO); } while (digit(peek(p)));
    }
    return p->error == 0;
}

static int value(struct parser *p, size_t depth, struct decoded *destination)
{
    if (depth > IPERF_RESULT_MAX_DEPTH || ++p->values > IPERF_RESULT_MAX_VALUES)
        return fail(p, EFBIG);
    if (depth > p->metrics->maximum_depth) p->metrics->maximum_depth = depth;
    if (p->capture == CORE && ++p->metrics->core_values > IPERF_RESULT_CORE_MAX_VALUES)
        return fail(p, EFBIG);
    /* Only complete output can still be discarded here: output that an earlier
     * byte limit already discarded keeps that reason. */
    if (p->capture == OUTPUT_JSON && ++p->output_values > IPERF_RESULT_CORE_MAX_VALUES &&
        p->output->state == IPERF_OUTPUT_COMPLETE) {
        discard_output(p, IPERF_OUTPUT_DISCARDED);
        p->output->reason = IPERF_OUTPUT_NODE_LIMIT;
    }
    whitespace(p);
    int c = peek(p);
    if (c == '"') return string(p, destination);
    if (c == '-' || digit(c)) return number(p);
    if (c == 't' || c == 'f' || c == 'n') {
        const char *literal = c == 't' ? "true" : c == 'f' ? "false" : "null";
        while (*literal) if (!expect(p, *literal++)) return 0;
        return 1;
    }
    if (c != '[' && c != '{') return fail(p, EPROTO);
    int object = c == '{', close = object ? '}' : ']';
    take(p); whitespace(p);
    if (peek(p) == close) return expect(p, close);
    for (;;) {
        if (object) {
            struct decoded key = { .is_key = 1 };
            if (!string(p, &key)) return 0;
            whitespace(p);
            if (!expect(p, ':')) return 0;
        }
        if (!value(p, depth + 1, NULL)) return 0;
        whitespace(p);
        if (peek(p) == close) return expect(p, close);
        if (!expect(p, ',')) return 0;
        whitespace(p);
    }
}

static int core_key(struct parser *p, const char *key)
{
    static const char hex[] = "0123456789abcdef";
    if (!emit(p, '"')) return 0;
    for (const unsigned char *s = (const unsigned char *)key; *s; ++s) {
        if (*s == '"' || *s == '\\') {
            if (!emit(p, '\\') || !emit(p, *s)) return 0;
        } else if (*s < 0x20) {
            const unsigned char escaped[] = {'\\', 'u', '0', '0', hex[*s >> 4], hex[*s & 15]};
            for (size_t i = 0; i < sizeof(escaped); ++i) if (!emit(p, escaped[i])) return 0;
        } else if (!emit(p, *s)) return 0;
    }
    return emit(p, '"') && emit(p, ':');
}

static int begin_output(struct parser *p, enum iperf_output_format format)
{
    iperf_clear_server_output(p->output);
    p->output->format = format;
    p->output->state = IPERF_OUTPUT_COMPLETE;
    p->output->observed_bytes_complete = 1;
    p->output->value = malloc(p->limit + 1);
    if (!p->output->value) return fail(p, ENOMEM);
    p->metrics->peak_buffer_capacity = IPERF_RESULT_CORE_MAX_BYTES + p->limit + 2;
    p->output_values = 0;
    return 1;
}

static int root(struct parser *p)
{
    /* These fields affect measurements or the output precedence. Reject
     * duplicates (including case/escape variants) instead of interpreting two
     * conflicting values differently in the filter and in cJSON. */
    const char *unique[] = {"cpu_util_total", "cpu_util_user", "cpu_util_system",
        "sender_has_retransmits", "streams", "congestion_used", "server_output_text", "server_output_json",
        "iperf_swift_server_output"};
    unsigned seen = 0;
    int core_fields = 0, seen_json = 0;
    p->capture = DISCARD;
    whitespace(p);
    if (!expect(p, '{')) return 0;
    p->capture = CORE;
    if (!emit(p, '{')) return 0;
    p->capture = DISCARD;
    whitespace(p);
    if (peek(p) != '}') for (;;) {
        char key[128] = {0};
        struct decoded decoded = { .key = key, .is_key = 1 };
        if (!string(p, &decoded)) return 0;
        for (size_t i = 0; i < sizeof(unique) / sizeof(*unique); ++i) {
            if (strcasecmp(key, unique[i]) == 0) {
                if (seen & (1U << i)) return fail(p, EPROTO);
                seen |= 1U << i;
            }
        }
        whitespace(p);
        if (!expect(p, ':')) return 0;
        whitespace(p);
        int json = strcasecmp(key, "server_output_json") == 0;
        int text = strcasecmp(key, "server_output_text") == 0;
        if (json || (text && !seen_json)) {
            if (!begin_output(p, json ? IPERF_OUTPUT_JSON : IPERF_OUTPUT_TEXT)) return 0;
            int valid_type = peek(p) == (json ? '{' : '"');
            if (!valid_type) {
                discard_output(p, IPERF_OUTPUT_INVALID);
                p->output->reason = IPERF_OUTPUT_INVALID_DATA;
                p->output->observed_bytes_complete = 0;
            }
            p->capture = json && valid_type ? OUTPUT_JSON : DISCARD;
            struct decoded output_text = { .output_text = text && valid_type };
            if (!value(p, 1, text && valid_type ? &output_text : NULL)) return 0;
            if (json) seen_json = 1;
        } else if (text) {
            /* Match libiperf's preference for JSON when both are present. */
            if (!value(p, 1, NULL)) return 0;
        } else {
            p->capture = CORE;
            if (core_fields++ && !emit(p, ',')) return 0;
            if (!core_key(p, key) || !value(p, 1, NULL)) return 0;
        }
        p->capture = DISCARD;
        whitespace(p);
        if (peek(p) == '}') break;
        if (!expect(p, ',')) return 0;
        whitespace(p);
    }
    if (!expect(p, '}')) return 0;
    p->capture = CORE;
    if (!emit(p, '}')) return 0;
    p->capture = DISCARD;
    whitespace(p);
    return peek(p) < 0 && !p->error ? 1 : fail(p, EPROTO);
}

cJSON *iperf_read_bounded_results(uint32_t frame_length, size_t output_limit,
                                  iperf_result_read_function read_function,
                                  void *context,
                                  struct iperf_server_output *output,
                                  struct iperf_result_read_metrics *metrics)
{
    if (!read_function || !output || !metrics || !output_limit || output_limit > IPERF_OUTPUT_MAX_BYTES) {
        if (output) output->state = IPERF_OUTPUT_INVALID;
        errno = EINVAL;
        return NULL;
    }
    if (!frame_length || frame_length > IPERF_RESULT_FRAME_MAX_BYTES) {
        output->state = IPERF_OUTPUT_INVALID;
        output->reason = IPERF_OUTPUT_BYTE_LIMIT;
        errno = EFBIG;
        return NULL;
    }
    struct parser p = { .read = read_function, .context = context, .remaining = frame_length,
        .limit = output_limit, .output = output, .metrics = metrics };
    p.core = malloc(IPERF_RESULT_CORE_MAX_BYTES + 1);
    if (!p.core) {
        output->state = IPERF_OUTPUT_INVALID;
        output->reason = IPERF_OUTPUT_ALLOCATION_FAILURE;
        errno = ENOMEM;
        return NULL;
    }
    metrics->peak_buffer_capacity = IPERF_RESULT_CORE_MAX_BYTES + 1;
    cJSON *result = NULL;
    if (root(&p)) {
        p.core[p.core_length] = 0;
        metrics->core_json_bytes = p.core_length;
        if (output->value) output->value[output->length] = 0;
        /* The scanner has already bounded core bytes, node count, depth and
         * number length. cJSON sees only this compact core, never the optional
         * output body, so it should fail only to allocate. Report anything
         * else as invalid input rather than as an allocation failure. */
        errno = 0;
        result = cJSON_ParseWithLengthOpts(p.core, p.core_length + 1, NULL, 1);
        if (!result) fail(&p, errno == ENOMEM ? ENOMEM : EPROTO);
    }
    free(p.core);
    if (!result) {
        iperf_clear_server_output(output);
        output->state = IPERF_OUTPUT_INVALID;
        output->reason = p.error == ENOMEM ? IPERF_OUTPUT_ALLOCATION_FAILURE :
            p.error == EPROTO ? IPERF_OUTPUT_INVALID_DATA : IPERF_OUTPUT_READ_FAILURE;
        errno = p.error ? p.error : EPROTO;
    }
    return result;
}
