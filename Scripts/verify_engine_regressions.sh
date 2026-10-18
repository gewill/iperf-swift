#!/usr/bin/env bash
# Private C paths are compiled into test translation units, not exported by the library.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_path="${SWIFT_BUILD_PATH:-$repo_root/.build}"
framework="$build_path/artifacts/openssl-spm/libssl/OpenSSL.Package.xcframework/macos-arm64_x86_64"
test -d "$framework/libssl.framework"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/iperf-engine-regressions.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM
sources=()
for source in "$repo_root"/Sources/IperfCLib/*.c; do
    case "$source" in */iperf_api.c|*/iperf_client_api.c|*/iperf_server_api.c|*/iperf_tcp.c|*/iperf_udp.c) continue ;; esac
    sources+=("$source")
done
"${CC:-clang}" -g -O1 -fsanitize=address \
    -I "$repo_root/Sources/IperfCLib/include" -I "$repo_root/Sources/IperfCLib" -F "$framework" \
    "${sources[@]}" "$repo_root"/Scripts/fixtures/engine_*.c \
    -framework libssl -framework Security -lpthread -lm -o "$work_dir/engine_regressions"
python3 - "$work_dir/engine_regressions" "${IPERF3_PATH:-iperf3}" <<'PY'
import socket, subprocess, sys, tempfile, time
binary, cli = sys.argv[1:]
version = subprocess.check_output([cli, '--version'], text=True)
assert version.splitlines()[0].startswith('iperf 3.22 '), version
subprocess.run([binary], check=True, timeout=15)

def serve(server_args, client_args):
    """Run a one-off server (port appended), then the client; the server must exit cleanly."""
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = str(reservation.getsockname()[1])
    with tempfile.TemporaryFile() as output:
        server = subprocess.Popen(server_args + [port], stdout=output, stderr=output)
        try:
            # Observe the listening FD without consuming a one-off connection.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    output.seek(0)
                    raise RuntimeError(output.read().decode())
                probe = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(server.pid), '-iTCP:'+port, '-sTCP:LISTEN'], capture_output=True)
                if probe.returncode == 0:
                    break
                time.sleep(.02)
            else:
                raise RuntimeError('server did not establish its listener')
            client = subprocess.run(client_args(port), capture_output=True, text=True, timeout=15)
            status = server.wait(timeout=10)
            output.seek(0)
            server_output = output.read().decode()
            assert status == 0, server_output + client.stdout + client.stderr
            return client.returncode, client.stdout + client.stderr, server_output
        finally:
            if server.poll() is None:
                server.terminate()
                try: server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill(); server.wait()

status, client_output, _ = serve([cli, '-s', '-B', '127.0.0.1', '-1', '-p'], lambda port: [binary, port])
assert status == 0, client_output
print(client_output.strip().splitlines()[-1])
# The embedded server runs out of descriptors partway through stream setup:
# an odd budget fails after accept(), an even one after the buffer file opens.
for slots in ('7', '8'):
    _, _, server_output = serve([binary, 'server', slots], lambda port: [cli, '-c', '127.0.0.1', '-p', port, '-P', '8', '-t', '1'])
    print(server_output.strip().splitlines()[-1])
PY
