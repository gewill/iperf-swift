#include "iperf_server_api.c"
#include <assert.h>

struct parked_worker {
    struct iperf_stream *stream;
    int ready[2];
    int park[2];
    int cleaned;
};

static void worker_cleanup(void *argument)
{
    struct parked_worker *worker = argument;
    /* The worker must still own a live stream and socket during cancellation.
     * ASan also detects a freed stream here if the watchdog frees too early. */
    assert(fcntl(worker->stream->socket, F_GETFD) >= 0);
    assert(__atomic_load_n(&worker->stream->done, __ATOMIC_SEQ_CST) == 1);
    worker->cleaned = 1;
}

static void *park_worker(void *argument)
{
    struct parked_worker *worker = argument;
    char byte = 1;
    pthread_cleanup_push(worker_cleanup, argument);
    assert(write(worker->ready[1], &byte, 1) == 1);
    (void)read(worker->park[0], &byte, 1);
    pthread_cleanup_pop(1);
    return NULL;
}

void verify_watchdog_joins_before_free(void)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    iperf_set_test_role(test, 's');
    int stream_pair[2], control_pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, stream_pair) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, control_pair) == 0);
    test->ctrl_sck = control_pair[0];
    struct iperf_stream *stream = iperf_new_stream(test, stream_pair[0], 0);
    assert(stream);
    struct parked_worker worker = {.stream = stream};
    assert(pipe(worker.ready) == 0 && pipe(worker.park) == 0);
    assert(pthread_create(&stream->thr, NULL, park_worker, &worker) == 0);
    stream->thread_created = 1;
    char byte;
    assert(read(worker.ready[0], &byte, 1) == 1);
    TimerClientData data = {.p = test};
    struct iperf_time now;
    assert(iperf_time_now(&now) == 0);
    server_timer_proc(data, &now);
    assert(worker.cleaned == 1);
    assert(SLIST_EMPTY(&test->streams));
    assert(test->ctrl_sck == -1);
    assert(fcntl(stream_pair[0], F_GETFD) == -1 && errno == EBADF);
    close(stream_pair[1]);
    close(control_pair[1]);
    close(worker.ready[0]); close(worker.ready[1]);
    close(worker.park[0]); close(worker.park[1]);
    iperf_free_test(test);
}
