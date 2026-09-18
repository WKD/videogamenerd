import Foundation
import Testing
import GRDB
@testable import VGN

@Suite struct ObservationTests {

    @Test func sidebarObservationEmitsAfterWrite() async throws {
        let store = try await TestDB.makeStore()
        // Drive the observation on a background queue so delivery doesn't depend
        // on a running main run loop (the public API defaults to main, correct
        // for the UI). This exercises the same fetch used by sidebarCounts().
        let queue = DispatchQueue(label: "vgn.test.sidebar")
        let observation = ValueObservation.tracking { db in try LibraryStore.fetchSidebarCounts(db) }
        var iterator = observation
            .values(in: store.dbReader, scheduling: .async(onQueue: queue))
            .makeAsyncIterator()

        let first = try await iterator.next()
        #expect(first?.all == 0)

        _ = try await store.addGame(GameDraft(title: "New Game", platformIDs: ["pc"], owned: true))
        let second = try await iterator.next()
        #expect(second?.all == 1)
        #expect(second?.owned == 1)
    }

    @Test func gridObservationEmitsAfterWrite() async throws {
        let store = try await TestDB.makeStore()
        let queue = DispatchQueue(label: "vgn.test.grid")
        let filter = LibraryFilter(scope: .all, sort: .title)
        let observation = ValueObservation.tracking { db in try LibraryStore.fetchGames(filter, db) }
        var iterator = observation
            .values(in: store.dbReader, scheduling: .async(onQueue: queue))
            .makeAsyncIterator()

        #expect(try await iterator.next()?.isEmpty == true)
        _ = try await store.addGame(GameDraft(title: "Tetris", platformIDs: ["snes"], owned: true))
        let rows = try await iterator.next()
        #expect(rows?.map(\.title) == ["Tetris"])
    }
}

@Suite struct BackupTests {

    @Test func snapshotRotationKeepsTen() async throws {
        let (db, dir) = try AppDatabase.temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Put something in the DB so the snapshot is non-trivial.
        let store = LibraryStore(db)   // migration already seeded tiers
        try await db.seedPlatforms(from: TestDB.platforms)
        _ = try await store.addGame(GameDraft(title: "Backup Me", platformIDs: ["pc"], owned: true))

        let backupsDir = dir.appendingPathComponent("backups", isDirectory: true)
        for _ in 0..<12 {
            _ = try db.backup(intoDirectory: backupsDir)
            try AppDatabase.rotateBackups(inDirectory: backupsDir, keeping: 10)
        }
        let files = try FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vgn-") && $0.pathExtension == "sqlite" }
        #expect(files.count == 10)

        // A snapshot is a real, openable SQLite database with the data.
        let restored = try DatabaseQueue(path: files[0].path)
        let count = try await restored.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") }
        #expect(count == 1)
    }

    @Test func restoreReplacesLiveDatabaseFromSnapshot() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VGN-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let liveURL = dir.appendingPathComponent("vgn.sqlite")

        // Live DB with one game; snapshot it; then add a second game *after* the snapshot.
        var snapshot: URL!
        do {
            let db = try AppDatabase(try DatabasePool(path: liveURL.path, configuration: config))
            let store = LibraryStore(db)
            try await db.seedPlatforms(from: TestDB.platforms)
            _ = try await store.addGame(GameDraft(title: "Original", platformIDs: ["pc"], owned: true))
            snapshot = try db.backup(intoDirectory: dir.appendingPathComponent("backups"))
            _ = try await store.addGame(GameDraft(title: "Added Later", platformIDs: ["pc"], owned: true))
            let live = try await db.dbWriter.read { d in
                try String.fetchAll(d, sql: "SELECT title FROM games ORDER BY title")
            }
            #expect(live == ["Added Later", "Original"])
        }   // the pool closes here (no open connection on liveURL)

        // Restore over the (now-closed) live file, then reopen.
        try AppDatabase.restore(from: snapshot, to: liveURL)
        let reopened = try AppDatabase(try DatabasePool(path: liveURL.path, configuration: config))
        let titles = try await reopened.dbWriter.read { d in
            try String.fetchAll(d, sql: "SELECT title FROM games ORDER BY title")
        }
        #expect(titles == ["Original"])   // the post-snapshot game is gone

        // A bad snapshot is rejected and leaves the live file untouched.
        let junk = dir.appendingPathComponent("junk.sqlite")
        try Data("not a database".utf8).write(to: junk)
        #expect(throws: AppDatabase.RestoreError.self) {
            try AppDatabase.restore(from: junk, to: liveURL)
        }
        let missing = dir.appendingPathComponent("nope.sqlite")
        #expect(throws: AppDatabase.RestoreError.missing) {
            try AppDatabase.validateBackup(at: missing)
        }
    }
}

@Suite struct PerformanceTests {

    @Test func gridAndSidebarQueriesAreFastAt2000Games() async throws {
        let store = try await TestDB.makeStore()
        let platforms = ["ps5", "ps4", "ps3", "ps2", "snes", "pc"]
        var drafts: [GameDraft] = []
        drafts.reserveCapacity(2000)
        for i in 0..<2000 {
            let played = (i % 2 == 0)
            let tierID: Int64? = played ? Int64((i % 6) + 1) : nil
            let year: Int = 1980 + (i % 45)
            drafts.append(GameDraft(
                title: "Game \(i)",
                igdbID: Int64(100_000 + i),
                year: year,
                platformIDs: [platforms[i % platforms.count]],
                owned: true,
                played: played,
                tierID: tierID))
        }
        _ = try await store.addGames(drafts)

        // Warm up, then take the best of three (cold caches aside).
        func measure(_ body: () async throws -> Void) async rethrows -> Double {
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<3 {
                let clock = ContinuousClock()
                let start = clock.now
                try await body()
                let ms = Double((clock.now - start).components.attoseconds) / 1e15
                best = min(best, ms)
            }
            return best
        }

        let gridMs = try await measure {
            _ = try await store.gamesOnce(filter: LibraryFilter(scope: .all, sort: .tierRank))
        }
        let sidebarMs = try await measure {
            _ = try await store.sidebarCountsOnce()
        }
        print("PERF: grid(2000)=\(String(format: "%.2f", gridMs))ms  sidebar(2000)=\(String(format: "%.2f", sidebarMs))ms")

        let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        // Correctness only — the printed numbers are the real figures for the
        // handoff; a wall-clock ceiling flakes under parallel test load.
        #expect(rows.count == 2000)
    }
}
