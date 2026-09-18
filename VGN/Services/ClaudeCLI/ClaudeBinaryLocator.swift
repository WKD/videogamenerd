import Foundation

/// Resolves a usable `claude` binary and validates its version (PLAN §6.2:
/// GUI apps don't inherit the shell `PATH`, so we auto-detect with a login shell
/// and a manual override, then check `claude --version` against a minimum).
///
/// Order (first hit wins): explicit override → `zsh -lc 'command -v claude'` →
/// common install locations. The two subprocess seams (`candidateSource`,
/// `versionProbe`) are injectable so tests never spawn a real shell.
protocol ClaudeBinaryResolving: Sendable {
    /// A validated, existing, version-checked binary URL, or a typed error.
    func resolve() throws -> URL
}

struct ClaudeBinaryLocator: ClaudeBinaryResolving {
    /// A user-provided absolute path (Settings override). Tried first when set.
    var explicitOverride: String?
    /// Minimum acceptable version.
    var minimumVersion: ClaudeCLIVersion
    /// Common non-PATH install locations, tilde-expanded.
    var knownLocations: [String]
    /// Returns the ordered candidate paths beyond the override / known locations
    /// (default: `zsh -lc 'command -v claude'`). Injected for tests.
    var commandVSource: @Sendable () -> String?
    /// Runs `<path> --version` and returns its stdout (or nil on any failure).
    /// Injected for tests.
    var versionProbe: @Sendable (String) -> String?
    /// Whether a path exists as a regular file. Injected for tests.
    var fileExists: @Sendable (String) -> Bool

    init(
        explicitOverride: String? = nil,
        minimumVersion: ClaudeCLIVersion = .minimumSupported,
        knownLocations: [String] = ClaudeBinaryLocator.defaultKnownLocations,
        commandVSource: @escaping @Sendable () -> String? = { ClaudeShellProbe.commandV() },
        versionProbe: @escaping @Sendable (String) -> String? = { ClaudeShellProbe.version(ofBinaryAt: $0) },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.explicitOverride = explicitOverride
        self.minimumVersion = minimumVersion
        self.knownLocations = knownLocations
        self.commandVSource = commandVSource
        self.versionProbe = versionProbe
        self.fileExists = fileExists
    }

    static let defaultKnownLocations: [String] = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ].map { ($0 as NSString).expandingTildeInPath }

    /// The ordered, de-duplicated candidate paths.
    func candidatePaths() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String?) {
            guard let raw, !raw.isEmpty else { return }
            let path = (raw as NSString).expandingTildeInPath
            if seen.insert(path).inserted { out.append(path) }
        }
        add(explicitOverride)
        add(commandVSource()?.trimmingCharacters(in: .whitespacesAndNewlines))
        for location in knownLocations { add(location) }
        return out
    }

    func resolve() throws -> URL {
        let candidates = candidatePaths()
        var sawExistingBinary = false
        var deferredError: ClaudeCLIError?

        for path in candidates where fileExists(path) {
            sawExistingBinary = true
            guard let raw = versionProbe(path), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                deferredError = deferredError ?? .unparsableVersion("(no output from \(path) --version)")
                continue
            }
            guard let version = ClaudeCLIVersion(parsing: raw) else {
                deferredError = deferredError ?? .unparsableVersion(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            guard version >= minimumVersion else {
                deferredError = deferredError ?? .versionTooOld(found: version.description, minimum: minimumVersion.description)
                continue
            }
            return URL(fileURLWithPath: path)
        }

        if let deferredError { throw deferredError }
        if sawExistingBinary {
            throw ClaudeCLIError.unparsableVersion("(no candidate reported a version)")
        }
        throw ClaudeCLIError.notInstalled(searched: candidates)
    }
}

/// Blocking subprocess helpers used only for binary discovery and the version probe
/// (both fast, one-shot). The main recognition path uses the full async runner.
enum ClaudeShellProbe {
    /// `zsh -lc 'command -v claude'` → the resolved path, or nil.
    static func commandV() -> String? {
        capture(executable: "/bin/zsh", arguments: ["-lc", "command -v claude"], timeout: 5)
            .flatMap { $0.exitCode == 0 ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `<path> --version` → its stdout, or nil on any failure.
    static func version(ofBinaryAt path: String) -> String? {
        capture(executable: path, arguments: ["--version"], timeout: 8)
            .flatMap { $0.exitCode == 0 ? $0.stdout : nil }
    }

    struct Capture { var stdout: String; var exitCode: Int32 }

    /// Run a short command and capture stdout. Returns nil if it can't launch or
    /// overruns `timeout`. Stdin is closed; environment is inherited (safe here — no
    /// API request is made by `command -v` or `--version`).
    static func capture(executable: String, arguments: [String], timeout: TimeInterval) -> Capture? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Enforce a wall-clock timeout without blocking forever.
        let deadline = Date().addingTimeInterval(timeout)
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return Capture(stdout: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }
}
