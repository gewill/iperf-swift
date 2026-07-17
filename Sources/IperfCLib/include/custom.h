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


#endif /* Header_h */
