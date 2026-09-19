import Foundation
import Testing
import GRDB
@testable import VGN

/// `games.origin` is set once, at creation, from the game's source (owner request):
/// Quick Add / manual → `manual`, photo scan → `photo`, an importer → its source.
/// Adding a later copy never changes it. Surfaced on ``GameDetail`` and the export.
@Suite(.serialized) @MainActor struct GameOriginTaggingTests {

    private func makeStore() async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        let store = LibraryStore(db)
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
        }
        return store
    }

    @Test func photoOwnedGameGetsPhotoOriginAndKeepsItWhenACopyIsAdded() async throws {
        let store = try await makeStore()
        let out = try await store.addGame(GameDraft(
            title: "Shelf Game", platformIDs: ["pc"], owned: true, source: .photo))
        let gameID = out.gameID
        // A manual second copy must NOT change the origin.
        _ = try await store.addCopy(gameID: gameID, platformID: "pc", source: .manual)
        let detail = try await store.gameDetail(id: gameID)
        #expect(detail?.origin == .photo)
    }

    @Test func playedOnlyGameGetsManualOrigin() async throws {
        let store = try await makeStore()
        let out = try await store.addGame(GameDraft(
            title: "Played Only", played: true, source: .manual))
        let detail = try await store.gameDetail(id: out.gameID)
        #expect(detail?.origin == .manual)
    }

    @Test func gogImportCommitTagsGameOriginGOG() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
        }
        let staging = ImportStagingStore(db)
        let item = ImportCommitItem(
            source: ImportSourceID.gog, externalID: "42", platformID: "pc",
            format: .digital,
            target: .newGame(ImportNewGameSpec(title: "Witcher 3")))
        let result = try await staging.commit([item])
        #expect(result.gamesCreated == 1)
        let gameID = try #require(result.affectedGameIDs.first)
        let store = LibraryStore(db)
        let detail = try await store.gameDetail(id: gameID)
        #expect(detail?.origin == .gog)
    }

    @Test func compilationMembersInheritProductSourceAsOrigin() async throws {
        let store = try await makeStore()
        let (_, members) = try await store.addCompilation(
            product: ProductDraft(title: "Retro Pack", platformID: "pc", source: .photo),
            members: [
                CompilationMemberDraft(title: "Game A", position: 0),
                CompilationMemberDraft(title: "Game B", position: 1),
            ])
        for outcome in members {
            let detail = try await store.gameDetail(id: outcome.gameID)
            #expect(detail?.origin == .photo)
        }
    }
}
