#!/usr/bin/env bash
# Build the CLI interoperability baseline without replacing a global iperf3.
set -euo pipefail

prefix="${1:?Usage: install_test_iperf3.sh /absolute/install/prefix}"
case "$prefix" in
    /*) ;;
    *) echo "Install prefix must be an absolute path" >&2; exit 1 ;;
esac

tag="3.21"
revision="d39cf41526626b4e5a130f115d931cd6cbdffc19"
openssl_prefix="$(brew --prefix openssl@3)"
test -x "$openssl_prefix/bin/openssl"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/iperf-test-cli.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

git -C "$work_dir" init --quiet
git -C "$work_dir" -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 \
    fetch --depth 1 https://github.com/esnet/iperf.git "refs/tags/$tag:refs/tags/$tag"
resolved_revision="$(git -C "$work_dir" rev-parse "$tag^{commit}")"
if [[ "$resolved_revision" != "$revision" ]]; then
    echo "Unexpected iperf $tag source: $resolved_revision (expected $revision)" >&2
    exit 1
fi
git -C "$work_dir" checkout --quiet --detach "$revision"
(
    cd "$work_dir"
    ./configure --prefix="$prefix" --with-openssl="$openssl_prefix"
    make -j2
    make install
)

version_output="$("$prefix/bin/iperf3" --version 2>&1)"
first_line="${version_output%%$'\n'*}"
if [[ ! "$first_line" =~ ^iperf\ 3\.21([[:space:]]|\() ]]; then
    echo "Expected iperf 3.21, got: $first_line" >&2
    exit 1
fi
if [[ "$version_output" != *authentication* ]]; then
    echo "The installed iperf3 does not report authentication support" >&2
    exit 1
fi
printf '%s\n' "$version_output"
