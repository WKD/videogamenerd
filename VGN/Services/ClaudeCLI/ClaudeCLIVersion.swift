import Foundation

/// A parsed semantic version of the `claude` CLI, plus the minimum this app targets.
///
/// `claude --version` prints e.g. `2.1.277 (Claude Code)`; we parse the leading
/// `major.minor.patch`. The minimum is a single tunable constant — bump it if a
/// future flag we rely on stops working on older releases.
struct ClaudeCLIVersion: Comparable, Sendable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The minimum supported release. The recognition invocation relies on
    /// `--output-format json`, `--json-schema`, `--permission-mode dontAsk` and
    /// `--allowedTools`, all present across the Claude Code 2.x line (installed here:
    /// 2.1.277). Tune if a newer flag becomes required.
    static let minimumSupported = ClaudeCLIVersion(major: 2, minor: 0, patch: 0)

    /// Parse the leading `x.y.z` out of a `claude --version` line. Extra tokens
    /// (like `(Claude Code)`) are ignored. Returns `nil` when no version is present.
    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // First whitespace-delimited token, then split on dots.
        guard let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
        else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              // Patch may carry a pre-release suffix like "277-beta"; take the digits.
              let patch = Int(parts[2].prefix(while: { $0.isNumber }))
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ClaudeCLIVersion, rhs: ClaudeCLIVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
