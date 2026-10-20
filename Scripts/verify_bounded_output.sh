#!/bin/sh
# Measure requested heap allocations in the actual C parser and cJSON, isolated
# from the SDK process. Sanitizers catch bounds/undefined behavior separately.
set -eu
repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/iperf-bounded-output.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

for source in iperf_bounded_output iperf_bounded_socket iperf_output_budget cjson; do
    "${CC:-clang}" -std=c11 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all \
        -Dmalloc=result_test_malloc -Dfree=result_test_free -Drealloc=result_test_realloc \
        -I "$repo_root/Sources/IperfCLib/include" \
        -c "$repo_root/Sources/IperfCLib/$source.c" -o "$work_dir/$source.o"
done
"${CC:-clang}" -std=c11 -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=all \
    -I "$repo_root/Sources/IperfCLib/include" \
    "$repo_root/Scripts/fixtures/bounded_output_allocations.c" \
    "$work_dir/iperf_bounded_output.o" "$work_dir/iperf_bounded_socket.o" \
    "$work_dir/iperf_output_budget.o" "$work_dir/cjson.o" -o "$work_dir/bounded_output"
"$work_dir/bounded_output"
