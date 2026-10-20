import Darwin
import Foundation
import XCTest

struct UnsupportedIperfVersionError: LocalizedError {
    let executable: String
    let reportedVersion: String

    var errorDescription: String? {
        "CLI interoperability requires iperf 3.22, but \(executable) reports: \(reportedVersion)"
    }
}

enum IperfCLITestSupport {
    static func iperf3(candidates: [String]? = nil) throws -> String {
        let candidates = candidates ?? executableCandidates(
            named: "iperf3",
            overrideVariable: "IPERF3_PATH"
        )
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw XCTSkip("iperf3 is not installed")
        }

        let version = try version(of: executable)
        guard version.range(
            of: #"^iperf 3\.22(?:\s|\()"#,
            options: .regularExpression
        ) != nil else {
            throw UnsupportedIperfVersionError(
                executable: executable,
                reportedVersion: version
            )
        }
        return executable
    }

    static func executableCandidates(
        named name: String,
        overrideVariable: String
    ) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[overrideVariable] {
            return [override]
        }
        return environment["PATH", default: ""]
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
    }

    private static func version(of executable: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? "no version output"
    }

    /// The states of the TCP sockets process `pid` holds on `port`, read with
    /// lsof from outside the process, as `Scripts/verify_engine_regressions.sh`
    /// waits for a server.
    static func tcpSocketStates(pid: pid_t, port: Int) throws -> [String] {
        let lsof = Process()
        let output = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-Ts", "-FT"]
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsof.waitUntilExit()
        return report.split(separator: "\n").compactMap { field in
            field.hasPrefix("TST=") ? String(field.dropFirst(4)) : nil
        }
    }

    /// A port that no TCP or UDP socket on this host holds, on any address.
    ///
    /// The kernel's choice for `127.0.0.1:0` only avoids sockets on 127.0.0.1
    /// and the wildcard, and a port held on another address defeats the binds
    /// tests make. An `iperf3` server binds the dual-stack wildcard, which
    /// another user's socket on any address refuses: ports that root's
    /// `remoted` held on IPv6 addresses passed that probe, and `iperf3 -s`
    /// then exited with "Address already in use". A `clientPort` stream binds
    /// the IPv4 wildcard without `SO_REUSEADDR`, which any socket on the port
    /// refuses, and a UDP socket on the port takes a UDP run's datagrams. So a
    /// candidate is handed out only if ``isFree(port:)`` as well.
    ///
    /// The port is released before it is returned, so a server can still lose
    /// it; ``XCTestCase/startCLIServer(_:_:timeout:ports:)``
    /// starts such a server again on another port.
    static func freePort() throws -> Int {
        for _ in 0..<64 {
            guard let descriptor = boundSocket(SOCK_STREAM, AF_INET, port: 0, loopback: true) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
            }
            let candidate = boundPort(descriptor)
            close(descriptor)
            if let candidate, isFree(port: candidate) {
                return candidate
            }
        }
        throw POSIXError(.EADDRINUSE)
    }

    /// Whether `port` binds on the wildcard address of both families, for TCP
    /// and UDP, without `SO_REUSEADDR` — which any socket holding it refuses.
    /// Neither family stands in for the other: a dual-stack bind succeeds over
    /// a socket on the IPv4 wildcard.
    static func isFree(port: Int) -> Bool {
        [SOCK_STREAM, SOCK_DGRAM].allSatisfy { type in
            [AF_INET, AF_INET6].allSatisfy { family in
                guard let descriptor = boundSocket(type, family, port: port) else {
                    return false
                }
                close(descriptor)
                return true
            }
        }
    }

    /// A socket of `type` bound to `port` on the wildcard address of `family`,
    /// or on its loopback address; nil if the bind is refused. An IPv6 socket
    /// is dual-stack, the default.
    static func boundSocket(_ type: Int32, _ family: Int32, port: Int, loopback: Bool = false) -> Int32? {
        let descriptor = socket(family, type, 0)
        guard descriptor >= 0 else {
            return nil
        }
        let result: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            address.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: loopback ? in_addr_t(INADDR_LOOPBACK).bigEndian : 0)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0 else {
            let bindError = errno
            close(descriptor)
            errno = bindError
            return nil
        }
        return descriptor
    }

    /// A TCP socket listening on 127.0.0.1, at a port the kernel picks.
    static func boundListener() throws -> (descriptor: Int32, port: Int) {
        guard let descriptor = boundSocket(SOCK_STREAM, AF_INET, port: 0, loopback: true) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRNOTAVAIL)
        }
        guard listen(descriptor, 1) == 0, let port = boundPort(descriptor) else {
            let failure = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EADDRNOTAVAIL)
        }
        return (descriptor, port)
    }

    static func boundPort(_ descriptor: Int32) -> Int? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else {
            return nil
        }
        let family = Int32(address.ss_family)
        return withUnsafePointer(to: &address) {
            if family == AF_INET6 {
                return $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Int(UInt16(bigEndian: $0.pointee.sin6_port))
                }
            }
            return $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                Int(UInt16(bigEndian: $0.pointee.sin_port))
            }
        }
    }
}
