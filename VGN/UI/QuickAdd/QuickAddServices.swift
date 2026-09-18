import Foundation

/// Live wiring for ``QuickAddModel``'s seams (PLAN §6.1). Kept in the UI lane so the
/// model stays testable with fakes; these adapters just translate to the services /
/// store the app already built.

// MARK: - Catalogue search (IGDB)

/// The live catalogue searcher: ``IGDBAutocomplete`` for autocomplete (with the
/// name-prefix / alt-name fallback) and ``IGDBClient`` for bundle members.
struct LiveCatalogSearcher: CatalogSearching {
    let autocomplete: IGDBAutocomplete
    let client: IGDBClient
    let credentials: @Sendable () async -> IGDBCredentials?

    func search(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult] {
        try await autocomplete.autocomplete(text, platformIGDBIDs: platformIGDBIDs, limit: limit)
    }

    func bundleMembers(bundleIGDBID: Int64) async throws -> [IGDBSearchResult] {
        // Fetch the bundle's full metadata first: it lets `bundleMembers(of:)` use
        // the forward `bundles` relation when present, else the reverse lookup.
        guard let meta = try await client.games(ids: [bundleIGDBID]).first else {
            return try await client.bundleMembers(ofBundleID: bundleIGDBID)
        }
        return try await client.bundleMembers(of: meta)
    }

    func hasCredentials() async -> Bool { await credentials() != nil }
}

/// A no-network catalogue searcher for `-VGNSampleData YES` (and the DB-failure
/// path): local library + manual rows only, never touches IGDB.
struct OfflineCatalogSearcher: CatalogSearching {
    func search(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult] {
        throw IGDBError.missingCredentials
    }
    func bundleMembers(bundleIGDBID: Int64) async throws -> [IGDBSearchResult] { [] }
    func hasCredentials() async -> Bool { false }
}

// MARK: - Library writes

/// The live library adder over ``LibraryStore``.
struct LiveLibraryAdder: LibraryAdding {
    let store: LibraryStore
    /// Local search needs at least this many characters (avoids dumping the whole
    /// library for one keystroke). PLAN's palette shows results from 3 letters.
    var minLocalChars = 2

    func localMatches(_ text: String) async -> [QuickAddLibraryMatch] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minLocalChars else { return [] }
        let filter = LibraryFilter(searchText: trimmed, scope: .all)
        let rows = (try? await store.gamesOnce(filter: filter)) ?? []
        return rows.map(QuickAddLibraryMatch.init(from:))
    }

    func add(_ draft: GameDraft) async throws -> AddOutcome {
        try await store.addGame(draft)
    }

    func addCompilation(
        product: ProductDraft, members: [CompilationMemberDraft]
    ) async throws -> (productID: Int64, members: [AddOutcome]) {
        try await store.addCompilation(product: product, members: members)
    }
}

// MARK: - Sticky-flag persistence

/// `UserDefaults`-backed sticky flags (owned / played / format), so the last-add
/// choices survive relaunch (PLAN §6.1 "sticky from last add … persisted").
struct UserDefaultsQuickAddPreferences: QuickAddPreferenceStoring {
    /// `UserDefaults` is thread-safe (its own locking) but not `Sendable`-annotated.
    nonisolated(unsafe) let defaults: UserDefaults
    private let ownedKey = "VGNQuickAdd.owned"
    private let playedKey = "VGNQuickAdd.played"
    private let formatKey = "VGNQuickAdd.format"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadFlags() -> QuickAddFlags {
        var flags = QuickAddFlags()
        if defaults.object(forKey: ownedKey) != nil { flags.owned = defaults.bool(forKey: ownedKey) }
        if defaults.object(forKey: playedKey) != nil { flags.played = defaults.bool(forKey: playedKey) }
        if let raw = defaults.string(forKey: formatKey), let format = ProductFormat(rawValue: raw) {
            flags.format = format
        }
        return flags
    }

    func saveFlags(_ flags: QuickAddFlags) {
        defaults.set(flags.owned, forKey: ownedKey)
        defaults.set(flags.played, forKey: playedKey)
        defaults.set(flags.format.rawValue, forKey: formatKey)
    }
}

/// An in-memory sticky store (tests; also a safe default when no `UserDefaults`).
final class InMemoryQuickAddPreferences: QuickAddPreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var flags: QuickAddFlags
    init(_ flags: QuickAddFlags = QuickAddFlags()) { self.flags = flags }
    func loadFlags() -> QuickAddFlags { lock.withLock { flags } }
    func saveFlags(_ flags: QuickAddFlags) { lock.withLock { self.flags = flags } }
}
