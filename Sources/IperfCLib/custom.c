//
//  custom.c
//  
//
//  Created by Igor Kim on 08.11.20.
//

#include "iperf.h"
#include "iperf_api.h"
#include <limits.h>
#include <queue.h>
#if defined(HAVE_SSL)
#include "iperf_auth.h"
#include <openssl/evp.h>
#include <openssl/pem.h>
#endif

struct iperf_interval_results* extract_iperf_interval_results(struct iperf_stream* stream) {
    struct iperf_interval_results* interval_results = TAILQ_LAST(&stream->result->interval_results, irlisthead);
    return interval_results;
}

/* libiperf 3.21 has no setter for the -4/-6 socket domain. */
void iperf_set_test_domain(struct iperf_test* ipt, int domain) {
    ipt->settings->domain = domain;
}

#if defined(HAVE_SSL)
int Base64Decode(const char* b64message, unsigned char** buffer, size_t* length);

static int reject_private_key_password(char* buffer, int size, int rwflag, void* userdata) {
    (void)buffer;
    (void)size;
    (void)rwflag;
    (void)userdata;
    return 0;
}

static EVP_PKEY* load_unencrypted_privkey_from_base64(const char* base64) {
    unsigned char* pem = NULL;
    size_t pem_length = 0;
    if (Base64Decode(base64, &pem, &pem_length) != 0 ||
        pem == NULL || pem_length == 0 || pem_length > INT_MAX) {
        free(pem);
        return NULL;
    }

    BIO* bio = BIO_new_mem_buf(pem, (int)pem_length);
    EVP_PKEY* key = bio == NULL
        ? NULL
        : PEM_read_bio_PrivateKey(bio, NULL, reject_private_key_password, NULL);
    BIO_free(bio);
    free(pem);
    return key;
}

int iperf_validate_client_rsa_pubkey(const char* base64) {
    EVP_PKEY* key = load_pubkey_from_base64(base64);
    if (key == NULL || EVP_PKEY_base_id(key) != EVP_PKEY_RSA) {
        EVP_PKEY_free(key);
        return -1;
    }
    EVP_PKEY_free(key);
    return 0;
}

int iperf_validate_server_rsa_privkey(const char* base64) {
    EVP_PKEY* key = load_unencrypted_privkey_from_base64(base64);
    if (key == NULL || EVP_PKEY_base_id(key) != EVP_PKEY_RSA) {
        EVP_PKEY_free(key);
        return -1;
    }
    EVP_PKEY_free(key);
    return 0;
}
#endif
