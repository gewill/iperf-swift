# ``IperfSwift/IperfConfiguration``

## Topics

### Creating a Configuration

- ``init()``

### Role and Endpoint

- ``role``
- ``address``
- ``port``
- ``addressFamily``
- ``bindDevice``

### Transport and Streams

- ``prot``
- ``mode``
- ``numStreams``
- ``rate``
- ``blockSize``
- ``socketBufferSize``
- ``noDelay``
- ``mss``
- ``clientPort``

### Traffic Marking and Payload

- ``dscp``
- ``tos``
- ``dontFragment``
- ``udpCounters64Bit``
- ``repeatingPayload``

### End Conditions and Timeouts

- ``duration``
- ``numberOfBytes``
- ``timeout``
- ``rcvTimeout``

### Server Behavior

- ``oneOff``
- ``idleTimeout``

### Reporting and Logging

- ``reporterInterval``
- ``omit``
- ``getServerOutput``
- ``logfile``
- ``verbose``

### Authentication

- ``isAuth``
- ``usePkcs1Padding``

### Client Authentication

- ``username``
- ``password``
- ``publicKey``

### Server Authentication

- ``privateKey``
- ``authorizedUsers``
- ``timeSkewThreshold``

### Compatibility

- ``reverse``
- ``statsInterval``
