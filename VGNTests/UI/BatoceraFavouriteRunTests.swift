import Foundation
import GRDB
import Testing
@testable import VGN

/// The favourites pass now finishes by itself (D4, PLAN §15): batch after batch until none is
/// left, cancellable, pausing cleanly on an IGDB error (no retry storm), resuming on the next
/// run without re-querying, with a shared progress value and ONE final banner (Review… + Undo),
/// all batches a single undo step. No network.
@MainActor
@Suite(.serialized)
struct BatoceraFavouriteRunTests {

    // MARK: - Fakes

    /// Returns a confident, non-bundle match for any title; records every request.
    private final class CountingConfidentMatcher: ImportMatcher, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var titles: [String] = []
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            lock.withLock { titles.append(request.title) }
            // A distinct igdb id per title, so each becomes its own new game (no dedupe-merge).
            let id = Int64(1000 + abs(request.title.hashValue % 100_000))
            return ScanMatchOutcome(
                best: ScanMatch(igdbID: id, name: request.title, releaseYear: request.releaseYear,
                                coverImageID: nil, platformSlugs: ["snes"], score: 0.95,
                                matchedName: request.title),
                alternatives: [], bucket: .confident)
        }
        var count: Int { lock.withLock { titles.count } }
    }

    /// Always fails — an IGDB outage.
    private struct MatcherOutage: Error {}
    private struct ThrowingMatcher: ImportMatcher {
        final class Counter: @unchecked Sendable { let l = NSLock(); var n = 0 }
        let counter: Counter
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            counter.l.withLock { counter.n += 1 }
            throw MatcherOutage()
        }
    }

    // MARK: - Setup

    private func seedFavourites(_ store: RomCatalogStore, _ names: [String]) async throws {
        let entries = names.enumerated().map { i, name -> RomCatalogEntry in
            let g = BatoceraGame(system: "snes", relativePath: "./f\(i).zip", name: name,
                                 releaseYear: 1990 + i, gameTimeSeconds: 0, isFavorite: true)
            return RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: g))
        }
        _ = try await store.syncSystem(system: "snes", entries: entries)
    }

    private func seedPlayedNonFavourite(_ store: RomCatalogStore) async throws {
        let existing = try await store.entries(system: "snes")
        let g = BatoceraGame(system: "snes", relativePath: "./pnf.zip", name: "Played Not Fav",
                             releaseYear: 1999, gameTimeSeconds: 3000, isFavorite: false)
        let e = RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: BatoceraFolding.foldKey(for: g))
        _ = try await store.syncSystem(system: "snes", entries: existing + [e])
    }

    private func makePresenter(_ db: AppDatabase, vm: LibraryViewModel,
                               matcher: any ImportMatcher) -> BatoceraImportPresenter {
        let p = BatoceraImportPresenter(
            catalog: RomCatalogStore(db), promoter: BatoceraPromoter(db),
            staging: ImportStagingStore(db), matcher: NoMatchImportMatcher(),
            autoAddMatcher: matcher, platformChoices: ["snes"])
        p.library = vm
        p.autoAddEnabled = { true }
        return p
    }

    private func makeVM(_ db: AppDatabase) -> LibraryViewModel {
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: LibraryStore(db)))
        vm.undoManager = UndoManager()
        return vm
    }

    // MARK: - The progress value

    @Test func progressValueTracksTheRun() {
        let p = BatoceraFavouriteProgress()
        #expect(p.statusLine == nil)
        p.begin(total: 10)
        #expect(p.isRunning)
        #expect(p.total == 10)
        p.update(matched: 3, added: 1)
        #expect(p.statusLine == "Matching favourites… 3 of 10")
        #expect((p.fraction ?? 0) > 0.29 && (p.fraction ?? 0) < 0.31)
        p.finish()
        #expect(!p.isRunning)
        #expect(p.statusLine == nil)
        var stopped = false
        p.onStop = { stopped = true }
        p.stop()
        #expect(stopped)
    }

    // MARK: - Multi-batch to completion (each title once)

    @Test(.timeLimit(.minutes(1)))
    func runsAllBatchesToCompletionEachTitleOnce() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let names = ["A", "B", "C", "D", "E"]
        try await seedFavourites(store, names)
        try await seedPlayedNonFavourite(store)   // leaves one review candidate

        let matcher = CountingConfidentMatcher()
        let vm = makeVM(db)
        let p = makePresenter(db, vm: vm, matcher: matcher)
        let engine = BatoceraFavouriteAutoAdd(catalog: store, staging: ImportStagingStore(db),
                                              matcher: matcher, promoter: BatoceraPromoter(db))
        await p.runFavouriteMatching(engine, fallbackCandidateCount: 0, batchLimit: 2)

        #expect(matcher.count == 5)                       // one request per favourite
        #expect(Set(matcher.titles) == Set(names))        // each title exactly once
        #expect(try await store.favouritesNeedingMatchCount() == 0)
        // Progress ended at total, no longer running.
        #expect(p.favouriteProgress.total == 5)
        #expect(p.favouriteProgress.matched == 5)
        #expect(p.favouriteProgress.added == 5)
        #expect(!p.favouriteProgress.isRunning)

        // ONE final banner with both actions.
        let banner = try #require(vm.banner)
        #expect(banner.message.contains("5 favourites added from Batocera"))
        #expect(banner.message.contains("your review"))
        #expect(banner.actionTitle == "Undo")
        #expect(banner.secondaryActionTitle == "Review…")
    }

    // MARK: - Cancel mid-run + resume on the next run (nothing queried twice)

    @Test(.timeLimit(.minutes(1)))
    func cancelStopsTheRunAndTheNextRunResumes() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let names = ["A", "B", "C", "D", "E"]
        try await seedFavourites(store, names)
        let matcher = CountingConfidentMatcher()
        let vm = makeVM(db)
        let p = makePresenter(db, vm: vm, matcher: matcher)
        let engine = BatoceraFavouriteAutoAdd(catalog: store, staging: ImportStagingStore(db),
                                              matcher: matcher, promoter: BatoceraPromoter(db))

        // Cancel before the first batch runs.
        let task = Task { await p.runFavouriteMatching(engine, fallbackCandidateCount: 0, batchLimit: 2) }
        task.cancel()
        await task.value
        #expect(matcher.count == 0)                       // nothing queried

        // The next run resumes and finishes — no title re-queried.
        await p.runFavouriteMatching(engine, fallbackCandidateCount: 0, batchLimit: 2)
        #expect(matcher.count == 5)
        #expect(Set(matcher.titles) == Set(names))
        #expect(try await store.favouritesNeedingMatchCount() == 0)
    }

    // MARK: - An IGDB error pauses cleanly (no storm)

    @Test(.timeLimit(.minutes(1)))
    func igdbErrorPausesWithoutAStorm() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, ["A", "B", "C", "D"])
        let counter = ThrowingMatcher.Counter()
        let matcher = ThrowingMatcher(counter: counter)
        let vm = makeVM(db)
        let p = makePresenter(db, vm: vm, matcher: matcher)
        let engine = BatoceraFavouriteAutoAdd(catalog: store, staging: ImportStagingStore(db),
                                              matcher: matcher, promoter: BatoceraPromoter(db))
        await p.runFavouriteMatching(engine, fallbackCandidateCount: 0, batchLimit: 2)

        #expect(counter.n == 1)                            // one call, then it stops — no storm
        // Only the one favourite it tried is staged; the other three wait for the next sync.
        #expect(try await store.favouritesNeedingMatchCount() == 3)
    }

    // MARK: - The whole run is one undo step

    @Test(.timeLimit(.minutes(1)))
    func oneUndoReversesEveryBatch() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seedFavourites(store, ["A", "B", "C", "D", "E"])
        let matcher = CountingConfidentMatcher()
        let vm = makeVM(db)
        let p = makePresenter(db, vm: vm, matcher: matcher)
        let engine = BatoceraFavouriteAutoAdd(catalog: store, staging: ImportStagingStore(db),
                                              matcher: matcher, promoter: BatoceraPromoter(db))
        await p.runFavouriteMatching(engine, fallbackCandidateCount: 0, batchLimit: 2)

        let before = try await db.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? 0 }
        #expect(before == 5)
        #expect(vm.undoManager?.canUndo == true)

        // The banner's Undo (and the undo manager) reverse everything the run added, in one step.
        p.undoAutoAdd()
        await waitUntil { (try? db.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1 }) == 0 }
        let after = try await db.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1 }
        #expect(after == 0)
        #expect(try await store.entries(system: "snes").allSatisfy { $0.promotedGameID == nil })
    }
}
