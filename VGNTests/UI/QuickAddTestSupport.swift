import Foundation
@testable import VGN

// Shared fakes + builders for the Quick Add model tests. No GRDB, no network.

/// A controllable catalogue searcher. A gate lets a test hold a response open to
/// exercise cancellation / stale-drop ordering.
actor FakeCatalog: CatalogSearching {
    var results: [IGDBSearchResult] = []
    var members: [IGDBSearchResult] = []
    var credentials = true
    var useGate = false
    private(set) var searchCallCount = 0
    private(set) var lastSearchText: String?
    private var gate: CheckedContinuation<Void, Never>?

    func configure(
        results: [IGDBSearchResult]? = nil,
        members: [IGDBSearchResult]? = nil,
        credentials: Bool? = nil,
        useGate: Bool? = nil
    ) {
        if let results { self.results = results }
        if let members { self.members = members }
        if let credentials { self.credentials = credentials }
        if let useGate { self.useGate = useGate }
    }

    func search(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult] {
        searchCallCount += 1
        lastSearchText = text
        if useGate { await withCheckedContinuation { gate = $0 } }
        if !credentials { throw IGDBError.missingCredentials }
        return results
    }

    func release() { gate?.resume(); gate = nil }

    func bundleMembers(bundleIGDBID: Int64) async throws -> BundleMemberResult { BundleMemberResult(members: members) }
    func hasCredentials() async -> Bool { credentials }
}

/// A recording library adder.
actor FakeLibrary: LibraryAdding {
    var localReturn: [QuickAddLibraryMatch] = []
    private(set) var addedDrafts: [GameDraft] = []
    private(set) var addedCompilations: [(product: ProductDraft, members: [CompilationMemberDraft])] = []
    var outcome: AddOutcome = .created(gameID: 1)
    private var nextID: Int64 = 1

    func setLocal(_ matches: [QuickAddLibraryMatch]) { localReturn = matches }
    func setOutcome(_ outcome: AddOutcome) { self.outcome = outcome }

    func localMatches(_ text: String) async -> [QuickAddLibraryMatch] {
        text.trimmingCharacters(in: .whitespaces).count >= 2 ? localReturn : []
    }

    func add(_ draft: GameDraft) async throws -> AddOutcome {
        addedDrafts.append(draft)
        return outcome
    }

    func addCompilation(
        product: ProductDraft, members: [CompilationMemberDraft]
    ) async throws -> (productID: Int64, members: [AddOutcome]) {
        addedCompilations.append((product, members))
        let outcomes = members.enumerated().map { AddOutcome.created(gameID: Int64(100 + $0.offset)) }
        return (99, outcomes)
    }
}

// MARK: - Builders

func makeSearchResult(
    id: Int64, name: String, year: Int? = nil, platforms: [String] = [],
    coverImageID: String? = nil, alternativeNames: [String] = [], bundle: Bool = false
) -> IGDBSearchResult {
    IGDBSearchResult(
        id: id, name: name, releaseYear: year, coverImageID: coverImageID,
        platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: platforms,
        genres: [], alternativeNames: alternativeNames,
        gameType: bundle ? .bundle : .mainGame
    )
}

func makeLibraryMatch(
    id: Int64, title: String, platforms: [String] = [],
    owned: Bool = true, played: Bool = false, hasROM: Bool = false
) -> QuickAddLibraryMatch {
    QuickAddLibraryMatch(from: GameSummary(
        id: id, title: title, played: played, owned: owned,
        platformIDs: platforms, hasROM: hasROM
    ))
}

// MARK: - Model helper

/// A fixed platform set + generations so the default-platform / cycling tests do
/// not depend on the bundled `platforms.json`.
enum QuickAddTestPlatforms {
    static func info(_ id: String, _ short: String, gen: Int?) -> PlatformInfo {
        PlatformInfo(id: id, name: id.uppercased(), short: short, manufacturer: "Sony",
                     group: "Sony", kind: .console, generation: gen, sort: 0)
    }
    static let all: [PlatformInfo] = [
        info("ps5", "PS5", gen: 9), info("ps4", "PS4", gen: 8),
        info("ps3", "PS3", gen: 7), info("ps2", "PS2", gen: 6),
    ]
    static let generation: [String: Int] = ["ps5": 9, "ps4": 8, "ps3": 7, "ps2": 6, "snes": 4]
}

@MainActor
func makeQuickAddModel(
    catalog: FakeCatalog = FakeCatalog(),
    library: FakeLibrary = FakeLibrary(),
    preferences: InMemoryQuickAddPreferences = InMemoryQuickAddPreferences(),
    platforms: [PlatformInfo] = QuickAddTestPlatforms.all,
    debounce: Duration = .seconds(60),
    generation: (@Sendable (String) -> Int?)? = nil
) -> QuickAddModel {
    QuickAddModel(
        catalog: catalog, library: library, preferences: preferences,
        platforms: platforms, debounce: debounce,
        platformGeneration: generation ?? { QuickAddTestPlatforms.generation[$0] }
    )
}

/// A `@MainActor` capture box for closure side effects in tests.
@MainActor
final class Captured {
    var openedID: Int64?
    var closed = false
    var changeCount = 0
}
