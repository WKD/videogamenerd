import Foundation
import Testing
@testable import VGN

/// D4: the Stats window reacts to a play-style change like the shelves do — the model
/// re-reads the style and re-queries on `vgnPlayStyleDidChange`.
@MainActor
@Suite(.serialized)
struct StatsBacklogStyleTests {

    /// A mutable play style the model reads through its provider.
    private final class StyleHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PlayStyle
        init(_ v: PlayStyle) { value = v }
        var current: PlayStyle { lock.withLock { value } }
        func set(_ v: PlayStyle) { lock.withLock { value = v } }
    }

    private func poll(timeout: TimeInterval = 2, _ cond: @MainActor () -> Bool) async {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func reactsToPlayStyleChange() async throws {
        let store = LibraryStore(try await TestDB.makeSeeded())
        let id = try await store.addGame(GameDraft(title: "Both", igdbID: 1, platformIDs: ["pc"], owned: true)).gameID
        try await store.updateMetadata(gameID: id, MetadataPatch(ttbNormallyS: 36_000, ttbCompletelyS: 108_000))

        let holder = StyleHolder(.storyFirst)
        let model = StatsModel(store: LibraryStatsStore(store.database),
                               playStyleProvider: { holder.current })
        await model.start()
        defer { model.stop() }

        #expect(model.report.myHoursVsAverage.backlogEstimateSeconds == 36_000)   // story-first

        // Change the style and announce it, exactly as the pace editor does.
        holder.set(.completionist)
        NotificationCenter.default.post(name: .vgnPlayStyleDidChange, object: nil)

        await poll { model.report.myHoursVsAverage.backlogEstimateSeconds == 108_000 }
        #expect(model.report.myHoursVsAverage.backlogEstimateSeconds == 108_000)
    }
}
