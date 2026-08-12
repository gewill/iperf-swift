#!/bin/sh -e

REPO_URL="https://github.com/esnet/iperf.git"
TAG="${1:-3.21}"
CHECKOUT_PATH="iperf3"
SRC_PATH="Sources/IperfCLib"
SYNC_DATA="iperf_sync"
STAGING_PATH="${SRC_PATH}.sync-tmp"

cd "$(dirname "$0")"

cleanup() {
    rm -rf "$CHECKOUT_PATH" "$STAGING_PATH"
}
trap cleanup EXIT INT TERM

echo "Checking out $REPO_URL (tag $TAG)"
rm -rf "$CHECKOUT_PATH"
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
rm -rf "$STAGING_PATH"
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
perl -0pi -e 's/(#define[ \t]+__FLOW_LABEL_H[ \t]*\n)\n*/$1\n#ifdef __linux__\n/; s/(\n#define IPV6_FLOWINFO_SEND\s+33\s*\n\s*#endif\s*)\z/$1\n#endif\n/' "$STAGING_PATH/include/flowlabel.h"

perl -0pi -e 's/if \( !\(test->server_rsa_private_key && test->server_authorized_users\)\) \{\n        return 0;\n    \}/if (!test->server_rsa_private_key && !test->server_authorized_users) {\n        return 0;\n    }\n\n    if (!(test->server_rsa_private_key && test->server_authorized_users)) {\n        i_errno = IEAUTHTEST;\n        return -1;\n    }/; s/(\tif \(rc\) \{\n)\t    return -1;/$1\t    i_errno = IEAUTHTEST;\n\t    return -1;/; s/(        \} else \{\n)(            if \(test->debug\) \{)/$1            i_errno = IEAUTHTEST;\n$2/; s/(\n    \}\n    return -1;\n\}\n#endif \/\/HAVE_SSL)/\n    }\n    i_errno = IEAUTHTEST;\n    return -1;\n}\n#endif \/\/HAVE_SSL/' "$STAGING_PATH/iperf_api.c"

if [ ! -d "$SYNC_DATA/custom_files" ]; then
    echo "Missing $SYNC_DATA/custom_files" >&2
    exit 1
fi
cp "$SYNC_DATA/custom_files/"*.c "$STAGING_PATH/"
cp "$SYNC_DATA/custom_files/"*.h "$STAGING_PATH/include/"

find "$STAGING_PATH" -type f \( -name '*.c' -o -name '*.h' \) \
    -exec perl -pi -e 's/<stdatomic\.h>/<iperf_stdatomic.h>/g' {} +
find "$STAGING_PATH" -name '*.orig' -delete

echo "Verifying synchronized sources"
grep -Fq '#ifdef __linux__' "$STAGING_PATH/include/flowlabel.h"
test "$(grep -c '#ifdef __linux__' "$STAGING_PATH/include/flowlabel.h")" -eq 1
grep -Fq 'if (i_errno == IENONE)' "$STAGING_PATH/iperf_client_api.c"
grep -Fq 'if (i_errno == IENONE)' "$STAGING_PATH/iperf_server_api.c"
grep -Fq 'if (i_errno == IENONE)' "$STAGING_PATH/iperf_udp.c"
grep -Fq 'IEBINDDEVNOSUPPORT' "$STAGING_PATH/net.c"
grep -Fq '#include <File.h>' "$STAGING_PATH/include/iperf_util.h"
grep -Fq '#include <iperf_stdatomic.h>' "$STAGING_PATH/include/iperf.h"
grep -Fq '#include <iperf_stdatomic.h>' "$STAGING_PATH/include/iperf_api.h"
grep -Fq '#define HAVE_SSL 1' "$STAGING_PATH/include/iperf_config.h"
grep -Fq 'iperf_set_test_use_pkcs1_padding' "$STAGING_PATH/iperf_api.c"
grep -Fq 'if (!test->server_rsa_private_key && !test->server_authorized_users)' "$STAGING_PATH/iperf_api.c"
grep -Fq 'i_errno = IEAUTHTEST' "$STAGING_PATH/iperf_api.c"

rm -rf "$SRC_PATH"
mv "$STAGING_PATH" "$SRC_PATH"

echo "$SRC_PATH is now updated to version $TAG!"
