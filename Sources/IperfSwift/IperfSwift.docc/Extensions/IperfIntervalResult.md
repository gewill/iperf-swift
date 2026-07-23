# ``IperfSwift/IperfIntervalResult``

## Topics

### Creating a Result

- ``init(runnerState:debugDescription:state:error:prot:)``

### Throughput and Byte Counts

- ``throughput``
- ``totalBytes``

### Streams and Directions

- ``streams``
- ``upload``
- ``download``

### UDP Counters

- ``totalPackets``
- ``totalLostPackets``
- ``totalOutoforderPackets``
- ``averageJitter``

### Interval Timing

- ``duration``
- ``startTime``
- ``endTime``

### Run State

- ``state``
- ``runnerState``
- ``prot``
- ``mode``
- ``debugDescription``

### Errors

- ``error``
- ``hasError``

### Recomputing Aggregates

- ``evaluate()``
- ``evaulate()``

### Identity

- ``id``

### Compatibility

- ``reverse``
- ``averageRtt``
