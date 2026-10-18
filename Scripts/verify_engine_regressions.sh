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
with socket.socket() as reservation:
    reservation.bind(('127.0.0.1', 0))
    port = reservation.getsockname()[1]
with tempfile.TemporaryFile() as output:
    server = subprocess.Popen([cli, '-s', '-B', '127.0.0.1', '-p', str(port), '-1'], stdout=output, stderr=output)
    try:
        # Observe the listening FD without consuming a one-off connection.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if server.poll() is not None:
                output.seek(0)
                raise RuntimeError(output.read().decode())
            probe = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-p', str(server.pid), '-iTCP:'+str(port), '-sTCP:LISTEN'], capture_output=True)
            if probe.returncode == 0:
                break
            time.sleep(.02)
        else:
            raise RuntimeError('CLI server did not establish its listener')
        subprocess.run([binary, str(port)], check=True, timeout=15)
        assert server.wait(timeout=5) == 0
    finally:
        if server.poll() is None:
            server.terminate()
            try: server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
PY
