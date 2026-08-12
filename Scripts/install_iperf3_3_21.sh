#!/usr/bin/env bash

set -euo pipefail

version="3.21"
archive_sha256="656e4405ebd620121de7ceca3eaf43a88f79ea1b857d041a6a0b1314801acdd8"
prefix="${1:-$PWD/.build/iperf3-$version}"
openssl_prefix="${OPENSSL_PREFIX:-}"

if [[ -z "$openssl_prefix" ]] && command -v brew >/dev/null 2>&1; then
    openssl_prefix="$(brew --prefix openssl@3)"
fi
if [[ -z "$openssl_prefix" || ! -d "$openssl_prefix" ]]; then
    echo "OpenSSL 3 not found; install openssl@3 or set OPENSSL_PREFIX" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
archive="$workdir/iperf-$version.tar.gz"
source_dir="$workdir/iperf-$version"
url="https://github.com/esnet/iperf/releases/download/$version/iperf-$version.tar.gz"

curl --fail --location --silent --show-error "$url" --output "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 --check
tar -xzf "$archive" -C "$workdir"

(
    cd "$source_dir"
    ./configure --prefix="$prefix" --with-openssl="$openssl_prefix"
    make -j"$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"
    make install
)

version_output="$($prefix/bin/iperf3 --version)"
if [[ "${version_output%%$'\n'*}" != "iperf $version "* ]]; then
    echo "Unexpected iperf3 version: ${version_output%%$'\n'*}" >&2
    exit 1
fi
if [[ "$version_output" != *"authentication"* ]]; then
    echo "The installed iperf3 does not report authentication support" >&2
    exit 1
fi

echo "Installed iperf $version at $prefix/bin/iperf3"
