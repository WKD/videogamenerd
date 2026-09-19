import Foundation

/// Stable source ids for the generic `import_titles` / `import_cache` tables and
/// the `LibraryImporter.source` discriminator (PLAN §4/§14). Raw strings, so the
/// pure Model layer stays free of any importer implementation.
enum ImportSourceID {
    static let gog = "gog"
    static let psn = "psn"
    /// The first **file-based** importer: an old Delicious Library 2 database (PLAN §5.5).
    static let delicious = "delicious"
}

/// What an imported title signals about the library (PLAN §14.3 / §13.3). GOG only
/// ever signals **owned**; PSN can signal **played** (trophies / game list) and/or
/// **owned** (purchases). Encoded into `import_titles.signals` as a comma list.
struct ImportSignals: OptionSet, Sendable, Hashable, Codable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let owned  = ImportSignals(rawValue: 1 << 0)
    static let played = ImportSignals(rawValue: 1 << 1)

    /// `"owned"`, `"played"`, `"owned,played"` or `""` — the `import_titles.signals`
    /// storage form.
    var storageString: String {
        var parts: [String] = []
        if contains(.owned) { parts.append("owned") }
        if contains(.played) { parts.append("played") }
        return parts.joined(separator: ",")
    }

    init(storageString: String?) {
        var value: ImportSignals = []
        for token in (storageString ?? "").split(separator: ",") {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "owned": value.insert(.owned)
            case "played": value.insert(.played)
            default: break
            }
        }
        self = value
    }
}

/// Why a validated-looking response is actually **bogus** and must not be cached
/// (PLAN §14.2). The `retryAfter` on `.rateLimited` drives the single 429 wait of
/// the retry policy. Pure Model so it can be persisted (redacted) and shown in the
/// UI without pulling in any service type.
enum ImportRejectReason: Sendable, Hashable, Codable {
    case wrongStatus(Int)
    case notJSON
    case loginPageOrHTML
    case errorEnvelope
    case schemaMismatch
    case incoherentPaging
    case suspiciouslyEmpty
    case rateLimited(retryAfter: TimeInterval?)
    case authChallenge
    case unknown

    /// A short, stable code stored in `import_cache_rejects.reason` and grepped in tests.
    var code: String {
        switch self {
        case .wrongStatus(let s): return "wrongStatus(\(s))"
        case .notJSON: return "notJSON"
        case .loginPageOrHTML: return "loginPageOrHTML"
        case .errorEnvelope: return "errorEnvelope"
        case .schemaMismatch: return "schemaMismatch"
        case .incoherentPaging: return "incoherentPaging"
        case .suspiciouslyEmpty: return "suspiciouslyEmpty"
        case .rateLimited(let after): return "rateLimited(\(after.map { String(Int($0)) } ?? "-"))"
        case .authChallenge: return "authChallenge"
        case .unknown: return "unknown"
        }
    }

    /// A one-line, user-facing explanation for the stop-and-ask message (PLAN §14.5).
    var message: String {
        switch self {
        case .wrongStatus(let s): return "The server returned HTTP \(s) instead of the expected data."
        case .notJSON: return "The response was not JSON."
        case .loginPageOrHTML: return "A login page was returned — the session looks signed out."
        case .errorEnvelope: return "The response carried an error envelope."
        case .schemaMismatch: return "The response did not match the expected shape."
        case .incoherentPaging: return "The paged list was inconsistent across pages."
        case .suspiciouslyEmpty: return "The list was empty where it previously had items."
        case .rateLimited(let after):
            let s = after.map { " (retry after \(Int($0))s)" } ?? ""
            return "The server asked us to slow down\(s)."
        case .authChallenge: return "The request was met with an authentication challenge."
        case .unknown: return "The response could not be understood."
        }
    }

    /// Whether the sync may make exactly **one** more request before ending: a 429
    /// with a `Retry-After` (PLAN §14.1 rule 3). Everything else is a hard stop.
    var allowsSingleRetry: TimeInterval? {
        if case .rateLimited(let after) = self { return after }
        return nil
    }
}

/// A bogus response, redacted and surfaced to the caller when a sync stops
/// (PLAN §14.5). Everything here is safe to log and persist: all identifiers have
/// been through ``ImportRedactor`` before this is built.
struct ImportReject: Sendable, Hashable, Codable, Error {
    var source: String
    var endpoint: String
    var status: Int?
    var reason: ImportRejectReason
    /// A ≤ 4 KB, already-redacted excerpt of the offending body.
    var redactedExcerpt: String
    var receivedAt: Date

    init(source: String, endpoint: String, status: Int? = nil,
         reason: ImportRejectReason, redactedExcerpt: String = "", receivedAt: Date = Date()) {
        self.source = source
        self.endpoint = endpoint
        self.status = status
        self.reason = reason
        self.redactedExcerpt = redactedExcerpt
        self.receivedAt = receivedAt
    }
}

/// The age of one cached data set, for the Settings ▸ Accounts pane (PLAN §14.2 —
/// "cache age per data set", and the Force-refresh confirmation).
struct ImportCacheAge: Sendable, Hashable, Codable, Identifiable {
    var key: String
    var endpoint: String
    var fetchedAt: Date
    var expiresAt: Date
    var itemCount: Int

    var id: String { key }
    func isFresh(now: Date) -> Bool { expiresAt > now }
}

/// A data set an importer can fetch, with the request cost the Force-refresh
/// confirmation shows (PLAN §14.2 "how many requests it will cost").
struct ImportDataSet: Sendable, Hashable, Codable, Identifiable {
    var id: String
    var title: String
    /// A best-effort request count for a full (cold) fetch of this data set.
    var estimatedRequests: Int

    init(id: String, title: String, estimatedRequests: Int) {
        self.id = id
        self.title = title
        self.estimatedRequests = estimatedRequests
    }
}

/// The default platform for a GOG import and whether it is switchable (PLAN §14.3).
enum ImportPlatformPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// `mac` when the product `worksOn.Mac`, else `pc` (the owner plays on a Mac).
    case macWhenAvailable
    /// Force every imported product to `pc`.
    case alwaysPC

    var label: String {
        switch self {
        case .macWhenAvailable: return "Mac when available"
        case .alwaysPC: return "Always PC"
        }
    }
}

/// Why an imported row is ignored by default (PLAN §14.3 noise rules). Shown in the
/// review sheet's *Ignored* bucket so the reason is visible and one click restores.
enum ImportIgnoreReason: String, Sendable, Hashable, Codable, CaseIterable {
    case notAGame
    case dlcOrExpansion
    case soundtrackOrGoodies
    case demoOrPrologue
    case hidden

    var label: String {
        switch self {
        case .notAGame: return "Not a game"
        case .dlcOrExpansion: return "DLC / expansion"
        case .soundtrackOrGoodies: return "Soundtrack / goodies"
        case .demoOrPrologue: return "Demo / prologue"
        case .hidden: return "Hidden on GOG"
        }
    }
}

/// One staging row produced by an importer's pure mapping — a normalised, library-
/// agnostic view of an owned/played external title (PLAN §14.3). Persisted (minus the
/// transient `releaseYear`/`ignoreReason`, which the deterministic mapping recomputes)
/// into `import_titles` by ``ImportStagingStore``.
struct ImportStagingRow: Sendable, Hashable, Codable, Identifiable {
    var source: String
    var externalID: String
    var name: String
    /// VGN platform slug (`pc` / `mac`) the row maps to, or nil if unresolved.
    var platform: String?
    var signals: ImportSignals
    var playDurationS: Int?
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?
    /// The IGDB match tie-breaker (PLAN §14.3). Transient — not stored.
    var releaseYear: Int?
    /// Non-nil ⇒ noise, ignored by default with this reason. Transient — the stored
    /// decision is the boolean `import_titles.ignored`.
    var ignoreReason: ImportIgnoreReason?
    /// Whether the source lists a Mac build (PLAN §14.3). Transient — lets the review
    /// sheet re-map the platform when the policy switch flips, without re-reading the
    /// source DTO. GOG sets it from `worksOn.Mac`.
    var macAvailable: Bool
    /// A Linux-only title mapped to `pc` (PLAN §14.3 — "Linux-only titles map to pc
    /// with a note"). Transient; the review sheet shows the note from this flag.
    var linuxOnly: Bool
    /// The cleaned title to match against IGDB when it differs from the shown `name`
    /// (PLAN §5.5 — a file importer keeps the noisy original but matches a scrubbed
    /// form). Transient; nil ⇒ match on `name`. GOG never sets it.
    var matchTitle: String?
    /// An edition extracted from the source title / metadata (e.g. "Collector's Edition")
    /// to land on the committed copy (PLAN §5.5). Transient. GOG never sets it.
    var edition: String?
    /// When the copy was acquired (Delicious `ZCREATIONDATE`), stored on the committed
    /// product (PLAN §5.5). Transient. GOG never sets it.
    var acquiredAt: Date?

    var id: String { "\(source):\(externalID)" }

    init(source: String, externalID: String, name: String, platform: String? = nil,
         signals: ImportSignals = [.owned], playDurationS: Int? = nil,
         firstPlayedAt: Date? = nil, lastPlayedAt: Date? = nil,
         releaseYear: Int? = nil, ignoreReason: ImportIgnoreReason? = nil,
         macAvailable: Bool = false, linuxOnly: Bool = false,
         matchTitle: String? = nil, edition: String? = nil, acquiredAt: Date? = nil) {
        self.source = source
        self.externalID = externalID
        self.name = name
        self.platform = platform
        self.signals = signals
        self.playDurationS = playDurationS
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
        self.releaseYear = releaseYear
        self.ignoreReason = ignoreReason
        self.macAvailable = macAvailable
        self.linuxOnly = linuxOnly
        self.matchTitle = matchTitle
        self.edition = edition
        self.acquiredAt = acquiredAt
    }
}

/// The three review-sheet buckets (PLAN §14.3 / §6.3).
enum ImportReviewBucket: String, Sendable, Hashable, Codable, CaseIterable {
    case new
    case alreadyMatched
    case ignored

    var label: String {
        switch self {
        case .new: return "New"
        case .alreadyMatched: return "Already matched"
        case .ignored: return "Ignored"
        }
    }
}

/// A staged title as the review sheet renders it — a plain, `Sendable` projection of
/// an `import_titles` row plus its derived bucket (PLAN §14.3). Its persisted decision
/// is `matchedGameID` / `ignored`; the bucket follows from them.
struct ImportStagedTitle: Sendable, Hashable, Codable, Identifiable {
    var id: Int64
    var source: String
    var externalID: String
    var name: String
    var platform: String?
    var signals: ImportSignals
    var matchedGameID: Int64?
    var ignored: Bool

    var bucket: ImportReviewBucket {
        if ignored { return .ignored }
        return matchedGameID == nil ? .new : .alreadyMatched
    }
}

/// A user (or auto-match) decision on one staged title (PLAN §14.3 — decisions persist
/// in `import_titles.matched_game_id / ignored`).
enum ImportDecision: Sendable, Hashable, Codable {
    /// Tie to an existing library game (also un-ignores).
    case match(gameID: Int64)
    /// Drop a previous match (back to *New*).
    case unmatch
    /// Move to *Ignored*.
    case ignore
    /// Restore from *Ignored* (back to *New* / *Already matched*).
    case restore
}

/// The result of one sync (PLAN §14.2 summary line "n from cache · m from network").
struct ImportSyncSummary: Sendable, Hashable, Codable {
    var source: String
    var fromCache: Int
    var fromNetwork: Int
    var stagedTotal: Int
    var newCount: Int
    var alreadyMatchedCount: Int
    var ignoredCount: Int
    var budgetUsed: Int
    var rejects: [ImportReject]
    /// Product ids returned on a library page that are **not** in the owned-id list
    /// (PLAN §14.2 — "a gap is reported, not fatal"). 0 ⇒ fully consistent. Surfaced
    /// as a note in the review-sheet header.
    var ownedGap: Int
    /// Count read from a **file** source (Delicious Library, PLAN §5.5). > 0 ⇒ the
    /// header shows "N games read from …" instead of the cache/network line. 0 for
    /// network importers (GOG/PSN).
    var fromFile: Int

    init(source: String, fromCache: Int = 0, fromNetwork: Int = 0,
         stagedTotal: Int = 0, newCount: Int = 0, alreadyMatchedCount: Int = 0,
         ignoredCount: Int = 0, budgetUsed: Int = 0, rejects: [ImportReject] = [],
         ownedGap: Int = 0, fromFile: Int = 0) {
        self.source = source
        self.fromCache = fromCache
        self.fromNetwork = fromNetwork
        self.stagedTotal = stagedTotal
        self.newCount = newCount
        self.alreadyMatchedCount = alreadyMatchedCount
        self.ignoredCount = ignoredCount
        self.budgetUsed = budgetUsed
        self.rejects = rejects
        self.ownedGap = ownedGap
        self.fromFile = fromFile
    }

    /// "12 from cache · 3 from network".
    var networkSummaryLine: String {
        "\(fromCache) from cache · \(fromNetwork) from network"
    }

    /// Header summary line: a file source reads "N games read from the file"; a network
    /// source shows the cache/network split. The source's human label is supplied by the
    /// review model (this Model type stays label-free).
    func summaryLine(sourceLabel: String) -> String {
        guard fromFile > 0 else { return networkSummaryLine }
        return "\(fromFile) game\(fromFile == 1 ? "" : "s") read from \(sourceLabel)"
    }

    /// A one-line note when the owned-id list and the library pages disagree
    /// (PLAN §14.2 — reported, never fatal), else nil.
    var ownedGapNote: String? {
        guard ownedGap > 0 else { return nil }
        return "\(ownedGap) product\(ownedGap == 1 ? "" : "s") not in your owned-games list"
    }
}

/// A plain progress value for the coordinator's `AsyncStream` (PLAN §14.4). No
/// service or SwiftUI types, so the UI can render it directly.
struct ImportProgress: Sendable, Hashable, Codable {
    enum Phase: String, Sendable, Hashable, Codable {
        case authenticating
        case fetching
        case staging
        case matching
        case finished
    }
    var phase: Phase
    /// Completed units of work in the current phase (e.g. pages fetched, rows matched).
    var completed: Int
    /// Total units, when known.
    var total: Int?
    var detail: String

    init(phase: Phase, completed: Int = 0, total: Int? = nil, detail: String = "") {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.detail = detail
    }
}
