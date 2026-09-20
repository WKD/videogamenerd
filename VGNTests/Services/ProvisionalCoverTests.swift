import Foundation
import Testing
import GRDB
@testable import VGN

/// D2: an importer-supplied (Delicious) cover is **provisional** — the background cover
/// job still runs and upgrades it to a provider cover; a hit replaces it (and deletes the
/// old file), a miss keeps it with no refetch loop, and a user-chosen cover is never
/// touched. End-to-end over an in-memory DB with the scripted transport — no network.
struct ProvisionalCoverTests {

    private func writeTempPNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-prov-\(UUID().uuidString).png")
        try TestImage.png(width: width, height: height).write(to: url)
        return url
    }

    private func coverState(_ harness: EnrichmentHarness, _ id: Int64) async throws -> (file: String?, provisional: Bool) {
        try await harness.database.dbWriter.read { db in
            let r = try Row.fetchOne(
                db, sql: "SELECT cover_file, cover_provisional FROM games WHERE id = ?", arguments: [id])
            return (r?["cover_file"], (r?["cover_provisional"] as Int? ?? 0) == 1)
        }
    }

    private func filesInCovers(_ harness: EnrichmentHarness) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: harness.coversDirectory.path)) ?? []
    }

    @Test("A provider hit replaces a provisional cover and deletes the old file")
    func hitReplacesProvisional() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1)[0]

        // File a Delicious-style provisional cover (distinct bytes → distinct file name).
        let tmp = try writeTempPNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let provisional = try await harness.coverStore.importCover(from: tmp, gameID: id)
        _ = try await harness.library.setImportedCoverIfEmpty(gameID: id, coverFile: provisional.coverFile)

        var state = try await coverState(harness, id)
        #expect(state.file == provisional.coverFile)
        #expect(state.provisional)

        await harness.coordinator.pump()

        state = try await coverState(harness, id)
        #expect(state.file != nil)
        #expect(state.file != provisional.coverFile)   // upgraded to the provider cover
        #expect(!state.provisional)                    // marker cleared
        // The old provisional original was deleted (only the new cover remains).
        #expect(!filesInCovers(harness).contains(provisional.coverFile))
        #expect(filesInCovers(harness).contains(state.file!))
    }

    @Test("A miss keeps the provisional cover, with no refetch loop")
    func missKeepsProvisional() async throws {
        // Empty chain → the provider always misses.
        let harness = try await EnrichmentHarness.makeEmptyChain()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1)[0]

        let tmp = try writeTempPNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let provisional = try await harness.coverStore.importCover(from: tmp, gameID: id)
        _ = try await harness.library.setImportedCoverIfEmpty(gameID: id, coverFile: provisional.coverFile)

        await harness.coordinator.pump()

        var state = try await coverState(harness, id)
        #expect(state.file == provisional.coverFile)   // kept — nothing better was found
        #expect(state.provisional)                     // still provisional

        // Second pass: the completed cover job is not re-enqueued (no refetch loop).
        await harness.coordinator.pump()
        state = try await coverState(harness, id)
        #expect(state.file == provisional.coverFile)
        let coverJobs = try await harness.database.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM enrichment_jobs WHERE kind = 'cover' AND game_id = ?",
                             arguments: [id]) ?? -1
        }
        #expect(coverJobs == 1)
    }

    @Test("A user-chosen cover is never replaced, even while a cover job is queued")
    func userChosenNeverReplaced() async throws {
        let harness = try await EnrichmentHarness.make()
        defer { harness.cleanup() }
        let id = try await harness.addGames(1)[0]

        // Provisional first, then the owner picks a cover (clears provisional, locks it).
        let tmp = try writeTempPNG(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let provisional = try await harness.coverStore.importCover(from: tmp, gameID: id)
        _ = try await harness.library.setImportedCoverIfEmpty(gameID: id, coverFile: provisional.coverFile)
        try await harness.library.setUserCover(gameID: id, coverFile: "chosen.png")
        _ = try await harness.jobStore.enqueue(kind: .cover, gameID: id)

        await harness.coordinator.pump()

        let state = try await coverState(harness, id)
        #expect(state.file == "chosen.png")   // untouched
        #expect(!state.provisional)
    }
}
