import Foundation

/// Twitch application credentials for IGDB's client-credentials flow. Kept as a
/// small local struct on purpose: the UI lane owns credential *storage*
/// (`KeychainStore` + a `CredentialsProviding` protocol) and wires it into
/// `IGDBClient`'s `credentials` closure next wave. Declaring our own type here avoids
/// a duplicate-declaration collision at merge.
struct IGDBCredentials: Sendable, Equatable {
    var clientID: String
    var secret: String
}

/// Errors surfaced by the IGDB token provider and client.
enum IGDBError: Error, Sendable, Equatable {
    /// No credentials were available (user has not entered them yet).
    case missingCredentials
    /// Twitch/IGDB returned an unexpected HTTP status. Body text is trimmed for logs.
    case http(status: Int, message: String)
    /// A response body could not be decoded into the expected shape.
    case decoding(String)
}
