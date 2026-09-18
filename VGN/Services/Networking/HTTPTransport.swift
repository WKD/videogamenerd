import Foundation

/// The single HTTP seam every service goes through. Production uses
/// `URLSessionTransport`; tests inject a `StubHTTPTransport` (see the test target)
/// so nothing touches the network. Chosen over a `URLProtocol` subclass because an
/// injected value type is simpler to drive deterministically from `async` actor
/// code (delays, cancellation, per-request scripting).
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Thrown when a response arrives but its status is not what the caller wanted.
/// Carries the body (small, for error messages) and any `Retry-After` so the retry
/// helper can honour it.
struct HTTPStatusError: Error, Sendable {
    let status: Int
    let body: Data
    let retryAfter: TimeInterval?

    /// Server explicitly asked us to slow down / try later.
    var isRetryable: Bool { status == 429 || (500...599).contains(status) }
}

/// Non-status transport failures we surface with intent.
enum TransportError: Error, Sendable {
    /// The `URLResponse` was not an `HTTPURLResponse` (should not happen for http/s).
    case notHTTP
}

/// `URLSession`-backed transport. `session` is injectable so a caller can hand in a
/// configured session (timeouts, no cookies) if it wants.
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.notHTTP
        }
        return (data, http)
    }
}

extension HTTPURLResponse {
    /// Parsed `Retry-After` (seconds only; the http-date form is rare here and
    /// treated as absent).
    var retryAfterSeconds: TimeInterval? {
        guard let raw = value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw.trimmingCharacters(in: .whitespaces))
    }
}
