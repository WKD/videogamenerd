import Foundation
import GRDB
import Testing
@testable import VGN

/// The Bundles-to-Expand candidate list + its persisted "not a bundle" dismissal (PLAN §5.1,
/// wave 16): a bundle-looking library game is a candidate; dismissing it (persisted in
/// `app_state`) removes it for good; an ordinary game is never a candidate. No network.
struct BundleCandidatesDismissTests {

    @discardableResult
    private func addLoneSingle(_ store: LibraryStore, title: String, igdbID: Int64?) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title))
            try g.insert(db)
            let gid = g.id!
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source) VALUES ('ps3', 'single', 'physical', 'manual')
                """)
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, gid])
            try db.execute(sql: "INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, 'ps3', 0)",
                           arguments: [gid])
            return gid
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bundleLookingGameIsCandidateAndOrdinaryIsNot() async throws {
        let store = try await TestDB.makeStore()
        let bundleID = try await addLoneSingle(store, title: "Halo: The Master Chief Collection", igdbID: 10)
        _ = try await addLoneSingle(store, title: "Celeste", igdbID: 20)

        let candidates = try await store.bundleExpansionCandidates()
        #expect(candidates.contains { $0.gameID == bundleID })
        #expect(!candidates.contains { $0.title == "Celeste" })
    }

    @Test(.timeLimit(.minutes(1)))
    func dismissRemovesFromListForGood() async throws {
        let store = try await TestDB.makeStore()
        let bundleID = try await addLoneSingle(store, title: "The Orange Box", igdbID: 30)
        #expect(try await store.bundleExpansionCandidates().contains { $0.gameID == bundleID })

        try await store.dismissBundleCandidate(gameID: bundleID)
        #expect(try await store.dismissedBundleCandidateIDs().contains(bundleID))
        #expect(!(try await store.bundleExpansionCandidates().contains { $0.gameID == bundleID }))

        // Idempotent — dismissing again keeps a single entry, list still excludes it.
        try await store.dismissBundleCandidate(gameID: bundleID)
        #expect(try await store.dismissedBundleCandidateIDs() == [bundleID])
    }
}
