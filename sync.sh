#!/bin/sh -e

REPO_URL="https://github.com/esnet/iperf.git"
TAG="${1:-3.21}"
SRC_PATH="Sources/IperfCLib"
SYNC_DATA="iperf_sync"
LOCK_PATH=".iperf-sync.lock"

cd "$(dirname "$0")"

WORK_PATH="$(mktemp -d "${TMPDIR:-/tmp}/iperf-swift-sync.XXXXXX")"
CHECKOUT_PATH="$WORK_PATH/iperf3"
STAGING_PATH="$WORK_PATH/IperfCLib"
LOCK_ACQUIRED=0

cleanup() {
    rm -rf "$WORK_PATH"
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        rmdir "$LOCK_PATH"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if ! mkdir "$LOCK_PATH" 2>/dev/null; then
    echo "Another synchronization is running ($LOCK_PATH exists)" >&2
    exit 1
fi
LOCK_ACQUIRED=1

echo "Checking out $REPO_URL (tag $TAG)"
mkdir "$CHECKOUT_PATH"
git -C "$CHECKOUT_PATH" init --quiet
git -C "$CHECKOUT_PATH" -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 \
    fetch --progress --depth 1 "$REPO_URL" "refs/tags/$TAG:refs/tags/$TAG"
git -C "$CHECKOUT_PATH" checkout --quiet "$TAG^{commit}"

echo "Configuring the source files"
if ! (cd "$CHECKOUT_PATH" && ./configure > configure.log 2>&1); then
    cat "$CHECKOUT_PATH/configure.log" >&2
    exit 1
fi

echo "Copying upstream source files"
mkdir -p "$STAGING_PATH/include"
cp "$CHECKOUT_PATH/src/"*.h "$STAGING_PATH/include"
cp "$CHECKOUT_PATH/src/"*.c "$STAGING_PATH/"
rm "$STAGING_PATH/main.c" "$STAGING_PATH/t_"*.c

echo "Applying local compatibility patches"
if [ ! -f "$SYNC_DATA/patches/modifications.patch" ]; then
    echo "Missing $SYNC_DATA/patches/modifications.patch" >&2
    exit 1
fi
patch --batch --forward -p1 -d "$STAGING_PATH" < "$SYNC_DATA/patches/modifications.patch"

# Inserts the guard and collapses the blank lines around it in one step. The
# substitution must match the pristine upstream header, which has no guard.
perl -0pi -e '
    $count = s/(#define[ \t]+__FLOW_LABEL_H[ \t]*\n)\n*/$1\n#ifdef __linux__\n/g;
    die "flowlabel start guard: expected 1 replacement, got $count\n" unless $count == 1;
    $count = s/(\n#define IPV6_FLOWINFO_SEND\s+33\s*\n\s*#endif\s*)\z/$1\n#endif\n/g;
    die "flowlabel end guard: expected 1 replacement, got $count\n" unless $count == 1;
' "$STAGING_PATH/include/flowlabel.h"

perl -0pi -e '
    $count = s/if \( !\(test->server_rsa_private_key && test->server_authorized_users\)\) \{\n        return 0;\n    \}/if (!test->server_rsa_private_key && !test->server_authorized_users) {\n        return 0;\n    }\n\n    if (!(test->server_rsa_private_key && test->server_authorized_users)) {\n        i_errno = IEAUTHTEST;\n        return -1;\n    }/g;
    die "server credentials check: expected 1 replacement, got $count\n" unless $count == 1;
    $count = s/(\tif \(rc\) \{\n)\t    return -1;/$1\t    i_errno = IEAUTHTEST;\n\t    return -1;/g;
    die "authentication token failure: expected 1 replacement, got $count\n" unless $count == 1;
    $count = s/(        \} else \{\n)(            if \(test->debug\) \{)/$1            i_errno = IEAUTHTEST;\n$2/g;
    die "authentication result failure: expected 1 replacement, got $count\n" unless $count == 1;
    $count = s/(\n    \}\n    return -1;\n\}\n#endif \/\/HAVE_SSL)/\n    }\n    i_errno = IEAUTHTEST;\n    return -1;\n}\n#endif \/\/HAVE_SSL/g;
    die "authentication fallback failure: expected 1 replacement, got $count\n" unless $count == 1;
' "$STAGING_PATH/iperf_api.c"

perl -0pi -e '
    $count = s/#include <openssl\/bio\.h>/typedef struct evp_pkey_st EVP_PKEY;/g;
    die "iperf_auth.h OpenSSL declaration: expected 1 replacement, got $count\n" unless $count == 1;
' "$STAGING_PATH/include/iperf_auth.h"
perl -0pi -e '
    $count = s/#include <openssl\/bio\.h>\n#include <openssl\/evp\.h>/typedef struct evp_pkey_st EVP_PKEY;/g;
    die "iperf.h OpenSSL declaration: expected 1 replacement, got $count\n" unless $count == 1;
' "$STAGING_PATH/include/iperf.h"

if [ ! -d "$SYNC_DATA/custom_files" ]; then
    echo "Missing $SYNC_DATA/custom_files" >&2
    exit 1
fi
cp "$SYNC_DATA/custom_files/"*.c "$STAGING_PATH/"
cp "$SYNC_DATA/custom_files/"*.h "$STAGING_PATH/include/"
mv "$STAGING_PATH/include/iperf_openssl.h" "$STAGING_PATH/iperf_openssl.h"

find "$STAGING_PATH" -type f \( -name '*.c' -o -name '*.h' \) \
    -exec perl -pi -e 's/<stdatomic\.h>/<iperf_stdatomic.h>/g' {} +
find "$STAGING_PATH" -name '*.orig' -delete

remaining_stdatomic="$(
    find "$STAGING_PATH" -type f \( -name '*.c' -o -name '*.h' \) \
        -exec grep -Fl '<stdatomic.h>' {} + || true
)"
if [ -n "$remaining_stdatomic" ]; then
    echo "Unconverted <stdatomic.h> references:" >&2
    echo "$remaining_stdatomic" >&2
    exit 1
fi

echo "Verifying synchronized sources"
grep -Fq '#ifdef __linux__' "$STAGING_PATH/include/flowlabel.h"
test "$(grep -c '#ifdef __linux__' "$STAGING_PATH/include/flowlabel.h")" -eq 1
test "$(grep -Fc 'if (i_errno == IENONE)' "$STAGING_PATH/iperf_client_api.c")" -eq 1
test "$(grep -Fc 'if (i_errno == IENONE)' "$STAGING_PATH/iperf_server_api.c")" -eq 1
test "$(grep -Fc 'if (i_errno == IENONE)' "$STAGING_PATH/iperf_udp.c")" -eq 2
grep -Fq 'IEBINDDEVNOSUPPORT' "$STAGING_PATH/net.c"
grep -Fq 'iperf_set_socket_no_sigpipe' "$STAGING_PATH/net.c"
grep -Fq 'iperf_set_socket_no_sigpipe' "$STAGING_PATH/iperf_server_api.c"
grep -Fq 'iperf_set_socket_no_sigpipe' "$STAGING_PATH/iperf_tcp.c"
grep -Fq '#include <File.h>' "$STAGING_PATH/include/iperf_util.h"
grep -Fq '#include <iperf_stdatomic.h>' "$STAGING_PATH/include/iperf.h"
grep -Fq '#include <iperf_stdatomic.h>' "$STAGING_PATH/include/iperf_api.h"
grep -Fq 'typedef struct evp_pkey_st EVP_PKEY;' "$STAGING_PATH/include/iperf.h"
grep -Fq 'typedef struct evp_pkey_st EVP_PKEY;' "$STAGING_PATH/include/iperf_auth.h"
grep -Fq '#include "iperf_openssl.h"' "$STAGING_PATH/iperf_api.c"
grep -Fq '#include "iperf_openssl.h"' "$STAGING_PATH/iperf_auth.c"
grep -Fq '#include "iperf_openssl.h"' "$STAGING_PATH/custom.c"
grep -Fq '#include <libssl/openssl/bio.h>' "$STAGING_PATH/iperf_openssl.h"
test ! -e "$STAGING_PATH/include/iperf_openssl.h"
grep -Fq 'iperf_openssl_version_major' "$STAGING_PATH/custom.c"
grep -Fq '#define HAVE_SSL 1' "$STAGING_PATH/include/iperf_config.h"
grep -Fq 'iperf_set_test_use_pkcs1_padding' "$STAGING_PATH/iperf_api.c"
grep -Fq 'free(test->server_authorized_users)' "$STAGING_PATH/iperf_api.c"
grep -Fq 'iperf_set_test_server_authorized_users(test, optarg)' "$STAGING_PATH/iperf_api.c"
grep -Fq 'if (!test->server_rsa_private_key && !test->server_authorized_users)' "$STAGING_PATH/iperf_api.c"
test "$(grep -Fc 'i_errno = IEAUTHTEST' "$STAGING_PATH/iperf_api.c")" -eq 4

rm -rf "$SRC_PATH"
mv "$STAGING_PATH" "$SRC_PATH"

echo "$SRC_PATH is now updated to version $TAG!"
