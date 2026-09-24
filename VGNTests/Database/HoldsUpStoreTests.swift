import Foundation
import Testing
import GRDB
@testable import VGN

/// The store side of "Holds up today?" (PLAN §4/§7b, v16): set / clear in one transaction,
/// refused on unplayed games (outcome, no throw), cleared by every un-play path, undo
/// inverse exact, read back through the grid row + detail, CSV/JSON export.
@Suite struct HoldsUpStoreTests {

    private func raw(_ store: LibraryStore, _ id: Int64) async throws -> String? {
        try await store.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT holds_up FROM games WHERE id = ?", arguments: [id])
        }
    }

    private func played(_ store: LibraryStore, _ title: String, owned: Bool = true) async throws -> Int64 {
        try await store.addGame(GameDraft(title: title, platformIDs: ["ps4"], owned: owned, played: true)).gameID
    }

    @Test func setAndClearOnPlayedGamesAndReadBack() async throws {
        let store = try await TestDB.makeStore()
        let a = try await played(store, "A")
        let b = try await played(store, "B")

        let outcome = try await store.setHoldsUp(.ofItsTime, for: [a, b])
        #expect(Set(outcome.applied) == [a, b])
        #expect(outcome.skippedUnplayed.isEmpty)
        #expect(outcome.previous[a] == .some(nil))
        #expect(try await raw(store, a) == "of_its_time")
        #expect(try await store.gameDetail(id: a)?.holdsUp == .ofItsTime)

        // The grid row carries it too.
        let rows = try await store.dbWriter.read { db in
            try LibraryStore.fetchGames(LibraryFilter(scope: .played), db)
        }
        #expect(rows.first { $0.id == b }?.holdsUp == .ofItsTime)

        // Clearing (nil) returns it to unrated.
        let cleared = try await store.setHoldsUp(nil, for: [a])
        #expect(cleared.previous[a] == .some(.ofItsTime))
        #expect(try await raw(store, a) == nil)
        #expect(try await store.gameDetail(id: a)?.holdsUp == nil)
    }

    @Test func unplayedGamesAreRefusedNotThrown() async throws {
        let store = try await TestDB.makeStore()
        let p = try await played(store, "Played")
        let backlog = try await store.addGame(GameDraft(title: "Backlog", platformIDs: ["ps4"],
                                                        owned: true, played: false)).gameID
        let outcome = try await store.setHoldsUp(.holdsUp, for: [p, backlog, 999_999])
        #expect(outcome.applied == [p])
        #expect(outcome.skippedUnplayed == [backlog, 999_999])
        #expect(try await raw(store, backlog) == nil)
        #expect(try await raw(store, p) == "holds_up")
    }

    @Test func everyUnplayPathClearsTheMark() async throws {
        let store = try await TestDB.makeStore()
        // setPlayed(false)
        let a = try await played(store, "A")
        try await store.setHoldsUp(.tooArchaic, for: [a])
        try await store.setPlayed([a], false)
        #expect(try await raw(store, a) == nil)
        // Re-playing does not bring it back (nothing inferred).
        try await store.setPlayed([a], true)
        #expect(try await raw(store, a) == nil)

        // markNotPlayed (Triage's safe un-play)
        let b = try await played(store, "B")
        try await store.setHoldsUp(.holdsUp, for: [b])
        #expect(try await store.markNotPlayed(b) == .becameBacklog)
        #expect(try await raw(store, b) == nil)

        // Undo of "Start playing" on a backlog game restores played = 0 ⇒ mark cleared.
        let c = try await store.addGame(GameDraft(title: "C", platformIDs: ["ps4"], owned: true)).gameID
        let recs = RecommendationStore(store.database)
        let undo = try await recs.startPlayingCapturingUndo(gameID: c)
        try await store.setHoldsUp(.holdsUp, for: [c])
        _ = try await recs.undoStartPlaying(undo)
        #expect(try await raw(store, c) == nil)

        // …whereas undoing Start playing on an already-played game keeps it.
        let d = try await played(store, "D")
        try await store.setHoldsUp(.ofItsTime, for: [d])
        let undoD = try await recs.startPlayingCapturingUndo(gameID: d)
        _ = try await recs.undoStartPlaying(undoD)
        #expect(try await raw(store, d) == "of_its_time")
    }

    /// The undo inverse, applied directly (``UndoManager/undo()`` hangs headless).
    @Test func restoreIsTheExactInverse() async throws {
        let store = try await TestDB.makeStore()
        let a = try await played(store, "A")
        let b = try await played(store, "B")
        try await store.setHoldsUp(.holdsUp, for: [a])            // a = holds up, b = unrated

        let outcome = try await store.setHoldsUp(.tooArchaic, for: [a, b])
        #expect(try await raw(store, a) == "too_archaic")
        let redo = try await store.restoreHoldsUp(outcome.previous)
        #expect(try await raw(store, a) == "holds_up")
        #expect(try await raw(store, b) == nil)
        // …and the redo map re-applies it.
        try await store.restoreHoldsUp(redo)
        #expect(try await raw(store, a) == "too_archaic")
        #expect(try await raw(store, b) == "too_archaic")

        // Undo never lands a mark on a game un-played since.
        try await store.setPlayed([b], false)
        try await store.restoreHoldsUp([b: .holdsUp])
        #expect(try await raw(store, b) == nil)
    }

    @Test func exportCarriesTheMark() async throws {
        let store = try await TestDB.makeStore()
        let a = try await played(store, "Alpha")
        _ = try await played(store, "Beta")
        try await store.setHoldsUp(.tooArchaic, for: [a])

        let csv = try await LibraryExporter(store.database).exportCSV()
        let lines = csv.split(separator: "\n").map(String.init)
        let header = lines[0].split(separator: ",").map(String.init)
        let col = try #require(header.firstIndex(of: "holds_up"))
        // Appended columns keep existing positions: v16's holds_up, then v17's Batocera hours.
        #expect(Array(header.suffix(2)) == ["holds_up", "batocera_playtime_hours"])
        #expect(header.firstIndex(of: "last_played") == 16)
        let alpha = try #require(lines.first { $0.hasPrefix("Alpha,") }).split(separator: ",", omittingEmptySubsequences: false)
        let beta = try #require(lines.first { $0.hasPrefix("Beta,") }).split(separator: ",", omittingEmptySubsequences: false)
        #expect(alpha[col] == "too_archaic")
        #expect(beta[col] == "")

        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let doc = try d.decode(LibraryExporter.Document.self, from: try await LibraryExporter(store.database).exportJSON())
        #expect(doc.games.first { $0.id == a }?.holdsUp == "too_archaic")
        #expect(HoldsUp(dbValue: doc.games.first { $0.id == a }?.holdsUp) == .tooArchaic)
    }

    /// Backward compatibility: an export game written before v16 (no `holdsUp` key) decodes
    /// as unrated, and the model enum decodes from its raw string.
    @Test func codableIsBackwardCompatible() throws {
        struct Wrapper: Codable { var mark: HoldsUp? }
        let old = try JSONDecoder().decode(Wrapper.self, from: Data("{}".utf8))
        #expect(old.mark == nil)
        let new = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"mark":"of_its_time"}"#.utf8))
        #expect(new.mark == .ofItsTime)
        #expect(HoldsUp(dbValue: "nonsense") == nil)
        #expect(HoldsUp.tooArchaic.explanation.contains("no longer playable for the gamer I am today"))
    }
}
