import Foundation

/// PSN API DTOs (PLAN §13.3). Shapes are ported from `achievements-app/psn-api` (commit
/// `1e9d9a806fcd884a4ddee8086bfe92594611da9f`), cross-checked against `isFakeAccount/psnawp`
/// and `andshrew/PlayStation-Trophies` — see `docs/psn-import.md`. Decoding is **lenient on
/// unknown fields** (extra keys ignored) but **strict on the required ones** (a missing
/// required field is a `schemaMismatch` reject). No DTO here was recorded from a live
/// account — all sample data is synthetic and clearly fake.
///
/// Every field VGN relies on but has not yet seen on a real response is an
/// `ASSUMPTION(S0)` the matching live step verifies.

/// The one JSON decoder every PSN DTO is decoded through. PSN timestamps are ISO-8601
/// (`lastUpdatedDateTime`, `firstPlayedDateTime`, …), sometimes with fractional seconds,
/// so the strategy tries both forms and falls back to "no date" rather than throwing —
/// a date is never a *required* field.
enum PSNJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            // Formatters are not `Sendable`, so build them inside the `@Sendable` closure.
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            // Unparseable timestamp → distantPast rather than a hard failure; callers that
            // care (last-played) treat distantPast as "unknown".
            return Date.distantPast
        }
        return decoder
    }()
}

// MARK: - OAuth token (…/token, PLAN §13.1)

/// The token response from `…/oauth/token`. Required: `access_token`, `refresh_token`,
/// `expires_in`. `refresh_token_expires_in` gives the ~2-month refresh window; `id_token`
/// is ignored. ASSUMPTION(S0): field names as psn-api documents — verified at S1.
struct PSNTokenDTO: Decodable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let refreshTokenExpiresIn: Int?
    let tokenType: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case tokenType = "token_type"
        case scope
    }
}

// MARK: - Profile (…/userProfile/…/me/profiles, PLAN §13.3)

/// The profile response — a token-is-mine sanity check (PLAN §13.3). Only the online id
/// and account id are read (both scrubbed from fixtures). ASSUMPTION(S0): the envelope
/// nests under `profile` with these keys — verified at S2.
struct PSNProfile: Decodable, Sendable, Equatable {
    let onlineId: String?
    let accountId: String?

    enum RootKeys: String, CodingKey { case profile }
    enum ProfileKeys: String, CodingKey {
        case onlineId, accountId
        case onlineIdAlt = "online_id"
        case accountIdAlt = "account_id"
    }

    init(from decoder: Decoder) throws {
        // Accept both `{ "profile": { … } }` and a bare `{ … }` (sources disagree; §13.3
        // says `…/me/profiles`, psnawp shows a nested `profile`).
        let root = try decoder.container(keyedBy: RootKeys.self)
        let nested = try? root.nestedContainer(keyedBy: ProfileKeys.self, forKey: .profile)
        let c = try nested ?? decoder.container(keyedBy: ProfileKeys.self)
        onlineId = (try? c.decode(String.self, forKey: .onlineId))
            ?? (try? c.decode(String.self, forKey: .onlineIdAlt))
        accountId = (try? c.decode(String.self, forKey: .accountId))
            ?? (try? c.decode(String.self, forKey: .accountIdAlt))
    }
}

// MARK: - Trophy titles (…/trophy/v1/users/me/trophyTitles, PLAN §13.3)

/// One page of trophy titles — the launch history (the only PS3/Vita source). Required:
/// `trophyTitles`, `totalItemCount`. `nextOffset` drives paging.
struct PSNTrophyTitlesPage: Decodable, Sendable, Equatable {
    let trophyTitles: [PSNTrophyTitle]
    let totalItemCount: Int
    let nextOffset: Int?
    let previousOffset: Int?
}

/// One trophy title = one game I have trophies in (title, platform, earned counts, last
/// activity). VGN keeps only "≥ 1 earned ⇒ played" — no trophy detail is ever fetched or
/// stored (PLAN §13.3). Required: `npCommunicationId`, `trophyTitleName`,
/// `trophyTitlePlatform`, `progress`.
struct PSNTrophyTitle: Decodable, Sendable, Equatable {
    let npCommunicationId: String
    let trophyTitleName: String
    /// e.g. `"PS5"`, `"PS4"`, `"PS3"`, `"PSVITA"`, or a combined `"PS4,PS5"`.
    let trophyTitlePlatform: String
    /// `trophy` (PS3/Vita) or `trophy2` (PS4/PS5).
    let npServiceName: String?
    /// 0…100.
    let progress: Int
    let earnedTrophies: PSNEarnedTrophies?
    let lastUpdatedDateTime: Date?
    let hiddenFlag: Bool?

    enum CodingKeys: String, CodingKey {
        case npCommunicationId, trophyTitleName, trophyTitlePlatform, npServiceName
        case progress, earnedTrophies, lastUpdatedDateTime, hiddenFlag
    }
}

struct PSNEarnedTrophies: Decodable, Sendable, Equatable {
    let bronze: Int?
    let silver: Int?
    let gold: Int?
    let platinum: Int?

    var total: Int { (bronze ?? 0) + (silver ?? 0) + (gold ?? 0) + (platinum ?? 0) }
}

// MARK: - Game list (…/gamelist/v2/users/me/titles, PLAN §13.3)

/// One page of the PS4/PS5 game list — play time, play count, first/last played. Required:
/// `titles`, `totalItemCount`.
struct PSNGameListPage: Decodable, Sendable, Equatable {
    let titles: [PSNGameListTitle]
    let totalItemCount: Int
    let nextOffset: Int?
    let previousOffset: Int?
}

/// One played PS4/PS5 title. `playDuration` is an ISO-8601 duration string (e.g.
/// `PT228H56M33S`) — parsed to seconds by ``PSNDuration``. Required: `titleId`, `name`.
/// ASSUMPTION(S0): `service`/`category` are the disc-vs-digital candidates (PLAN §13.3
/// point 3) — inspected at S5.
struct PSNGameListTitle: Decodable, Sendable, Equatable {
    let titleId: String
    let name: String
    let localizedName: String?
    let category: String?
    let service: String?
    let playCount: Int?
    let firstPlayedDateTime: Date?
    let lastPlayedDateTime: Date?
    /// ISO-8601 duration string; nil/blank ⇒ unknown.
    let playDuration: String?
    let concept: PSNConcept?

    /// Parsed play time in seconds, or nil when `playDuration` is absent/unparseable.
    var playDurationSeconds: Int? {
        playDuration.flatMap(PSNDuration.seconds(fromISO8601:))
    }
}

struct PSNConcept: Decodable, Sendable, Equatable {
    let id: Int64?
}

// MARK: - Purchases (GraphQL getPurchasedGameList, PLAN §13.3)

/// The GraphQL envelope for `getPurchasedGameList`. A GraphQL `errors[]` array means the
/// operation failed (e.g. persisted-query-not-found) even at HTTP 200 — the validator
/// treats it as a reject (PLAN §13.2).
struct PSNPurchasedGamesEnvelope: Decodable, Sendable, Equatable {
    let data: DataNode?
    let errors: [PSNGraphQLError]?

    struct DataNode: Decodable, Sendable, Equatable {
        let purchasedTitlesRetrieve: Retrieve?
    }
    struct Retrieve: Decodable, Sendable, Equatable {
        let games: [PSNPurchasedGame]?
    }
}

struct PSNGraphQLError: Decodable, Sendable, Equatable {
    let message: String?
    let extensions: Extensions?
    struct Extensions: Decodable, Sendable, Equatable { let code: String? }
}

/// One purchased entitlement. `membership` marks a PS Plus claim vs a bought copy
/// (PLAN §13.3 — `PS_PLUS` vs `NONE`, but unknown values kept raw and shown). Required:
/// `name`. A free-to-play entitlement is a normal owned digital copy (price is irrelevant).
struct PSNPurchasedGame: Decodable, Sendable, Equatable {
    let name: String
    let platform: String?
    /// `PS_PLUS`, `NONE`, or an unknown value kept raw (PLAN §13.3).
    let membership: String?
    let isActive: Bool?
    let isDownloadable: Bool?
    let isPreOrder: Bool?
    let entitlementId: String?
    let productId: String?
    let titleId: String?
    let conceptId: String?
    let image: PSNImage?

    struct PSNImage: Decodable, Sendable, Equatable { let url: String? }

    /// A stable external id for the staging row: the entitlement id, else product, else
    /// title, else concept.
    var stableExternalID: String? {
        entitlementId ?? productId ?? titleId ?? conceptId
    }
}

// MARK: - ISO-8601 duration parser (PLAN §13.3 — playDuration → seconds)

/// A strict ISO-8601 **duration** parser for the game list's `playDuration` (PLAN §13.3),
/// e.g. `PT228H56M33S`, `PT0S`, `P1DT2H`. Handles the date part (`Y`/`M`/`W`/`D`) and the
/// time part (`H`/`M`/`S`) after `T`. Deliberately conservative: it rejects anything not
/// shaped like a real duration (returns nil) rather than guessing, so a garbage value
/// becomes "no play time" not a wrong number. Years/months are treated as 365/30 days —
/// they never appear in a play time, but the parser stays total.
enum PSNDuration {
    static func seconds(fromISO8601 raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.first == "P" else { return nil }
        var body = Substring(s.dropFirst())
        guard !body.isEmpty else { return nil }

        var total = 0.0
        var sawAny = false
        var inTime = false

        // Split into date part and (optional) time part at `T`.
        while let ch = body.first {
            if ch == "T" {
                inTime = true
                body = body.dropFirst()
                continue
            }
            // Read a number (integer or decimal for seconds).
            var numStr = ""
            while let d = body.first, d.isNumber || d == "." {
                numStr.append(d)
                body = body.dropFirst()
            }
            guard let value = Double(numStr), let unit = body.first else { return nil }
            body = body.dropFirst()
            let seconds: Double
            switch (inTime, unit) {
            case (false, "Y"): seconds = value * 365 * 86_400
            case (false, "M"): seconds = value * 30 * 86_400
            case (false, "W"): seconds = value * 7 * 86_400
            case (false, "D"): seconds = value * 86_400
            case (true, "H"):  seconds = value * 3_600
            case (true, "M"):  seconds = value * 60
            case (true, "S"):  seconds = value
            default: return nil   // unknown unit / time unit before `T`
            }
            total += seconds
            sawAny = true
        }
        guard sawAny else { return nil }
        return Int(total.rounded())
    }
}
