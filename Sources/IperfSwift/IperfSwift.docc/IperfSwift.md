# ``IperfSwift``

Run the embedded iperf3 engine as a Swift client or server.

## Overview

Create an ``IperfConfiguration``, pass it to ``IperfRunner``, and receive
periodic ``IperfIntervalResult`` values while the test runs. The wrapper supports
TCP and UDP tests, plus authentication, DSCP, interface binding, and interval
statistics.

Callbacks aren't guaranteed to run on a specific queue. Dispatch UI updates to
the main actor or main queue, and keep terminal-state handling idempotent.

## Topics

### Examples

- <doc:UsingIperfSwift>

### Running a Test

- ``IperfConfiguration``
- ``IperfRunner``
- ``IperfRunnerState``

### Callbacks

- ``reporterFunctionType``
- ``errorFunctionType``
- ``runnerStateFunctionType``
- ``jsonStreamFunctionType``

### Protocol Configuration

- ``IperfProtocol``
- ``IperfRole``
- ``IperfTestMode``
- ``IperfDirection``
- ``IperfAddressFamily``

### Results

- ``IperfIntervalResult``
- ``IperfDirectionalIntervalResult``
- ``IperfStreamIntervalResult``
- ``IperfThroughput``

### Engine State and Errors

- ``IperfState``
- ``IperfError``
