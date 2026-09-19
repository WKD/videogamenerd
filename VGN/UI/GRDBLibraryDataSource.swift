import Foundation
import GRDB

/// The live `LibraryDataSource`: it bridges each of ``LibraryStore``'s GRDB
/// `ValueObservation` async sequences into an `AsyncStream` the UI reads
/// (PLAN §9 — "views subscribe through GRDB `ValueObservation` … the grid
/// updates itself after any write").
///
/// Cancellation is exact: terminating a stream (which the view model does on
/// every filter change, since the grid re-subscribes) cancels the bridging
/// task, which cancels the underlying observation — so rapid filter changes
/// never leak observations. Latest-filter-wins / stale-drop is enforced one
/// level up, in ``LibraryViewModel``'s generation guard.
struct GRDBLibraryDataSource: LibraryDataSource {
    let store: LibraryStore
    /// The ranking store, for the inspector's live derived-score line (PLAN §7).
    let ranking: RankingStore?

    init(store: LibraryStore, ranking: RankingStore? = nil) {
        self.store = store
        self.ranking = ranking
    }

    func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts> {
        // ONE observation: the existing scalar + per-platform aggregate
        // (`LibraryStore.fetchSidebarCounts`, unchanged) plus the pace-derived
        // "By Length" shelf counts over each game's personal length, composed here
        // rather than adding a second observation. A pace/style change re-subscribes
        // this stream with new bounds/length.
        let bounds = LengthShelf.bounds(for: pace)
        let observation = ValueObservation
            .tracking { db -> SidebarCounts in
                var counts = try LibraryStore.fetchSidebarCounts(db)
                let lengths = try LibraryQuery.fetchLengthShelfCounts(db, bounds: bounds, style: style)
                counts.lengthShelves = lengths.shelves
                counts.unmeasured = lengths.unmeasured
                return counts
            }
            .values(in: store.dbReader)
        return Self.bridge(observation)
    }

    func platformsInUse() -> AsyncStream<[PlatformInfo]> {
        Self.bridge(store.platformsInUse())
    }

    func tiers() -> AsyncStream<[TierInfo]> {
        Self.bridge(store.tiersObservation())
    }

    func genresInUse() -> AsyncStream<[String]> {
        Self.bridge(store.genresInUse())
    }

    func decadesInUse() -> AsyncStream<[Int]> {
        Self.bridge(store.decadesInUse())
    }

    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> {
        Self.bridge(store.games(filter: filter))
    }

    func gameDetail(id: Int64) async -> GameDetail? {
        try? await store.gameDetail(id: id)
    }

    func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> {
        Self.bridge(store.gameDetailObservation(id: id))
    }

    func compilationMemberIDs(productID: Int64) async -> [Int64] {
        ((try? await store.compilationMembers(productID: productID)) ?? []).map(\.gameID)
    }

    func scoreLineStream(for gameID: Int64) -> AsyncStream<DerivedScoreLine?> {
        guard let ranking else { return onceStream(nil) }
        return Self.bridge(ranking.scoreLineObservation(for: gameID))
    }

    func scoresStream() -> AsyncStream<[Int64: DerivedScoreValue]> {
        guard let ranking else { return onceStream([:]) }
        return Self.bridge(ranking.derivedScoresObservation())
    }

    func libraryStats() async -> LibraryStats {
        (try? await store.libraryStats()) ?? .empty
    }

    /// Republish a GRDB `ValueObservation` async sequence (itself `Sendable`) as
    /// a non-throwing `AsyncStream`. Cancelling the stream cancels the consuming
    /// task, which ends the observation — no leaks when the grid re-subscribes on
    /// every filter change. A failed observation simply ends the stream (the UI
    /// keeps its last value).
    private static func bridge<Element: Sendable>(
        _ observation: AsyncValueObservation<Element>
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation {
                        continuation.yield(value)
                    }
                } catch {
                    // Observation ended with an error (e.g. cancelled) — finish.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
