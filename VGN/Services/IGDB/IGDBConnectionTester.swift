import Foundation

/// Settings "Test connection" logic (PLAN §5.1): fetch a Twitch token with the
/// given credentials and run one trivial IGDB query, mapping the outcome to a
/// human-readable result. The UI lane calls this from the Settings sheet; the
/// logic lives here in the services lane.
struct IGDBConnectionTester: Sendable {
    private let transport: HTTPTransport
    private let catalog: PlatformCatalog

    init(transport: HTTPTransport = URLSessionTransport(), catalog: PlatformCatalog) {
        self.transport = transport
        self.catalog = catalog
    }

    /// A successful connection: a short human message plus the game count the probe
    /// query returned (proves auth + a real query round-trip).
    struct Success: Sendable, Equatable {
        var message: String
        var sampleCount: Int
    }

    /// A failed connection, already turned into something worth showing a user.
    struct Failure: Error, Sendable, Equatable {
        var message: String
    }

    /// Fetch a token and run one probe query. Returns a human-readable result.
    func test(credentials: IGDBCredentials) async -> Result<Success, Failure> {
        guard !credentials.clientID.isEmpty, !credentials.secret.isEmpty else {
            return .failure(Failure(message: "Enter both a Client ID and a Client Secret."))
        }
        // A dedicated client with a no-op cache: the probe should not pollute the
        // real catalogue cache, and no rate-limit history is shared.
        let client = IGDBClient(
            transport: transport,
            credentials: { credentials },
            catalog: catalog,
            cache: InMemoryCatalogCache()
        )
        do {
            let results = try await client.searchGames("the legend of zelda", limit: 1)
            return .success(Success(message: "Connected to IGDB.", sampleCount: results.count))
        } catch {
            return .failure(Failure(message: Self.humanMessage(for: error)))
        }
    }

    /// Turn a thrown error into a short, actionable sentence.
    static func humanMessage(for error: Error) -> String {
        switch error {
        case IGDBError.missingCredentials:
            return "No credentials were provided."
        case let IGDBError.http(status, _):
            return httpMessage(status: status)
        case IGDBError.decoding:
            return "IGDB returned a response VGN could not read. Try again."
        case let status as HTTPStatusError:
            return httpMessage(status: status.status)
        case let urlError as URLError:
            return "Network error: \(urlError.localizedDescription)"
        default:
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    private static func httpMessage(status: Int) -> String {
        switch status {
        case 400, 401, 403:
            return "IGDB rejected the credentials (HTTP \(status)). Check the Client ID and Secret."
        case 429:
            return "IGDB is rate-limiting the request (HTTP 429). Wait a moment and try again."
        case 500...599:
            return "IGDB is having trouble (HTTP \(status)). Try again shortly."
        default:
            return "IGDB returned HTTP \(status)."
        }
    }
}
