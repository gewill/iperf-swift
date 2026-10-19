/* Isolated allocator instrumentation. Only the parser and cJSON translation
 * units use these hooks; no global hooks are changed in a running SDK process. */
#include "iperf.h"
#include "iperf_api.h"
#include "iperf_output_budget.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef union {
    max_align_t alignment;
    struct { size_t size; uint64_t magic; } allocation;
} header;

static size_t live_bytes, peak_bytes, largest_request, attempts, fail_at;
static const uint64_t magic = 0xB0D196ABCDEF1234ULL;

void *result_test_malloc(size_t size)
{
    if (++attempts == fail_at) { errno = ENOMEM; return NULL; }
    assert(size <= SIZE_MAX - sizeof(header));
    header *block = malloc(sizeof(header) + size);
    assert(block);
    block->allocation.size = size;
    block->allocation.magic = magic;
    live_bytes += size;
    if (live_bytes > peak_bytes) peak_bytes = live_bytes;
    if (size > largest_request) largest_request = size;
    return block + 1;
}

void result_test_free(void *pointer)
{
    if (!pointer) return;
    header *block = (header *)pointer - 1;
    assert(block->allocation.magic == magic);
    assert(live_bytes >= block->allocation.size);
    live_bytes -= block->allocation.size;
    block->allocation.magic = 0;
    free(block);
}

void *result_test_realloc(void *pointer, size_t size)
{
    if (!pointer) return result_test_malloc(size);
    header *block = (header *)pointer - 1;
    assert(block->allocation.magic == magic);
    void *replacement = result_test_malloc(size);
    if (!replacement) return NULL;
    memcpy(replacement, pointer, size < block->allocation.size ? size : block->allocation.size);
    result_test_free(pointer);
    return replacement;
}

struct input {
    const char *prefix, *suffix;
    size_t repeated, offset, max_request;
};

/* Generate multi-MiB input a chunk at a time: the test fixture itself does not
 * allocate an on-wire frame and therefore cannot hide a parser-sized copy. */
static int read_input(void *context, unsigned char *destination, size_t capacity)
{
    struct input *input = context;
    size_t prefix = strlen(input->prefix), suffix = strlen(input->suffix);
    size_t total = prefix + input->repeated + suffix;
    size_t count = total - input->offset;
    if (count > capacity) count = capacity;
    if (capacity > input->max_request) input->max_request = capacity;
    for (size_t i = 0; i < count; ++i) {
        size_t offset = input->offset++;
        destination[i] = offset < prefix ? input->prefix[offset] :
            offset < prefix + input->repeated ? 'a' : input->suffix[offset - prefix - input->repeated];
    }
    return (int)count;
}

static void reset(size_t failure)
{
    assert(live_bytes == 0);
    peak_bytes = largest_request = attempts = 0;
    fail_at = failure;
}

static size_t check(const char *name, struct input input, size_t limit,
                    enum iperf_output_state state, size_t failure)
{
    reset(failure);
    struct iperf_server_output output = {0};
    struct iperf_result_read_metrics metrics = {0};
    uint32_t length = (uint32_t)(strlen(input.prefix) + input.repeated + strlen(input.suffix));
    cJSON *tree = iperf_read_bounded_results(length, limit, read_input, &input, &output, &metrics);
    if (failure) {
        assert(!tree && !output.value && output.state == IPERF_OUTPUT_INVALID);
        assert(errno == ENOMEM);
    } else {
        assert(tree && output.state == state);
        assert(input.offset == length);
        assert(input.max_request <= 4096);
        assert(largest_request <= IPERF_RESULT_CORE_MAX_BYTES + 1);
        /* Includes actual requested cJSON node/key/value bytes, not just the
         * parser's self-reported byte-buffer capacity. Excludes allocator and
         * instrumentation headers, stack, Swift copies and process footprint. */
        size_t upper = 2 * IPERF_RESULT_CORE_MAX_BYTES + limit + 2 +
            (IPERF_RESULT_CORE_MAX_VALUES + 1) * sizeof(cJSON);
        assert(peak_bytes <= upper);
        cJSON *streams = cJSON_GetObjectItem(tree, "streams");
        if (streams) assert(cJSON_GetObjectItem(cJSON_GetArrayItem(streams, 0), "bytes")->valueint == 123456);
        printf("%s: wire=%u requested_peak=%zu largest_request=%zu allocations=%zu output=%zu\n",
               name, length, peak_bytes, largest_request, attempts, output.length);
    }
    size_t allocation_count = attempts;
    cJSON_Delete(tree);
    iperf_clear_server_output(&output);
    assert(live_bytes == 0);
    return allocation_count;
}


/* This isolated allocator probe exercises collection and serialization, not an
 * engine run. The CLI tests cover the actual iperf_printf/network path. */
int iperf_printf(struct iperf_test *test, const char *format, ...)
{
    (void)test; (void)format;
    return 0;
}

static void collect(struct iperf_test *test, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    iperf_output_collect_printf(test, NULL, format, arguments);
    va_end(arguments);
}

static void collector_allocations(int json)
{
    reset(0);
    struct iperf_test test = {0};
    test.server_output_byte_limit = 256 * 1024;
    test.ctrl_sck = -1;
    test.json_output = json;
    cJSON *interval = NULL;
    if (json) {
        test.json_top = cJSON_CreateObject();
        test.json_intervals = cJSON_AddArrayToObject(test.json_top, "intervals");
        cJSON_AddObjectToObject(test.json_top, "start");
        cJSON_AddObjectToObject(test.json_top, "end");
        interval = cJSON_Parse("{\"streams\":[{\"bytes\":123456,\"seconds\":1}]}");
        assert(interval);
        for (int i = 0; i < 100000; ++i) iperf_output_collect_interval(&test, interval);
        assert(test.collected_server_output.state == IPERF_OUTPUT_DISCARDED);
        assert(cJSON_GetArraySize(test.json_intervals) == 0);
    } else {
        for (int i = 0; i < 100000; ++i)
            collect(&test, "0123456789012345678901234567890123456789012345678901234567890123456789\n");
        assert(test.collected_server_output.state == IPERF_OUTPUT_TRUNCATED);
        assert(test.collected_server_output.length == test.server_output_byte_limit);
        assert(test.collected_server_output.observed_bytes == 7100000);
    }
    cJSON *results = cJSON_CreateObject();
    assert(iperf_output_add_server_results(&test, results) == 0);
    /* The invalid fd intentionally fails AFTER bounded serialization. This
     * measures the real encoding allocation and cleanup, not socket success. */
    assert(iperf_output_write_results(&test, results) == -1);
    size_t serialization_capacity = IPERF_RESULT_CORE_MAX_BYTES + 6 * test.server_output_byte_limit + 1029;
    assert(largest_request == serialization_capacity);
    assert(peak_bytes < serialization_capacity + 2 * test.server_output_byte_limit + 4096);
    printf("server-%s-collection-and-serialization: requested_peak=%zu largest_request=%zu output=%zu\n",
        json ? "json" : "text", peak_bytes, largest_request, test.collected_server_output.length);
    cJSON_Delete(results);
    cJSON_Delete(interval);
    iperf_output_budget_reset(&test);
    assert(live_bytes == 0);
}

static size_t collector_failure(size_t failure)
{
    reset(failure);
    struct iperf_test test = {0};
    test.server_output_byte_limit = 256;
    test.ctrl_sck = -1;
    collect(&test, "%s", "example output");
    cJSON *results = cJSON_CreateObject();
    if (results && iperf_output_add_server_results(&test, results) == 0)
        assert(iperf_output_write_results(&test, results) == -1);
    size_t count = attempts;
    cJSON_Delete(results);
    iperf_output_budget_reset(&test);
    assert(live_bytes == 0);
    return count;
}

int main(void)
{
    collector_allocations(0);
    collector_allocations(1);
    size_t collector_attempts = collector_failure(0);
    for (size_t i = 1; i <= collector_attempts; ++i) collector_failure(i);
    printf("collector allocation failure cleanup: %zu/%zu\n", collector_attempts, collector_attempts);

    const char *stats = "\",\"streams\":[{\"id\":1,\"bytes\":123456}]}";
    struct input text = { .prefix = "{\"server_output_text\":\"", .suffix = stats, .repeated = 8 * 1024 * 1024 };
    check("large-text", text, 256 * 1024, IPERF_OUTPUT_TRUNCATED, 0);
    struct input json = { .prefix = "{\"server_output_json\":{\"data\":\"",
        .suffix = "\"},\"streams\":[{\"id\":1,\"bytes\":123456}]}", .repeated = text.repeated };
    check("large-json", json, 256 * 1024, IPERF_OUTPUT_DISCARDED, 0);
    struct input core = { .prefix = "{\"x\":\"", .suffix = "\"}", .repeated = IPERF_RESULT_CORE_MAX_BYTES - 8 };
    check("maximum-core-string", core, IPERF_OUTPUT_MAX_BYTES, IPERF_OUTPUT_MISSING, 0);

    /* Every allocation in a successful parse must be safely fail-able, including
     * allocations of nested cJSON values and keys after output was retained. */
    text.repeated = 128;
    size_t count = check("allocation-failure-baseline", text, 256, IPERF_OUTPUT_COMPLETE, 0);
    for (size_t i = 1; i <= count; ++i) check("failure", text, 256, IPERF_OUTPUT_INVALID, i);
    printf("allocation failure cleanup: %zu/%zu; all requested bytes released\n", count, count);

    /* Node-heavy core also exercises the independent node allocation budget. */
    size_t nodes = IPERF_RESULT_CORE_MAX_VALUES - 1;
    char *array = malloc(nodes * 2 + 16);
    assert(array);
    strcpy(array, "{\"x\":[");
    size_t length = strlen(array);
    for (size_t i = 0; i < nodes; ++i) {
        if (i) array[length++] = ',';
        array[length++] = '0';
    }
    strcpy(array + length, "]}");
    struct input dense = { .prefix = array, .suffix = "" };
    check("maximum-core-nodes", dense, 256, IPERF_OUTPUT_MISSING, 0);
    free(array);
    puts("PASS: bounded parser allocations, cleanup, AddressSanitizer and UndefinedBehaviorSanitizer");
    return 0;
}
