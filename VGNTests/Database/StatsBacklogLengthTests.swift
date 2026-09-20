import Foundation
import Testing
@testable import VGN

/// D4: the Stats "backlog to beat" uses the owner's **personal length** at their play
/// style (the BY LENGTH source of truth), not the raw IGDB main story. A rushed-only game
/// has no personal length → it counts as *without an estimate*.
struct StatsBacklogLengthTests {

    private func addBacklog(_ store: LibraryStore, _ title: String, igdbID: Int64,
                            hastily: Int? = nil, normally: Int? = nil, completely: Int? = nil) async throws {
        let id = try await store.addGame(GameDraft(title: title, igdbID: igdbID,
                                                   platformIDs: ["pc"], owned: true)).gameID   // owned, unplayed
        try await store.updateMetadata(gameID: id, MetadataPatch(
            ttbHastilyS: hastily, ttbNormallyS: normally, ttbCompletelyS: completely))
    }

    @Test("Backlog estimate is the personal length; rushed-only counts as unmeasured")
    func personalLengthBacklog() async throws {
        let store = try await TestDB.makeStore()
        try await addBacklog(store, "Both", igdbID: 1, normally: 36_000, completely: 108_000)   // 10h / 30h
        try await addBacklog(store, "MainOnly", igdbID: 2, normally: 18_000)                    // 5h main
        try await addBacklog(store, "RushedOnly", igdbID: 3, hastily: 3_600)                    // 1h rushed → Unmeasured

        let style = PlayStyle.lotsOfSideQuests
        let report = try await LibraryStatsStore(store.database).report(scope: .all, playStyle: style)
        let mva = report.myHoursVsAverage

        let expected = (PersonalLength.compute(normallyS: 36_000, completelyS: 108_000, style: style)!.seconds)
                     + (PersonalLength.compute(normallyS: 18_000, completelyS: nil, style: style)!.seconds)
        #expect(mva.backlogEstimateSeconds == expected)
        #expect(mva.backlogGamesMissingEstimate == 1)      // the rushed-only game
        #expect(report.backlogGames == 3)
        // It is NOT the raw main-story sum (that would ignore the play style).
        #expect(mva.backlogEstimateSeconds != 36_000 + 18_000)
    }

    @Test("A different play style changes the backlog estimate")
    func styleChangesEstimate() async throws {
        let store = try await TestDB.makeStore()
        try await addBacklog(store, "Both", igdbID: 1, normally: 36_000, completely: 108_000)

        let statsStore = LibraryStatsStore(store.database)
        let storyFirst = try await statsStore.report(scope: .all, playStyle: .storyFirst)
        let completionist = try await statsStore.report(scope: .all, playStyle: .completionist)
        #expect(storyFirst.myHoursVsAverage.backlogEstimateSeconds == 36_000)     // main only
        #expect(completionist.myHoursVsAverage.backlogEstimateSeconds == 108_000) // completionist
    }
}
