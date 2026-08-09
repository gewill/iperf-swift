//
//  Header.h
//  
//
//  Created by Igor Kim on 08.11.20.
//

#ifndef iperf_custom_h
#define iperf_custom_h

struct iperf_interval_results* extract_iperf_interval_results(struct iperf_stream* stream);

/* Defined in iperf_api.c since 3.21 but missing from iperf_api.h. */
struct iperf_time;
void iperf_set_test_idle_timeout(struct iperf_test* ipt, int to);
void iperf_set_test_rcv_timeout(struct iperf_test* ipt, struct iperf_time* to);

/* Defined in custom.c. */
void iperf_set_test_domain(struct iperf_test* ipt, int domain);
/* Atomically invalidates the stored descriptor before closing it. */
void iperf_close_test_listener(struct iperf_test* ipt);
/* Validate the in-memory Base64 PEM inputs used by the wrapper setters.
   Always defined: real checks under HAVE_SSL, otherwise stubs that report the
   key as invalid, so these declarations and their Swift callers always link. */
int iperf_validate_client_rsa_pubkey(const char* base64);
int iperf_validate_server_rsa_privkey(const char* base64);


#endif /* Header_h */
