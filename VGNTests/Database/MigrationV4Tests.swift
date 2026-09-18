import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v4 (PLAN §7b): `game_traits`, `games.igdb_rating(_count)`,
/// `rec_feedback`, and the `games.user_edited` marker — plus the trait/rating
/// writes and the user-edit guard on `LibraryStore`.
@Suite struct MigrationV4Tests {

    /// True iff `body` throws (avoids a `#expect(throws:)` macro-expansion quirk
    /// with GRDB write closures).
    static func threw(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch { return true }
    }

    // MARK: - Migration from a populated v3 database keeps data

    @Test func v4FromV3KeepsDataAndAddsSchema() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        // Up to v3, then seed a game + product.
        var upToV3 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV3)
        Migrations.registerV2(in: &upToV3)
        Migrations.registerV3(in: &upToV3)
        try upToV3.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('ps4', 'PlayStation 4', 'PS4', 'Sony', 'Sony', 'console', 1)
                """)
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'Bloodborne', 1)")
        }

        // Add v4.
        var full = upToV3
        Migrations.registerV4(in: &full)
        try full.migrate(queue)

        // Data preserved + new columns with defaults; valid inserts.
        let preserved = try await queue.write { db -> (Int, String?, Double?) in
            try db.execute(sql: "INSERT INTO game_traits (game_id, kind, value) VALUES (1, 'developer', 'FromSoftware')")
            try db.execute(sql: "INSERT INTO rec_feedback (game_id, action) VALUES (1, 'snooze')")
            return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1,
                    try String.fetchOne(db, sql: "SELECT user_edited FROM games WHERE id = 1"),
                    try Double.fetchOne(db, sql: "SELECT igdb_rating FROM games WHERE id = 1"))
        }
        #expect(preserved.0 == 1)
        #expect(preserved.1 == "")
        #expect(preserved.2 == nil)

        // CHECK constraints reject invalid kinds / actions.
        let rejectsTrait = await Self.threw {
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO game_traits (game_id, kind, value) VALUES (1, 'nonsense', 'x')")
            }
        }
        #expect(rejectsTrait)
        let rejectsAction = await Self.threw {
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO rec_feedback (game_id, action) VALUES (1, 'bogus')")
            }
        }
        #expect(rejectsAction)

        // Cascade: deleting the game removes its traits + feedback.
        try await queue.write { db in try db.execute(sql: "DELETE FROM games WHERE id = 1") }
        let remaining = try await queue.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM game_traits") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rec_feedback") ?? -1)
        }
        #expect(remaining.0 == 0)
        #expect(remaining.1 == 0)
    }

    // MARK: - Trait writes (replace-all; non-persisted kinds skipped)

    @Test func setTraitsReplacesAllAndSkipsSyntheticKinds() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(title: "Elden Ring", igdbID: 119133,
                                                    platformIDs: ["ps5"], owned: true)).gameID
        try await store.updateMetadata(gameID: id, MetadataPatch(traits: [
            GameTrait(kind: .developer, value: "FromSoftware"),
            GameTrait(kind: .theme, value: "Fantasy"),
            GameTrait(kind: .similar, value: "7334"),
            GameTrait(kind: .genre, value: "RPG"),          // engine-only → NOT persisted
        ]))
        let rows = try await store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, value FROM game_traits WHERE game_id = ? ORDER BY kind, value",
                             arguments: [id]).map { ($0["kind"] as String, $0["value"] as String) }
        }
        #expect(rows.contains { $0 == ("developer", "FromSoftware") })
        #expect(rows.contains { $0 == ("similar", "7334") })
        #expect(!rows.contains { $0.0 == "genre" })          // synthetic kind skipped

        // Replace-all: a new set wipes the old.
        try await store.updateMetadata(gameID: id, MetadataPatch(traits: [
            GameTrait(kind: .developer, value: "FromSoftware"),
        ]))
        let after = try await store.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM game_traits WHERE game_id = ?", arguments: [id]) ?? -1
        }
        #expect(after == 1)
    }

    // MARK: - user_edited marker + guard

    @Test func userCoverAndTitleEditsSetTheMarker() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(title: "Working Title", igdbID: 1,
                                                   platformIDs: ["ps4"], owned: true)).gameID
        try await store.setUserCover(gameID: id, coverFile: "mine.jpg")
        try await store.editTitle(gameID: id, "My Title")

        let edited = try await store.database.dbWriter.read { db in
            try LibraryStore.userEditedFields(id, db)
        }
        #expect(edited.contains(.cover))
        #expect(edited.contains(.title))
        #expect(!edited.contains(.summary))
    }

    @Test func userEditedFieldsRoundTripThroughRawString() {
        var set = UserEditedFields()
        set = set.inserting(.cover).inserting(.summary)
        #expect(set.raw == "cover,summary")
        let parsed = UserEditedFields(raw: " summary , cover ")
        #expect(parsed.contains(.cover) && parsed.contains(.summary))
        #expect(parsed.removing(.cover).contains(.cover) == false)
    }
}
