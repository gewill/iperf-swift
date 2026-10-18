/* Compile the real implementation in this test translation unit so private
 * protocol parsing is exercised without exporting test-only library APIs. */
#include "iperf_api.c"
#include <assert.h>
#include <sys/resource.h>

void verify_remote_parameters(void)
{
    const struct { const char *name; int value; int error; } cases[] = {
        {"parallel", 0, IENUMSTREAMS}, {"parallel", 129, IENUMSTREAMS},
        {"time", -1, IEDURATION}, {"omit", -1, IEOMIT},
        {"window", -1, IEBUFSIZE}, {"MSS", -1, IEMSS},
        {"TOS", 256, IEBADTOS}, {"bandwidth", -1, IERECVPARAMS},
        {"pacing_timer", -1, IERECVPARAMS}, {"gro", 2, IERECVPARAMS},
        {"len", 0, IEUDPBLOCKSIZE}, {"len", 11, IEUDPBLOCKSIZE},
        {"len", 65508, IEUDPBLOCKSIZE},
        {"parallel", 1, IENONE},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        struct iperf_test *test = iperf_new_test();
        assert(test && iperf_defaults(test) == 0);
        iperf_set_test_role(test, 's');
        assert(iperf_json_start(test) == 0);
        test->ctrl_sck = pair[1];
        cJSON *parameters = cJSON_CreateObject();
        cJSON_AddBoolToObject(parameters, "udp", 1);
        cJSON_AddNumberToObject(parameters, "len", 1400);
        cJSON_AddNumberToObject(parameters, "parallel", 1);
        cJSON_AddNumberToObject(parameters, "time", 1);
        cJSON_DeleteItemFromObjectCaseSensitive(parameters, cases[i].name);
        cJSON_AddNumberToObject(parameters, cases[i].name, cases[i].value);
        assert(JSON_write(pair[0], parameters) >= 0);
        cJSON_Delete(parameters);
        iperf_set_error(IENONE);
        int result = get_parameters(test);
        assert((result == 0) == (cases[i].error == IENONE));
        assert(iperf_get_error() == cases[i].error);
        assert(SLIST_EMPTY(&test->streams));
        close(pair[0]);
        close(pair[1]);
        test->ctrl_sck = -1;
        iperf_free_test(test);
    }
}

static int open_descriptor_count(void)
{
    int count = 0;
    for (int fd = 0; fd < 1024; ++fd)
        if (fcntl(fd, F_GETFD) >= 0) ++count;
    return count;
}

void verify_stream_failure_cleanup(void)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    int baseline = open_descriptor_count();
    for (int i = 0; i < 4; ++i) {
        int pair[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        /* Zero-length mmap fails after the temporary file has been opened. */
        test->settings->blksize = 0;
        assert(iperf_new_stream(test, pair[0], 1) == NULL);
        assert(iperf_get_error() == IECREATESTREAM);
        close(pair[0]);
        close(pair[1]);
        assert(open_descriptor_count() == baseline);
    }
    unsigned char entropy[32];
    assert(readentropy(entropy, sizeof(entropy)) == 0);
    assert(open_descriptor_count() == baseline);
    iperf_free_test(test);
}

/* Stream setup spends the last free descriptor on its buffer file. Payload and
 * cookie entropy must not need another one: running out used to exit the host
 * process from readentropy() instead of failing the run. */
void verify_entropy_under_descriptor_pressure(void)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    struct rlimit original, limited;
    assert(getrlimit(RLIMIT_NOFILE, &original) == 0);
    limited = original;
    if (limited.rlim_cur > 512)
        limited.rlim_cur = 512;
    assert(setrlimit(RLIMIT_NOFILE, &limited) == 0);
    int fillers[512], count = 0, fd;
    while (count < 512 && (fd = open("/dev/null", O_RDONLY)) >= 0)
        fillers[count++] = fd;
    assert(count > 0 && errno == EMFILE);
    char cookie[COOKIE_SIZE];
    make_cookie(cookie);
    close(fillers[--count]);
    assert(iperf_new_stream(test, pair[0], 1) != NULL);
    while (count > 0)
        close(fillers[--count]);
    (void)setrlimit(RLIMIT_NOFILE, &original);
    close(pair[0]);
    close(pair[1]);
    iperf_free_test(test);
}
