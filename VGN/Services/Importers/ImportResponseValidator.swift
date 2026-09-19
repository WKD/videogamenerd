import Foundation

/// A raw HTTP response as it reaches the validator (PLAN §14.2 — validate *before*
/// anything else happens to it).
struct ImportRawResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// What the validator is told to expect for this particular request (PLAN §14.2 —
/// page echo, constant totals, previous item count for the emptiness check).
struct ImportValidationContext: Sendable, Equatable {
    var endpoint: String
    /// The page this request asked for (paged lists) — the response must echo it.
    var expectedPage: Int?
    /// Totals seen on earlier pages of this list — must stay constant.
    var expectedTotalPages: Int?
    var expectedTotalProducts: Int?
    /// Ids already seen across earlier pages — the response must not repeat them.
    var seenIDs: Set<String>
    /// The item count of the last **valid** cache for this key (suspicious-emptiness).
    var previousItemCount: Int?

    init(endpoint: String, expectedPage: Int? = nil,
         expectedTotalPages: Int? = nil, expectedTotalProducts: Int? = nil,
         seenIDs: Set<String> = [], previousItemCount: Int? = nil) {
        self.endpoint = endpoint
        self.expectedPage = expectedPage
        self.expectedTotalPages = expectedTotalPages
        self.expectedTotalProducts = expectedTotalProducts
        self.seenIDs = seenIDs
        self.previousItemCount = previousItemCount
    }
}

/// The verdict: valid (with the item count to cache and cross-check) or a reason to reject.
enum ImportValidation: Sendable, Equatable {
    case valid(itemCount: Int)
    case rejected(ImportRejectReason)

    var reason: ImportRejectReason? {
        if case .rejected(let r) = self { return r }
        return nil
    }
    var isValid: Bool { if case .valid = self { return true }; return false }
}

/// Every importer's response validator (PLAN §14.2). One method: turn a raw response +
/// context into a verdict. Implementations reuse ``ImportResponseChecks`` for the
/// source-agnostic gates and add their own schema / paging / emptiness rules.
protocol ImportResponseValidator: Sendable {
    func validate(_ response: ImportRawResponse, context: ImportValidationContext) -> ImportValidation
}

/// The source-agnostic "not bogus" gates shared by every importer (PLAN §14.2 /
/// §13.2): HTTP 200, JSON content type, not an HTML/login page, no rate-limit, no
/// auth challenge. Pure static functions so both GOG and (later) PSN reuse them and
/// they are directly unit-testable. Returns `nil` when the gate passes.
enum ImportResponseChecks {

    /// Run the transport-level gates in order. `nil` ⇒ passed; the body is real JSON
    /// and can be decoded by the source validator.
    static func transportReject(_ response: ImportRawResponse) -> ImportRejectReason? {
        // Rate-limit first: a 429 is a distinct, single-retry case.
        if response.status == 429 {
            let after = response.header("Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .rateLimited(retryAfter: after)
        }
        // 401/403 or a captcha/auth challenge status → auth failure.
        if response.status == 401 || response.status == 403 {
            return .authChallenge
        }
        guard response.status == 200 else {
            return .wrongStatus(response.status)
        }
        // A login/HTML page returned with a 200 (very common when signed out).
        if looksLikeHTML(response) {
            return .loginPageOrHTML
        }
        // Declared non-JSON content type.
        if let ct = response.header("Content-Type"),
           !ct.lowercased().contains("json"),
           !ct.lowercased().contains("text/plain") {
            return .notJSON
        }
        // Body must at least parse as JSON.
        guard let parsed = try? JSONSerialization.jsonObject(with: response.body) else {
            return .notJSON
        }
        // An error envelope (`error` / `errors`) is never valid data (PLAN §14.2).
        if let object = parsed as? [String: Any], object["error"] != nil || object["errors"] != nil {
            return .errorEnvelope
        }
        return nil
    }

    /// Heuristic HTML/login-page detection: an HTML content type, or a body that opens
    /// with `<` / an html/doctype tag (a signed-out GOG call returns the login page).
    static func looksLikeHTML(_ response: ImportRawResponse) -> Bool {
        if let ct = response.header("Content-Type")?.lowercased(),
           ct.contains("text/html") {
            return true
        }
        let head = String(decoding: response.body.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || head.hasPrefix("<")
    }
}
