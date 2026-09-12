#!/bin/sh
# Exercise the vendored authentication boundary under AddressSanitizer using
# the same static OpenSSL framework as SwiftPM. No saved keys or CLI are needed.
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
framework="$repo_root/.build/artifacts/openssl-spm/libssl/OpenSSL.Package.xcframework/macos-arm64_x86_64"
if [ ! -d "$framework/libssl.framework" ]; then
    echo "Resolve package dependencies first: swift package resolve" >&2
    exit 1
fi
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/iperf-auth-safety.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

cat > "$work_dir/auth_safety.c" <<'C'
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libssl/openssl/evp.h>
#include <libssl/openssl/rsa.h>
#include <libssl/openssl/crypto.h>
#include "iperf_config.h"
#include "iperf_auth.h"

int Base64Encode(const unsigned char *, size_t, char **);
int Base64Decode(const char *, unsigned char **, size_t *);
int encrypt_rsa_message(const char *, EVP_PKEY *, unsigned char **, int);
int decrypt_rsa_message(const unsigned char *, int, EVP_PKEY *, unsigned char **, int);

int main(void)
{
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    EVP_PKEY *key = NULL;
    assert(ctx != NULL);
    assert(EVP_PKEY_keygen_init(ctx) > 0);
    assert(EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, 2048) > 0);
    assert(EVP_PKEY_keygen(ctx, &key) > 0);
    EVP_PKEY_CTX_free(ctx);

    /* Both calls overwrote a 256-byte heap allocation in upstream 3.21. */
    unsigned char oversized[1024], *output = NULL;
    memset(oversized, 'x', sizeof(oversized));
    oversized[sizeof(oversized) - 1] = '\0';
    assert(encrypt_rsa_message((char *)oversized, key, &output, 0) == 0);
    assert(output == NULL);
    assert(decrypt_rsa_message(oversized, sizeof(oversized), key, &output, 0) == 0);
    assert(output == NULL);

    for (int padding = 0; padding <= 1; ++padding) {
        char *token = NULL, *username = NULL, *password = NULL;
        time_t timestamp = 0;
        assert(encode_auth_setting("audit", "password", key, &token, padding) == 0);
        assert(decode_auth_setting(0, token, key, &username, &password, &timestamp, padding) == 0);
        assert(strcmp(username, "audit") == 0 && strcmp(password, "password") == 0);
        free(token);
        free(username);
        free(password);
    }

    /* All three Base64 padding lengths must retain exact binary data. */
    for (size_t count = 1; count <= 129; ++count) {
        unsigned char input[129], *decoded = NULL;
        for (size_t i = 0; i < count; ++i)
            input[i] = (unsigned char)i;
        char *encoded = NULL;
        size_t decoded_length = 0;
        assert(Base64Encode(input, count, &encoded) == 0);
        assert(Base64Decode(encoded, &decoded, &decoded_length) == 0);
        assert(decoded_length == count && memcmp(input, decoded, count) == 0);
        free(encoded);
        free(decoded);
    }
    const char *invalid[] = { "", "A", "====", "AA=A", "AAAA=", "AA A", "AAAA!AAA" };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) {
        unsigned char *decoded = NULL;
        size_t decoded_length = 42;
        assert(Base64Decode(invalid[i], &decoded, &decoded_length) != 0);
        assert(decoded == NULL && decoded_length == 0);
    }
    EVP_PKEY_free(key);
    return 0;
}
C

"${CC:-clang}" -g -O1 -fsanitize=address \
    -I "$repo_root/Sources/IperfCLib/include" -F "$framework" \
    "$repo_root/Sources/IperfCLib/iperf_auth.c" "$work_dir/auth_safety.c" \
    -framework libssl -framework Security -o "$work_dir/auth_safety"
"$work_dir/auth_safety"
echo "PASS: authentication bounds, failure cleanup, Base64 and RSA round trips"
