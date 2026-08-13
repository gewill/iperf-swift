import Foundation
import XCTest

struct UnsupportedIperfVersionError: LocalizedError {
    let executable: String
    let reportedVersion: String

    var errorDescription: String? {
        "CLI interoperability requires iperf 3.21, but \(executable) reports: \(reportedVersion)"
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
            of: #"^iperf 3\.21(?:\s|\()"#,
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
}
