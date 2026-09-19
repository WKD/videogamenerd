import Foundation

/// GOG account-API DTOs (PLAN §14.3). Shapes are from the community-documented,
/// decade-stable `embed.gog.com` responses that every open-source GOG client uses;
/// each field VGN relies on is marked with an `ASSUMPTION(G0)` where G2–G5 must
/// confirm it against a real response. Decoding is **lenient on unknown fields**
/// (extra keys ignored) but **strict on the required ones** (a missing required field
/// is a `schemaMismatch` reject).
///
/// No DTO here was recorded from a live account — all sample data is synthetic.

// MARK: - userData.json (account, PLAN §14.3)

/// `embed.gog.com/userData.json`. Required: `isLoggedIn`. `username` present when
/// signed in (shown in Settings). ASSUMPTION(G0): `userId` is a string; confirm at G2.
struct GOGUserData: Decodable, Sendable, Equatable {
    let isLoggedIn: Bool
    let username: String?
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case isLoggedIn
        case username
        case userId
    }
}

// MARK: - user/data/games (owned ids, PLAN §14.3)

/// `embed.gog.com/user/data/games`. ASSUMPTION(G0): the payload is `{ "owned": [id…] }`
/// with integer product ids; confirm at G3.
struct GOGOwnedGames: Decodable, Sendable, Equatable {
    let owned: [Int64]
}

// MARK: - account/getFilteredProducts (library page, PLAN §14.3)

/// One `getFilteredProducts` page. Required: `products`, `page`, `totalPages`,
/// `totalProducts` (PLAN §14.2). Everything else is lenient.
struct GOGProductsPage: Decodable, Sendable, Equatable {
    let page: Int
    let totalPages: Int
    let totalProducts: Int
    let productsPerPage: Int?
    let products: [GOGProduct]

    enum CodingKeys: String, CodingKey {
        case page, totalPages, totalProducts, productsPerPage, products
    }
}

/// One owned product. Required: `id`, `title`, `worksOn` (PLAN §14.2). The rest drive
/// the platform + noise rules and are optional/lenient.
/// ASSUMPTION(G0): `category` carries soundtrack/DLC hints and `dlcCount`/`isGame`/
/// `isHidden` exist as modelled — confirm the exact fields at G4/G5.
struct GOGProduct: Decodable, Sendable, Equatable {
    let id: Int64
    let title: String
    let worksOn: GOGWorksOn
    let image: String?
    let url: String?
    let slug: String?
    let category: String?
    let isGame: Bool?
    let isMovie: Bool?
    let isHidden: Bool?
    let dlcCount: Int?
    let releaseDate: GOGReleaseDate?

    enum CodingKeys: String, CodingKey {
        case id, title, worksOn, image, url, slug, category
        case isGame, isMovie, isHidden, dlcCount, releaseDate
    }
}

/// GOG's `worksOn` platform triple. All optional — absence reads as "does not run there".
struct GOGWorksOn: Decodable, Sendable, Equatable {
    let windows: Bool?
    let mac: Bool?
    let linux: Bool?

    enum CodingKeys: String, CodingKey {
        case windows = "Windows"
        case mac = "Mac"
        case linux = "Linux"
    }

    var runsOnWindows: Bool { windows ?? false }
    var runsOnMac: Bool { mac ?? false }
    var runsOnLinux: Bool { linux ?? false }
}

/// GOG's release date is inconsistent across the API surface: sometimes a Unix
/// timestamp, sometimes an object `{ "date": "2015-05-18 …" }`, sometimes a plain
/// string, sometimes null. This decodes any of those and exposes just the `year`, the
/// only thing the matcher needs (PLAN §14.3 tie-breaker).
/// ASSUMPTION(G0): the shapes above cover what `getFilteredProducts` returns — confirm at G4.
struct GOGReleaseDate: Decodable, Sendable, Equatable {
    let year: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let ts = try? container.decode(Double.self) {
            self.year = Self.year(fromUnix: ts)
        } else if let s = try? container.decode(String.self) {
            self.year = Self.year(fromString: s)
        } else if let object = try? decoder.container(keyedBy: ObjectKeys.self) {
            if let ts = try? object.decode(Double.self, forKey: .date) {
                self.year = Self.year(fromUnix: ts)
            } else if let s = try? object.decode(String.self, forKey: .date) {
                self.year = Self.year(fromString: s)
            } else {
                self.year = nil
            }
        } else {
            self.year = nil
        }
    }

    init(year: Int?) { self.year = year }

    private enum ObjectKeys: String, CodingKey { case date }

    private static func year(fromUnix ts: Double) -> Int? {
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        return Calendar(identifier: .gregorian).component(.year, from: date)
    }

    /// Pull a 1970…2099 four-digit year from the front of a "YYYY-MM-DD …" string.
    private static func year(fromString s: String) -> Int? {
        let head = s.prefix(4)
        guard head.count == 4, head.allSatisfy(\.isNumber), let y = Int(head),
              (1970...2099).contains(y) else { return nil }
        return y
    }
}

// MARK: - auth.gog.com/token (OAuth token, PLAN §14.1)

/// The OAuth token response from `auth.gog.com/token` (authorization-code + refresh).
/// Required: `access_token`, `refresh_token`, `expires_in`. `user_id` / `session_id`
/// are kept only to redact them, never logged or cached.
/// ASSUMPTION(G0): field names as below (the Galaxy client's documented response) —
/// confirm at G1.
struct GOGTokenDTO: Decodable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let userId: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userId = "user_id"
        case sessionId = "session_id"
    }
}
