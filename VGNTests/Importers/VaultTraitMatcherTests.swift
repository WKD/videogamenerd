import Foundation
import Testing
@testable import VGN

/// The Vault IGDB trait-matching pass (PLAN §16): the pure "confident" rule, the background
/// matcher (persists traits / rating / time-to-beat on a confident match, marks the rest
/// no-match, caps a run, never re-queries, cancels cleanly, confident-only), and the Settings
/// status model (counts + "Match more now" + inertness with no entries). Fake matcher +
/// metadata fetcher; no network.
@Suite(.serialized) struct VaultTraitMatcherTests {

    // MARK: - Fakes

    /// A metadata fetcher that returns scripted info per IGDB id (absent ⇒ no metadata).
    private final class FakeVaultMetadata: VaultMetadataFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var byID: [Int64: VaultTraitInfo] = [:]
        private(set) var batches: [[Int64]] = []
        func set(_ id: Int64, _ info: VaultTraitInfo) { lock.withLock { byID[id] = info } }
        func info(igdbIDs: [Int64]) async throws -> [Int64: VaultTraitInfo] {
            lock.withLock {
                batches.append(igdbIDs)
                var out: [Int64: VaultTraitInfo] = [:]
                for id in igdbIDs where byID[id] != nil { out[id] = byID[id] }
                return out
            }
        }
    }

    /// A matcher that cancels the running task on its first call, to test cancellation.
    private final class SelfCancellingMatcher: ImportMatcher, @unchecked Sendable {
        let outcome: ScanMatchOutcome
        private let lock = NSLock()
        private var count = 0
        init(_ outcome: ScanMatchOutcome) { self.outcome = outcome }
        var callCount: Int { lock.withLock { count } }
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            lock.withLock { count += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
            return outcome
        }
    }

    private func confident(igdbID: Int64, platforms: [String] = ["ps5"]) -> ScanMatchOutcome {
        ScanMatchOutcome(
            best: ScanMatch(igdbID: igdbID, name: "Match", releaseYear: 2020, coverImageID: nil,
                            platformSlugs: platforms, score: 0.96, matchedName: "Match"),
            alternatives: [], bucket: .confident)
    }

    private func psn(_ ext: String, _ name: String, platform: String = "ps5") -> RomCatalogEntry {
        RomCatalogEntry.makePSNVault(externalID: ext, platform: platform, name: name,
                                     coverURL: nil, membership: "ps_plus")
    }

    private func seed(_ store: RomCatalogStore, _ entries: [RomCatalogEntry]) async throws {
        _ = try await store.syncPSNVault(entries: entries,
                                         presentExternalIDs: Set(entries.map(\.relativePath)))
    }

    // MARK: - The pure confidence rule

    @Test func confidentRuleTopBucketAndPlatform() {
        #expect(VaultTraitMatch.isConfident(outcome: confident(igdbID: 1), entryPlatform: "ps5"))
        // Not the top bucket → not confident.
        let plausible = ScanMatchOutcome(
            best: ScanMatch(igdbID: 1, name: "X", releaseYear: nil, coverImageID: nil,
                            platformSlugs: ["ps5"], score: 0.8, matchedName: "X"),
            alternatives: [], bucket: .plausible)
        #expect(!VaultTraitMatch.isConfident(outcome: plausible, entryPlatform: "ps5"))
        // Wrong platform → downgraded.
        #expect(!VaultTraitMatch.isConfident(outcome: confident(igdbID: 1, platforms: ["ps4"]),
                                             entryPlatform: "ps5"))
        // Unknown platforms on the match → the platform check does not block.
        #expect(VaultTraitMatch.isConfident(outcome: confident(igdbID: 1, platforms: []),
                                            entryPlatform: "ps5"))
        // No best → never confident.
        #expect(!VaultTraitMatch.isConfident(
            outcome: ScanMatchOutcome(best: nil, alternatives: [], bucket: .none), entryPlatform: "ps5"))
    }

    // MARK: - traitInfo shape

    @Test func traitInfoBuildsEngineVocabulary() {
        var meta = IGDBGameMetadata(
            id: 42, name: "Bloodborne", slug: nil, summary: nil, releaseDate: nil, releaseYear: 2015,
            coverImageID: nil, platformIGDBIDs: [], platformSlugs: ["ps4"], genres: ["Role-playing (RPG)"],
            alternativeNames: [], gameType: .init(rawValue: 0), bundleMemberIDs: [],
            parentGameID: nil, versionParentID: nil)
        meta.developers = ["FromSoftware"]
        meta.themes = ["Horror"]
        meta.keywords = ["gothic"]
        meta.igdbRating = 91
        let ttb = IGDBTimeToBeat(gameID: 42, hastily: nil, normally: 3600 * 33, completely: 3600 * 70, count: 5)
        let info = VaultTraitMatcher.traitInfo(from: meta, ttb: ttb)
        #expect(info.igdbID == 42)
        #expect(info.igdbRating == 91)
        #expect(info.lengthMainSeconds == 3600 * 33)
        #expect(info.lengthCompleteSeconds == 3600 * 70)
        #expect(info.traits.contains(GameTrait(kind: .developer, value: "FromSoftware")))
        #expect(info.traits.contains(GameTrait(kind: .theme, value: "Horror")))
        #expect(info.traits.contains(GameTrait(kind: .keyword, value: "gothic")))
        #expect(info.traits.contains(GameTrait(kind: .genre, value: "Role-playing (RPG)")))
        #expect(info.traits.contains(GameTrait(kind: .decade, value: "2010")))
    }

    // MARK: - The pass

    @Test(.timeLimit(.minutes(1)))
    func confidentPersistsTraitsAndNonConfidentMarkedNoMatch() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store, [psn("e1", "Bloodborne"), psn("e2", "Obscure Thing")])

        let matcher = FakeImportMatcher()
        matcher.on(title: "Bloodborne", confident(igdbID: 42))
        // "Obscure Thing" → no scripted outcome ⇒ .none ⇒ no match.
        let meta = FakeVaultMetadata()
        meta.set(42, VaultTraitInfo(igdbID: 42, traits: [GameTrait(kind: .genre, value: "Shooter")],
                                    igdbRating: 88, lengthMainSeconds: 3600 * 20, lengthCompleteSeconds: nil))

        let runner = VaultTraitMatcher(catalog: store, matcher: matcher, metadata: meta, cleanTitle: { $0 })
        let outcome = await runner.run()

        #expect(outcome.attempted == 2)
        #expect(outcome.matched == 1)
        #expect(outcome.noMatch == 1)
        // Only one batch metadata request, for the one confident id.
        #expect(meta.batches == [[42]])

        let progress = try await store.psnMatchProgress()
        #expect(progress.matched == 1)
        #expect(progress.total == 2)

        // The confident entry carries persisted traits / rating / length.
        let entries = try await store.unmatchedPSN(limit: 10)
        #expect(entries.isEmpty)   // both attempted, none left to query
        let all = try await store.vaultPool()      // matched PS Plus rows are suggestable
        #expect(all.count == 1)
        #expect(all.first?.igdbID == 42)
        #expect(all.first?.igdbRating == 88)
        #expect(all.first?.lengthMainSeconds == 3600 * 20)
        #expect(all.first?.traits.contains(GameTrait(kind: .genre, value: "Shooter")) == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func capsAtLimitAndNeverRequeries() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store, [psn("e1", "A"), psn("e2", "B"), psn("e3", "C")])

        let matcher = FakeImportMatcher()          // all → .none (no match)
        let meta = FakeVaultMetadata()
        let runner = VaultTraitMatcher(catalog: store, matcher: matcher, metadata: meta, cleanTitle: { $0 })

        let first = await runner.run(limit: 2)
        #expect(first.attempted == 2)
        #expect(try await store.psnMatchProgress().total == 3)
        // One entry still needs a match.
        #expect(try await store.unmatchedPSN(limit: 10).count == 1)

        // A second run finishes the last one; the first two are never re-queried.
        let second = await runner.run(limit: 2)
        #expect(second.attempted == 1)
        #expect(try await store.unmatchedPSN(limit: 10).isEmpty)
        // A third run has nothing to do.
        let third = await runner.run(limit: 2)
        #expect(third.attempted == 0)
        // Only the three original titles were ever matched (no re-query).
        #expect(matcher.requests.count == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelLeavesEntriesForNextRun() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store, [psn("e1", "A"), psn("e2", "B")])

        // Confident on the first call, but the matcher cancels the task, so the metadata batch
        // is skipped and nothing is persisted — both entries remain for the next run.
        let matcher = SelfCancellingMatcher(confident(igdbID: 7))
        let meta = FakeVaultMetadata()
        meta.set(7, VaultTraitInfo(igdbID: 7, traits: [], igdbRating: nil,
                                   lengthMainSeconds: nil, lengthCompleteSeconds: nil))
        let runner = VaultTraitMatcher(catalog: store, matcher: matcher, metadata: meta, cleanTitle: { $0 })

        let outcome = await Task { await runner.run() }.value
        #expect(outcome.cancelled)
        #expect(matcher.callCount == 1)
        #expect(meta.batches.isEmpty)                        // metadata batch skipped
        #expect(try await store.unmatchedPSN(limit: 10).count == 2)   // nothing persisted
    }

    @Test func cleanerStripsTrademarkBeforeMatching() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store, [psn("e1", "Ghost of Tsushima™ DIRECTOR'S CUT")])
        let matcher = FakeImportMatcher()
        let runner = VaultTraitMatcher(catalog: store, matcher: matcher, metadata: FakeVaultMetadata())
        _ = await runner.run()
        // The default cleaner (PSN) stripped the ™ before the match request.
        #expect(matcher.requests.first?.title == "Ghost of Tsushima DIRECTOR'S CUT")
    }

    // MARK: - The status model (inertness / counts / Match more)

    @Test(.timeLimit(.minutes(1))) @MainActor
    func modelIsInertWithNoEntriesAndReportsCounts() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let matcher = FakeImportMatcher()
        matcher.on(title: "Bloodborne", confident(igdbID: 42))
        let meta = FakeVaultMetadata()
        meta.set(42, VaultTraitInfo(igdbID: 42, traits: [], igdbRating: 88,
                                    lengthMainSeconds: nil, lengthCompleteSeconds: nil))
        let runner = VaultTraitMatcher(catalog: store, matcher: matcher, metadata: meta, cleanTitle: { $0 })
        let model = VaultTraitMatchModel(catalog: store, matcher: runner)

        // No entries yet → inert (empty status, nothing to match).
        await model.refresh()
        #expect(!model.hasEntries)
        #expect(model.statusText.isEmpty)
        #expect(!model.canMatchMore)

        // Add one PS Plus entry, run one batch, and the status reflects it.
        try await seed(store, [psn("e1", "Bloodborne")])
        await model.refresh()
        #expect(model.hasEntries)
        #expect(model.canMatchMore)                       // one unmatched
        #expect(model.statusText == "Vault: 0 of 1 matched · next batch at the next sync")

        model.matchMoreNow()
        try await pollUntil { !model.isRunning && model.matched == 1 }
        #expect(model.statusText == "Vault: 1 of 1 matched")
        #expect(!model.canMatchMore)
    }

    /// Await a condition without a wall-clock assertion.
    @MainActor private func pollUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met in time")
    }
}
