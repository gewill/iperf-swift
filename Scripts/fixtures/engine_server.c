#include "iperf_server_api.c"
#include <assert.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/ioctl.h>

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

static void teardown_hung(int sig)
{
    static const char message[] = "FAIL: teardown is still joining a sender blocked in sendfile()\n";
    (void)sig;
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(3);
}

/* A zerocopy sender whose peer stops reading parks in sendfile(). Cancelling
 * it interrupts that call at most once: when part of the block was already
 * sent, Nsendfile() reports progress and the send loop re-enters sendfile(),
 * which then blocks for good. A block larger than the loopback buffers puts
 * the worker in exactly that state. */
static struct iperf_test *start_blocked_zerocopy_sender(int *peer)
{
    struct iperf_test *test = iperf_new_test();
    assert(test && iperf_defaults(test) == 0);
    iperf_set_test_role(test, 's');
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t length = sizeof(address);
    assert(listener >= 0 && bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0 && getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    *peer = socket(AF_INET, SOCK_STREAM, 0);
    assert(*peer >= 0 && connect(*peer, (struct sockaddr *)&address, sizeof(address)) == 0);
    int stream_socket = accept(listener, NULL, NULL);
    /* As iperf_tcp_accept() does for every TCP stream. A fixed send buffer
     * keeps autotuning from absorbing the block. */
    int send_buffer = 16384;
    assert(stream_socket >= 0 && iperf_set_socket_no_sigpipe(stream_socket) == 0);
    assert(setsockopt(stream_socket, SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof(send_buffer)) == 0);
    close(listener);
    test->zerocopy = 1;
    test->settings->blksize = MAX_BLOCKSIZE;
    struct iperf_stream *stream = iperf_new_stream(test, stream_socket, 1);
    assert(stream);
    stream->green_light = 1;
    assert(pthread_create(&stream->thr, NULL, iperf_server_worker_run, stream) == 0);
    stream->thread_created = 1;
    /* A full, unchanging receive queue means the worker is parked inside
     * sendfile() with part of its block already queued. */
    int last = -1, stable = 0;
    for (int i = 0; i < 500 && stable < 20; ++i) {
        usleep(10000);
        int queued = 0;
        assert(ioctl(*peer, FIONREAD, &queued) == 0);
        stable = (queued > 0 && queued == last) ? stable + 1 : 0;
        last = queued;
    }
    assert(stable == 20);
    return test;
}

void verify_teardown_unblocks_zerocopy_sender(void)
{
    int peer, control[2];
    signal(SIGALRM, teardown_hung);

    struct iperf_test *test = start_blocked_zerocopy_sender(&peer);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, control) == 0);
    test->ctrl_sck = control[0];
    TimerClientData data = {.p = test};
    struct iperf_time now;
    assert(iperf_time_now(&now) == 0);
    alarm(10);
    server_timer_proc(data, &now);
    alarm(0);
    assert(SLIST_EMPTY(&test->streams) && test->ctrl_sck == -1);
    /* The woken sender's write error must not replace the watchdog's. */
    assert(iperf_get_error() == IESERVERTESTDURATIONEXPIRED);
    close(control[1]);
    close(peer);
    iperf_free_test(test);

    /* stop() and every failed run tear down through cleanup_server(). */
    test = start_blocked_zerocopy_sender(&peer);
    iperf_set_error(IENONE);
    alarm(10);
    cleanup_server(test);
    alarm(0);
    assert(iperf_get_error() == IENONE);
    close(peer);
    iperf_free_test(test);
    signal(SIGALRM, SIG_DFL);
}

static void skip_callback(struct iperf_test *test)
{
    (void)test;
}

/* TEST_END and CLIENT_TERMINATE close every stream socket before teardown joins
 * the workers. By then another part of the host may own that number, so
 * stopping the worker must not shut it down. */
void verify_released_stream_descriptors_stay_untouched(void)
{
    const signed char states[] = {TEST_END, CLIENT_TERMINATE};
    for (size_t i = 0; i < sizeof(states); ++i) {
        struct iperf_test *test = iperf_new_test();
        assert(test && iperf_defaults(test) == 0);
        iperf_set_test_role(test, 's');
        test->stats_callback = skip_callback;
        test->reporter_callback = skip_callback;
        int stream_pair[2], control[2], reuse[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, stream_pair) == 0);
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, control) == 0);
        /* As iperf_accept() does for the control connection. */
        assert(iperf_set_socket_no_sigpipe(control[0]) == 0);
        test->ctrl_sck = control[0];
        struct iperf_stream *stream = iperf_new_stream(test, stream_pair[0], 1);
        assert(stream);
        assert(write(control[1], &states[i], 1) == 1);
        /* TEST_END then fails to request results; the streams are released first. */
        close(control[1]);
        (void)iperf_handle_message_server(test);
        assert(fcntl(stream_pair[0], F_GETFD) == -1 && errno == EBADF);
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, reuse) == 0);
        assert(iperf_set_socket_no_sigpipe(reuse[0]) == 0);
        assert(dup2(reuse[0], stream_pair[0]) == stream_pair[0]);
        stop_stream_worker(test, stream);
        char byte = 1;
        assert(write(stream_pair[0], &byte, 1) == 1 && read(reuse[1], &byte, 1) == 1);
        close(stream_pair[0]); close(stream_pair[1]);
        close(reuse[0]); close(reuse[1]);
        close(control[0]);
        test->ctrl_sck = -1;
        iperf_free_test(test);
    }
}
