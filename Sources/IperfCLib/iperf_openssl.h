#ifndef IPERF_OPENSSL_H
#define IPERF_OPENSSL_H

/* openssl-spm 4 packages headers inside a static framework. */
#if defined(__has_include)
#if __has_include(<libssl/openssl/bio.h>)
#define IPERF_OPENSSL_FRAMEWORK_HEADERS 1
#endif
#endif

#if defined(IPERF_OPENSSL_FRAMEWORK_HEADERS)
#include <libssl/openssl/bio.h>
#include <libssl/openssl/buffer.h>
#include <libssl/openssl/core_names.h>
#include <libssl/openssl/err.h>
#include <libssl/openssl/evp.h>
#include <libssl/openssl/pem.h>
#include <libssl/openssl/rsa.h>
#include <libssl/openssl/sha.h>
#else
#include <openssl/bio.h>
#include <openssl/buffer.h>
#include <openssl/core_names.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>
#endif

#undef IPERF_OPENSSL_FRAMEWORK_HEADERS

#endif
