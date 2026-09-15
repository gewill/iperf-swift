/*
 * iperf, Copyright (c) 2014-2023, The Regents of the University of
 * California, through Lawrence Berkeley National Laboratory (subject
 * to receipt of any required approvals from the U.S. Dept. of
 * Energy).  All rights reserved.
 *
 * If you have questions about your rights to use or distribute this
 * software, please contact Berkeley Lab's Technology Transfer
 * Department at TTD@lbl.gov.
 *
 * NOTICE.  This software is owned by the U.S. Department of Energy.
 * As such, the U.S. Government has been granted for itself and others
 * acting on its behalf a paid-up, nonexclusive, irrevocable,
 * worldwide license in the Software to reproduce, prepare derivative
 * works, and perform publicly and display publicly.  Beginning five
 * (5) years after the date permission to assert copyright is obtained
 * from the U.S. Department of Energy, and subject to any subsequent
 * five (5) year renewals, the U.S. Government is granted for itself
 * and others acting on its behalf a paid-up, nonexclusive,
 * irrevocable, worldwide license in the Software to reproduce,
 * prepare derivative works, distribute copies to the public, perform
 * publicly and display publicly, and to permit others to do so.
 *
 * This code is distributed under a BSD style license, see the LICENSE file
 * for complete information.
 */

#include "iperf_config.h"

#include <string.h>
#include <time.h>
#include <sys/types.h>
/* FreeBSD needs _WITH_GETLINE to enable the getline() declaration */
#define _WITH_GETLINE
#include <stdio.h>
#include <termios.h>
#include <limits.h>
#include <inttypes.h>
#include <stdint.h>

#if defined(HAVE_SSL)

#include "iperf_openssl.h"

const char *auth_text_format = "user: %s\npwd:  %s\nts:   %"PRId64;

void sha256(const char *string, char outputBuffer[65])
{
    unsigned char hash[SHA256_DIGEST_LENGTH];

    SHA256((const unsigned char *) string, strlen(string), hash);
    int i = 0;
    for(i = 0; i < SHA256_DIGEST_LENGTH; i++)
    {
        snprintf(outputBuffer + (i * 2), 3, "%02x", hash[i]);
    }
    outputBuffer[64] = 0;
}

int check_authentication(const char *username, const char *password, const time_t ts, const char *filename, int skew_threshold){
    if (username == NULL || password == NULL || filename == NULL) {
        return 3;
    }

    time_t t = time(NULL);
    // Note: mktime(localtime(&t)) is essentially just t. 
    // We normalize to ensure we are comparing UTC seconds.
    if ( (t - ts) > skew_threshold || (t - ts) < -skew_threshold ) {
        return 1;
    }

    char passwordHash[65];
    char salted[strlen(username) + strlen(password) + 3];
    snprintf(salted, sizeof(salted), "{%s}%s", username, password);
    sha256(&salted[0], passwordHash);

    char *s_username, *s_password;

    char *text_copy = strdup(filename); // Create a copy of the input text
    if (text_copy == NULL) {
        return 3;
    }
    char *p = text_copy;

    // Tokenize the text by lines
    while (p) {
        char *line = strsep(&p, "\n");
        /* Preserve the CLI authorized-users file's CRLF and comment rules. */
        line[strcspn(line, "\r")] = '\0';
        if (*line == '\0' || *line == '#') {
            continue;
        }

        // Use strsep for thread-safe comma separation
        char *line_ptr = line;
        s_username = strsep(&line_ptr, ",");
        s_password = strsep(&line_ptr, ",");

        if (s_username != NULL && s_password != NULL) {
            if (strcmp(username, s_username) == 0 && strcmp(passwordHash, s_password) == 0) {
                free(text_copy);
                return 0;
            }
        }
    }

    free(text_copy);
    return 3;
}


int Base64Encode(const unsigned char* buffer, const size_t length, char** b64text) {
    if (b64text == NULL)
        return -1;
    *b64text = NULL;
    if (buffer == NULL || length == 0 || length > (INT_MAX / 4) * 3)
        return -1;

    size_t encoded_length = 4 * ((length + 2) / 3);
    char *encoded = malloc(encoded_length + 1);
    if (encoded == NULL)
        return -1;
    if (EVP_EncodeBlock((unsigned char *)encoded, buffer, (int)length) != encoded_length) {
        free(encoded);
        return -1;
    }
    *b64text = encoded;
    return 0;
}

size_t calcDecodeLength(const char* b64input) {
    if (b64input == NULL)
        return 0;
    size_t len = strlen(b64input), padding = 0;
    if (len >= 2 && b64input[len - 1] == '=' && b64input[len - 2] == '=')
        padding = 2;
    else if (len >= 1 && b64input[len - 1] == '=')
        padding = 1;
    return len / 4 * 3 >= padding ? len / 4 * 3 - padding : 0;
}

int Base64Decode(const char* b64message, unsigned char** buffer, size_t* length) {
    if (buffer == NULL || length == NULL)
        return -1;
    *buffer = NULL;
    *length = 0;
    if (b64message == NULL)
        return -1;
    size_t input_length = strlen(b64message);
    if (input_length == 0 || input_length > INT_MAX || input_length % 4 != 0)
        return -1;

    size_t decoded_length = calcDecodeLength(b64message);
    size_t padding = input_length / 4 * 3 - decoded_length;
    for (size_t i = 0; i < input_length - padding; ++i) {
        unsigned char c = b64message[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '+' || c == '/'))
            return -1;
    }
    unsigned char *decoded = malloc(input_length / 4 * 3 + 1);
    if (decoded == NULL)
        return -1;
    int result = EVP_DecodeBlock(decoded, (const unsigned char *)b64message, (int)input_length);
    if (result < 0 || (size_t)result != decoded_length + padding) {
        free(decoded);
        return -1;
    }
    decoded[decoded_length] = '\0';
    *buffer = decoded;
    *length = decoded_length;
    return 0;
}

EVP_PKEY *load_pubkey_from_file(const char *file) {
    BIO *key = NULL;
    EVP_PKEY *pkey = NULL;

    if (file) {
      key = BIO_new_file(file, "r");
      if (key != NULL) {
          pkey = PEM_read_bio_PUBKEY(key, NULL, NULL, NULL);
          BIO_free(key);
      }
    }
    return (pkey);
}

EVP_PKEY *load_pubkey_from_base64(const char *buffer) {
    unsigned char *key = NULL;
    size_t key_len;
    if (Base64Decode(buffer, &key, &key_len) != 0)
        return NULL;
    BIO *bio = BIO_new_mem_buf(key, (int)key_len);
    EVP_PKEY *pkey = bio ? PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL) : NULL;
    BIO_free(bio);
    free(key);
    return pkey;
}

EVP_PKEY *load_privkey_from_file(const char *file) {
    BIO *key = NULL;
    EVP_PKEY *pkey = NULL;

    if (file) {
      key = BIO_new_file(file, "r");
      if (key != NULL) {
          pkey = PEM_read_bio_PrivateKey(key, NULL, NULL, NULL);
          BIO_free(key);
      }
    }
    return (pkey);
}

EVP_PKEY *load_privkey_from_base64(const char *buffer) {
    unsigned char *key = NULL;
    size_t key_len;
    if (Base64Decode(buffer, &key, &key_len) != 0)
        return NULL;
    BIO *bio = BIO_new_mem_buf(key, (int)key_len);
    EVP_PKEY *pkey = bio ? PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL) : NULL;
    BIO_free(bio);
    free(key);
    return pkey;
}

int test_load_pubkey_from_file(const char *file){
    EVP_PKEY *key = load_pubkey_from_file(file);
    if (key == NULL){
        return -1;
    }
    EVP_PKEY_free(key);
    return 0;
}

int test_load_private_key_from_file(const char *file){
    EVP_PKEY *key = load_privkey_from_file(file);
    if (key == NULL){
        return -1;
    }
    EVP_PKEY_free(key);
    return 0;
}

int encrypt_rsa_message(const char *plaintext, EVP_PKEY *public_key, unsigned char **encryptedtext, int use_pkcs1_padding) {
    EVP_PKEY_CTX *ctx = NULL;
    unsigned char *output = NULL;
    size_t output_length = 0;
    int result = 0;
    if (encryptedtext == NULL)
        return 0;
    *encryptedtext = NULL;
    if (plaintext == NULL || public_key == NULL)
        return 0;

    ctx = EVP_PKEY_CTX_new(public_key, NULL);
    int padding = use_pkcs1_padding ? RSA_PKCS1_PADDING : RSA_PKCS1_OAEP_PADDING;
    size_t input_length = strlen(plaintext);
    /* Let EVP enforce the padding-specific limit without copying input into
     * an RSA-sized buffer. Oversized input must fail, never be truncated. */
    if (ctx == NULL || EVP_PKEY_encrypt_init(ctx) <= 0 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, padding) <= 0 ||
        EVP_PKEY_encrypt(ctx, NULL, &output_length, (const unsigned char *)plaintext, input_length) <= 0 ||
        output_length == 0 || output_length > INT_MAX)
        goto cleanup;
    output = OPENSSL_malloc(output_length);
    if (output == NULL ||
        EVP_PKEY_encrypt(ctx, output, &output_length, (const unsigned char *)plaintext, input_length) <= 0)
        goto cleanup;
    *encryptedtext = output;
    output = NULL;
    result = (int)output_length;

  cleanup:
    OPENSSL_free(output);
    EVP_PKEY_CTX_free(ctx);
    return result;
}

int decrypt_rsa_message(const unsigned char *encryptedtext, const int encryptedtext_len, EVP_PKEY *private_key, unsigned char **plaintext, int use_pkcs1_padding) {
    EVP_PKEY_CTX *ctx = NULL;
    unsigned char *output = NULL;
    size_t output_length = 0;
    int result = 0;
    if (plaintext == NULL)
        return 0;
    *plaintext = NULL;
    if (encryptedtext == NULL || encryptedtext_len <= 0 || private_key == NULL)
        return 0;

    ctx = EVP_PKEY_CTX_new(private_key, NULL);
    int padding = use_pkcs1_padding ? RSA_PKCS1_PADDING : RSA_PKCS1_OAEP_PADDING;
    if (ctx == NULL || EVP_PKEY_decrypt_init(ctx) <= 0 ||
        EVP_PKEY_CTX_set_rsa_padding(ctx, padding) <= 0 ||
        EVP_PKEY_decrypt(ctx, NULL, &output_length, encryptedtext, encryptedtext_len) <= 0 ||
        output_length == 0 || output_length > INT_MAX)
        goto cleanup;
    output = OPENSSL_malloc(output_length + 1);
    if (output == NULL ||
        EVP_PKEY_decrypt(ctx, output, &output_length, encryptedtext, encryptedtext_len) <= 0 ||
        output_length == 0)
        goto cleanup;
    output[output_length] = '\0';
    *plaintext = output;
    output = NULL;
    result = (int)output_length;

  cleanup:
    OPENSSL_free(output);
    EVP_PKEY_CTX_free(ctx);
    return result;
}

int encode_auth_setting(const char *username, const char *password, EVP_PKEY *public_key, char **authtoken, int use_pkcs1_padding){
    if (authtoken == NULL)
        return -1;
    *authtoken = NULL;
    if (username == NULL || password == NULL || public_key == NULL)
        return -1;
    time_t utc_seconds = time(NULL);

    /*
     * Compute a pessimistic/conservative estimate of storage required.
     * It's OK to allocate too much storage but too little is bad.
     */
    /* Reject credentials larger than the modulus before sizing the framing
     * buffer from them; EVP enforces the exact padding limit afterwards. */
    size_t username_len = strlen(username), password_len = strlen(password);
    int key_size = EVP_PKEY_size(public_key);
    if (key_size <= 0 || username_len > (size_t)key_size || password_len > (size_t)key_size)
        return -1;
    size_t text_len = strlen(auth_text_format) + username_len + password_len + 32;
    char *text = (char *) calloc(text_len, sizeof(char));
    if (text == NULL) {
        return -1;
    }
    snprintf(text, text_len, auth_text_format, username, password, (int64_t)utc_seconds);

    unsigned char *encrypted = NULL;
    int encrypted_len;
    encrypted_len = encrypt_rsa_message(text, public_key, &encrypted, use_pkcs1_padding);
    free(text);
    if (encrypted_len <= 0)
        return -1;
    int result = Base64Encode(encrypted, encrypted_len, authtoken);
    OPENSSL_free(encrypted);
    return result;
}

int decode_auth_setting(int enable_debug, const char *authtoken, EVP_PKEY *private_key, char **username, char **password, time_t *ts, int use_pkcs1_padding){
    if (username == NULL || password == NULL || ts == NULL)
        return -1;
    *username = NULL;
    *password = NULL;
    *ts = 0;
    unsigned char *encrypted_b64 = NULL;
    size_t encrypted_len_b64;
    int64_t utc_seconds = 0;
    if (Base64Decode(authtoken, &encrypted_b64, &encrypted_len_b64) != 0)
        return -1;

    unsigned char *plaintext = NULL;
    int plaintext_len;
    plaintext_len = decrypt_rsa_message(encrypted_b64, encrypted_len_b64, private_key, &plaintext, use_pkcs1_padding);
    free(encrypted_b64);
    if (plaintext_len <= 0) {
        return -1;
    }

    plaintext[plaintext_len] = '\0';

    char *s_username, *s_password;
    s_username = (char *) calloc(plaintext_len, sizeof(char));
    if (s_username == NULL) {
        OPENSSL_free(plaintext);
        return -1;
    }
    s_password = (char *) calloc(plaintext_len, sizeof(char));
    if (s_password == NULL) {
        OPENSSL_free(plaintext);
        free(s_username);
        return -1;
    }

    int rc = sscanf((char *) plaintext, auth_text_format, s_username, s_password, &utc_seconds);
    if (rc != 3) {
        OPENSSL_free(plaintext);
        free(s_password);
        free(s_username);
        return -1;
    }

    if (enable_debug) {
        printf("Auth Token Content:\n%s\n", plaintext);
        printf("Auth Token Credentials:\n--> %s %s\n", s_username, s_password);
    }
    *username = s_username;
    *password = s_password;
    *ts = (time_t)utc_seconds;
    OPENSSL_free(plaintext);
    return (0);
}

#endif //HAVE_SSL

ssize_t iperf_getpass (char **lineptr, size_t *n, FILE *stream) {
    struct termios old, new;
    ssize_t nread;

    /* Turn echoing off and fail if we can't. */
    if (tcgetattr (fileno (stream), &old) != 0)
        return -1;
    new = old;
    new.c_lflag &= ~ECHO;
    if (tcsetattr (fileno (stream), TCSAFLUSH, &new) != 0)
        return -1;

    /* Read the password. */
    printf("Password: ");
    nread = getline (lineptr, n, stream);

    /* Restore terminal. */
    (void) tcsetattr (fileno (stream), TCSAFLUSH, &old);

    //strip the \n or \r\n chars
    char *buf = *lineptr;
    int i;
    for (i = 0; buf[i] != '\0'; i++){
        if (buf[i] == '\n' || buf[i] == '\r'){
            buf[i] = '\0';
            break;
        }
    }

    return nread;
}
