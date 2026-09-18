import Foundation
@testable import VGN

/// A `ClaudeBinaryResolving` that hands back a fixed URL (a generated fake script),
/// skipping real discovery and version probing.
struct StubClaudeResolver: ClaudeBinaryResolving {
    let url: URL
    let error: ClaudeCLIError?
    init(url: URL) { self.url = url; self.error = nil }
    init(error: ClaudeCLIError) { self.url = URL(fileURLWithPath: "/nonexistent"); self.error = error }
    func resolve() throws -> URL {
        if let error { throw error }
        return url
    }
}

/// Builds a throwaway executable `sh` script that stands in for `claude`. The script
/// records the argv and its (scrubbed) environment into `outputDir`, optionally
/// sleeps, prints a canned stdout, and exits with a chosen code.
enum FakeClaudeCLI {
    struct Script {
        let executable: URL
        let outputDir: URL

        /// The argv the script received (one entry per element, in order), preserving
        /// empty-string arguments. NUL-separated to disambiguate a genuine "" arg.
        func recordedArguments() -> [String] {
            let url = outputDir.appendingPathComponent("args.txt")
            guard let data = try? Data(contentsOf: url) else { return [] }
            var parts = data.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            if parts.last == "" { parts.removeLast() }   // trailing separator artifact
            return parts
        }

        /// The environment the script saw, as `KEY=VALUE` lines.
        func recordedEnvironment() -> [String: String] {
            let url = outputDir.appendingPathComponent("env.txt")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
            var out: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                out[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            return out
        }
    }

    /// - Parameters:
    ///   - stdout: what the script prints on stdout (the CLI envelope, usually).
    ///   - exitCode: process exit status.
    ///   - sleepSeconds: seconds to sleep before printing (to exercise timeouts).
    static func make(stdout: String, exitCode: Int32 = 0, sleepSeconds: Double = 0) throws -> Script {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-fakecli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stdoutFile = dir.appendingPathComponent("stdout.json")
        try stdout.write(to: stdoutFile, atomically: true, encoding: .utf8)

        let sleepLine = sleepSeconds > 0 ? "sleep \(sleepSeconds)" : ":"
        let out = dir.path
        let body = """
        #!/bin/sh
        /usr/bin/env > "\(out)/env.txt"
        : > "\(out)/args.txt"
        for a in "$@"; do printf '%s\\0' "$a" >> "\(out)/args.txt"; done
        \(sleepLine)
        /bin/cat "\(out)/stdout.json"
        exit \(exitCode)
        """
        let script = dir.appendingPathComponent("claude")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return Script(executable: script, outputDir: dir)
    }

    /// A minimal valid text envelope with the given result.
    static func textEnvelope(result: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"\#(result)","num_turns":1,"total_cost_usd":0.01}"#
    }

    /// A minimal structured envelope carrying `structured_output`.
    static func structuredEnvelope(json: String) -> String {
        #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":\#(json),"num_turns":2,"total_cost_usd":0.02,"usage":{"input_tokens":100,"output_tokens":50}}"#
    }
}
