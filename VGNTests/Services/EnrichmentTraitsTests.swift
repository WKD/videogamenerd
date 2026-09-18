import Foundation
import Testing
import GRDB
@testable import VGN

/// §7b enrichment: the metadata job now also writes `game_traits` + the crowd
/// rating, respects the `user_edited` marker (even on refresh), and `enqueueMissing`
/// re-arms games enriched before traits existed. Uses the scripted transport (its
/// synthetic game carries traits + a rating).
struct EnrichmentTraitsTests {

    private func traits(_ harness: EnrichmentHarness, _ gameID: Int64) async throws -> [(String, String)] {
        try await harness.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, value FROM game_traits WHERE game_id = ? ORDER BY kind, value",
                             arguments: [gameID]).map { ($0["kind"], $0["value"]) }
        }
    }

    @Test("Draining writes traits + crowd rating")
    func traitsAndRatingWritten() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let ids = try await harness.addGames(3)
        await harness.coordinator.pump()

        for id in ids {
            let game = try #require(try await harness.game(id))
            #expect(game.igdbRating == 88.5)
            #expect(game.igdbRatingCount == 300)
            let t = try await traits(harness, id)
            #expect(t.contains { $0 == ("developer", "Stub Studio") })   // publisher excluded
            #expect(!t.contains { $0.0 == "developer" && $0.1 == "Stub Publisher" })
            #expect(t.contains { $0 == ("franchise", "Synthetica") })
            #expect(t.contains { $0 == ("series", "Synth Saga") })
            #expect(t.contains { $0 == ("theme", "Fantasy") })
            #expect(t.contains { $0 == ("mode", "Single player") })
            #expect(t.contains { $0 == ("perspective", "Third person") })
            #expect(t.contains { $0 == ("similar", "5000") })
        }
    }

    @Test("A user-edited cover survives a refresh; untouched fields are re-fetched")
    func userEditedCoverSurvivesRefresh() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1).first!
        await harness.coordinator.pump()

        // User imports their own cover (marks it edited).
        try await harness.library.setUserCover(gameID: id, coverFile: "hand-picked.jpg")

        // A forced refresh must NOT replace the user's cover…
        await harness.coordinator.refresh(gameID: id)
        let game = try #require(try await harness.game(id))
        #expect(game.coverFile == "hand-picked.jpg")

        // …but traits (untouched) are still present after the refresh.
        #expect(try await traits(harness, id).isEmpty == false)
        #expect(game.igdbRating == 88.5)
        _ = game
    }

    @Test("A user-edited title is never renamed, even on refresh")
    func userEditedTitleProtected() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1).first!
        await harness.coordinator.pump()

        try await harness.library.editTitle(gameID: id, "My Own Title")
        await harness.coordinator.refresh(gameID: id)
        let game = try #require(try await harness.game(id))
        #expect(game.title == "My Own Title")
    }

    @Test("enqueueMissing re-arms a done metadata job whose traits/rating are missing")
    func reArmsForMissingTraits() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1).first!
        await harness.coordinator.pump()   // metadata now done, traits + rating written

        // Simulate a pre-§7b library: metadata `done`, but no traits and no rating.
        try await harness.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM game_traits WHERE game_id = ?", arguments: [id])
            try db.execute(sql: "UPDATE games SET igdb_rating = NULL, igdb_rating_count = NULL WHERE id = ?",
                           arguments: [id])
        }
        // A plain pump should notice and refill (without touching covers/TTB).
        await harness.coordinator.pump()
        let game = try #require(try await harness.game(id))
        #expect(game.igdbRating == 88.5)
        #expect(try await traits(harness, id).isEmpty == false)
    }
}
