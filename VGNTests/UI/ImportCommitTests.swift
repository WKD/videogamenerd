import Foundation
import GRDB
import Testing
@testable import VGN

/// Atomic commit of scanned drafts against a real in-memory database
/// (`LiveScanCommitter`). Serialized because it touches GRDB on the main actor.
@MainActor
@Suite(.serialized)
struct ImportCommitTests {

    private func gameCount(_ store: LibraryStore) async throws -> Int {
        try await store.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? 0 }
    }
    private func productCount(_ store: LibraryStore) async throws -> Int {
        try await store.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products") ?? 0 }
    }

    @Test("Singles commit in one transaction")
    func singlesCommit() async throws {
        let store = try await TestDB.makeStore()
        let committer = LiveScanCommitter(store: store)
        let outcomes = try await committer.commit(singles: [
            GameDraft(title: "Bloodborne", igdbID: 1, platformIDs: ["ps4"], owned: true, source: .photo),
            GameDraft(title: "Returnal", igdbID: 2, platformIDs: ["ps5"], owned: true, source: .photo),
        ], compilations: [])
        #expect(outcomes.count == 2)
        #expect(try await gameCount(store) == 2)
        #expect(try await productCount(store) == 2)
    }

    @Test("A compilation commits its product and members")
    func compilationCommit() async throws {
        let store = try await TestDB.makeStore()
        let committer = LiveScanCommitter(store: store)
        let compilation = ScanCompilationDraft(
            product: ProductDraft(title: "Jak Collection", platformID: "ps3", source: .photo, igdbID: 500),
            members: [
                CompilationMemberDraft(title: "Jak 1", igdbID: 501, position: 0),
                CompilationMemberDraft(title: "Jak 2", igdbID: 502, position: 1),
            ]
        )
        let outcomes = try await committer.commit(
            singles: [GameDraft(title: "Nioh", igdbID: 3, platformIDs: ["ps4"], owned: true, source: .photo)],
            compilations: [compilation]
        )
        #expect(outcomes.count == 3)                    // 2 members + 1 single
        #expect(try await gameCount(store) == 3)
        #expect(try await productCount(store) == 2)     // 1 compilation + 1 single
    }

    @Test("A failure after a compilation rolls everything back — nothing half-added")
    func failureRollsBack() async throws {
        let store = try await TestDB.makeStore()
        let committer = LiveScanCommitter(store: store)
        // First a valid compilation is written, then the single fails on an unknown
        // platform (foreign-key violation). The committer must undo the compilation.
        let compilation = ScanCompilationDraft(
            product: ProductDraft(title: "Jak Collection", platformID: "ps3", source: .photo, igdbID: 500),
            members: [CompilationMemberDraft(title: "Jak 1", igdbID: 501, position: 0)]
        )
        let badSingle = GameDraft(title: "Broken", igdbID: 9, platformIDs: ["does-not-exist"], owned: true, source: .photo)

        await #expect(throws: (any Error).self) {
            _ = try await committer.commit(singles: [badSingle], compilations: [compilation])
        }
        #expect(try await gameCount(store) == 0)
        #expect(try await productCount(store) == 0)
    }
}

/// Settings persistence round-trip.
struct ImportSettingsTests {

    @Test("Photo-scan settings persist and clamp concurrency to 1–4")
    func persistRoundTrip() {
        let suite = "VGNPhotoScanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsPhotoScanPreferences(defaults: defaults)
        var settings = PhotoScanSettings()
        settings.binaryOverride = "/usr/local/bin/claude"
        settings.model = "opus"
        settings.maxConcurrent = 9        // out of range
        settings.enginePreference = .visionOnly
        store.save(settings)

        let loaded = UserDefaultsPhotoScanPreferences(defaults: defaults).load()
        #expect(loaded.binaryOverride == "/usr/local/bin/claude")
        #expect(loaded.model == "opus")
        #expect(loaded.maxConcurrent == 4)          // clamped
        #expect(loaded.enginePreference == .visionOnly)
    }

    @Test("Defaults are Claude-with-Vision-fallback at concurrency 3")
    func defaults() {
        let settings = PhotoScanSettings()
        #expect(settings.enginePreference == .claudeWithVisionFallback)
        #expect(settings.clampedConcurrency == 3)
        #expect(settings.model.isEmpty)
    }
}
