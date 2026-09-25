import Foundation

/// Scrubs identifiers out of anything an importer persists or logs (PLAN §14.2 /
/// §14.5 — tokens, cookies, user ids, e-mail, usernames, IP addresses never appear in the
/// cache, rejects, logs, prompts or commits). Pure and Foundation-only: it first replaces
/// credential **values** while keeping key names (``redactSecretValues(_:)``, wave 21 E),
/// then the known literal values (username, user id, session id, access/refresh tokens,
/// the OAuth `code`), then a set of structural patterns (e-mail, bearer tokens,
/// `Set-Cookie`, long hex/opaque ids); every hit becomes `‹redacted›`.
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
        var out = Self.redactSecretValues(input)
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
            // bearer tokens in headers / text
            #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
            // Set-Cookie / Cookie header values
            #"(?i)(set-)?cookie:\s*[^\r\n]+"#,
            // long opaque hex / base64-ish ids (≥ 24 chars)
            #"\b[A-Fa-f0-9]{24,}\b"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    // MARK: - Secret values, shape kept (wave 21 E)

    /// Keys whose **value** is a credential. Matched case-insensitively as a whole JSON key;
    /// the key name stays, only the value becomes ``placeholder``.
    static let secretKeys: [String] = [
        "token", "access_token", "refresh_token", "id_token", "npsso", "authorization",
        "hpVal", "session_id",
    ]

    /// Replace credential **values** in a (possibly truncated) JSON or text excerpt while
    /// keeping the key names and the overall shape, so a reject excerpt still explains the
    /// mismatch (`{"token":"‹redacted›"}` says "token only, no hpKey/hpVal"):
    ///  - the value of any key in ``secretKeys`` (quoted or bare), a *string* `"code"` value,
    ///    and credentials in a URL query (`?code=…`, `&access_token=…`);
    ///  - an `Authorization:` header line's value;
    ///  - any base64 / base64url run (≥ 16 chars) that decodes to text carrying a browser
    ///    User-Agent (`|Mozilla`) or an IPv4 / IPv6 address — HowLongToBeat's `/init` token
    ///    is `<ms>::<caller IP>|<User-Agent>.<hex>` in base64;
    ///  - a plain IPv4 / IPv6 address.
    /// Works on text rather than a JSON round-trip, so a truncated excerpt is handled and
    /// the original formatting is preserved. Pure.
    static func redactSecretValues(_ input: String) -> String {
        var out = input
        // 1. "secretKey": "value" | bare value.
        out = secretKeyValue.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out),
            withTemplate: "$1\"\(NSRegularExpression.escapedTemplate(for: placeholder))\"")
        // 1b. "code": "<string>" (an OAuth code) — a numeric error code stays readable.
        out = stringCode.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out),
            withTemplate: "$1\"\(NSRegularExpression.escapedTemplate(for: placeholder))\"")
        // 1c. credentials in a URL query (`?code=…`, `&access_token=…`).
        out = queryCredential.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out),
            withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: placeholder))
        // 2. Authorization header lines.
        out = authorizationHeader.stringByReplacingMatches(
            in: out, range: NSRange(out.startIndex..., in: out),
            withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: placeholder))
        // 3. base64 runs that decode to an IP / a UA.
        out = replaceMatches(of: base64Run, in: out) { run in
            decodesToIdentifyingText(run) ? placeholder : nil
        }
        // 4. literal IP addresses.
        out = replaceMatches(of: ipv4, in: out) { _ in placeholder }
        out = replaceMatches(of: ipv6, in: out) { _ in placeholder }
        return out
    }

    /// Whether `run` base64- (or base64url-) decodes to UTF-8 text containing `|Mozilla`
    /// or an IP address.
    static func decodesToIdentifyingText(_ run: String) -> Bool {
        var b64 = run.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.hasSuffix("=") { b64.removeLast() }
        let pad = (4 - b64.count % 4) % 4
        guard pad != 3 else { return false }
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return false }
        if text.range(of: "|Mozilla", options: .caseInsensitive) != nil { return true }
        let range = NSRange(text.startIndex..., in: text)
        return ipv4.firstMatch(in: text, range: range) != nil
            || ipv6.firstMatch(in: text, range: range) != nil
    }

    private static func replaceMatches(of re: NSRegularExpression, in text: String,
                                       _ replacement: (String) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hit = ns.substring(with: m.range)
            guard let rep = replacement(hit) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += rep
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static let secretKeyValue: NSRegularExpression = {
        let keys = secretKeys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // "key" : "value (with escapes)"  |  "key" : bare-value
        let pattern = #"(?i)("(?:"# + keys + #")"\s*:\s*)(?:"(?:[^"\\]|\\.)*"?|[^\s,}\]]+)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let stringCode =
        try! NSRegularExpression(pattern: #"(?i)("code"\s*:\s*)"(?:[^"\\]|\\.)*"?"#)

    private static let queryCredential = try! NSRegularExpression(
        pattern: ##"(?i)([?&](?:code|token|access_token|refresh_token|id_token|npsso)=)[^&\s"#']+"##)

    private static let authorizationHeader =
        try! NSRegularExpression(pattern: #"(?im)^(\s*authorization\s*:\s*)[^\r\n]+"#)

    private static let base64Run =
        try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_-]{16,}={0,2}"#)

    private static let ipv4 = try! NSRegularExpression(
        pattern: #"(?<![\d.])(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}(?![\d.])"#)

    /// Full or `::`-compressed IPv6. Over-matching (e.g. `12::34`) only over-redacts — safe.
    private static let ipv6 = try! NSRegularExpression(
        pattern: #"(?i)(?<![0-9a-f:])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4})(?![0-9a-f:])"#)
}
