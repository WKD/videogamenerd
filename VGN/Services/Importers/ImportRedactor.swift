import Foundation

/// Scrubs identifiers out of anything an importer persists or logs (PLAN §14.2 /
/// §14.5 — tokens, cookies, user ids, e-mail, usernames never appear in the cache,
/// rejects, logs, prompts or commits). Pure and Foundation-only: it takes the known
/// literal values to remove (username, user id, session id, access/refresh tokens,
/// the OAuth `code`) plus a set of structural patterns (e-mail, bearer tokens,
/// `Set-Cookie`, long hex/opaque ids) and replaces every hit with `‹redacted›`.
struct ImportRedactor: Sendable {
    static let placeholder = "‹redacted›"

    /// Exact strings to remove verbatim (case-insensitive) — the values the caller
    /// actually holds (username, ids, tokens, the auth code).
    let literals: [String]

    init(literals: [String] = []) {
        // Only non-trivial literals (avoid nuking every "a"/"1" in a body).
        self.literals = literals
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    /// A redactor that knows no specific literals — still applies the structural
    /// patterns (e-mail, tokens, cookies, opaque ids).
    static let structural = ImportRedactor()

    func redact(_ input: String) -> String {
        var out = input
        for literal in literals {
            out = out.replacingOccurrences(of: literal, with: Self.placeholder,
                                           options: [.caseInsensitive])
        }
        for pattern in Self.patterns {
            out = pattern.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: Self.placeholder)
        }
        return out
    }

    /// Convenience closure form for the cache store's `recordReject(redact:)` hook.
    var closure: @Sendable (String) -> String { { self.redact($0) } }

    // MARK: - Structural patterns

    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // e-mail
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            // bearer / access / refresh tokens in JSON or headers
            #"(?i)(access_token|refresh_token|bearer|npsso|session_id|code)"[^"]*"\s*:?\s*"?[^"\s,}]+"?"#,
            // Set-Cookie / Cookie header values
            #"(?i)(set-)?cookie:\s*[^\r\n]+"#,
            // long opaque hex / base64-ish ids (≥ 24 chars)
            #"\b[A-Fa-f0-9]{24,}\b"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}
