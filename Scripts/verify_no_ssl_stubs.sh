#!/usr/bin/env bash
#
# Verifies the no-SSL fallback in Sources/IperfCLib/custom.c.
#
# The package config (iperf_config.h) hardcodes HAVE_SSL=1, so the #else stub
# path for iperf_validate_client_rsa_pubkey / iperf_validate_server_rsa_privkey
# is never exercised by a normal `swift build` / `swift test`. Those symbols are
# declared unconditionally in custom.h and called unconditionally from Swift, so
# a build without OpenSSL must still define them or the link fails.
#
# This script compiles custom.c with HAVE_SSL forced off and asserts that both
# symbols are present as defined text symbols and that the object pulls in no
# OpenSSL references. Run locally or in CI; exits non-zero on any failure.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$repo_root/Sources/IperfCLib/custom.c"
include="$repo_root/Sources/IperfCLib/include"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp -R "$include" "$tmp/include"
# Disable the hardcoded HAVE_SSL so the #else fallback is the compiled path.
sed -i.bak 's/#define HAVE_SSL 1/\/* HAVE_SSL disabled by verify_no_ssl_stubs.sh *\//' \
    "$tmp/include/iperf_config.h"
rm -f "$tmp/include/iperf_config.h.bak"

if grep -q '#define HAVE_SSL 1' "$tmp/include/iperf_config.h"; then
    echo "FAIL: could not disable HAVE_SSL in the temp iperf_config.h" >&2
    exit 1
fi

obj="$tmp/custom.o"
# -include stdio.h: the standalone TU lacks the transitive include the full
# SwiftPM build provides; it does not affect which validate branch compiles.
"${CC:-clang}" -c "$src" -I "$tmp/include" -include stdio.h -o "$obj"

symbols="$(nm "$obj")"
status=0
for sym in _iperf_validate_client_rsa_pubkey _iperf_validate_server_rsa_privkey; do
    if echo "$symbols" | grep -qE "^[0-9a-f]+ T $sym$"; then
        echo "ok: $sym defined in the no-SSL build"
    else
        echo "FAIL: $sym is not a defined symbol without HAVE_SSL" >&2
        status=1
    fi
done

if nm -u "$obj" | grep -qiE 'EVP_|PEM_|BIO_'; then
    echo "FAIL: no-SSL object still references OpenSSL symbols" >&2
    nm -u "$obj" | grep -iE 'EVP_|PEM_|BIO_' >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "PASS: no-SSL RSA-validation stubs compile and link cleanly"
fi
exit "$status"
