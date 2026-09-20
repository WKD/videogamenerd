import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The import matching progress (coordinator 2026-09-20): the pure label / fraction / ETA maths,
/// the coordinator emitting monotonic `completed`/`total` while matching, and the progress
/// sheet's Cancel button being genuinely clickable (a plain button, never a menu).
struct ImportProgressTests {

    // MARK: - Pure maths

    @Test func labelAndFraction() {
        #expect(ImportMatchProgress.label(completed: 137, total: 412, title: "Elden Ring")
                == "Matching 137 of 412 · Elden Ring")
        #expect(ImportMatchProgress.label(completed: 5, total: 10) == "Matching 5 of 10")
        #expect(ImportMatchProgress.label(completed: 0, total: nil) == "Matching…")
        #expect(ImportMatchProgress.fraction(completed: 1, total: 4) == 0.25)
        #expect(ImportMatchProgress.fraction(completed: 1, total: nil) == nil)   // indeterminate
    }

    @Test func etaHiddenBeforeTenAndFormattedAfter() {
        // Fewer than 10 done → hidden (unstable rate).
        #expect(ImportMatchProgress.etaText(completed: 5, total: 100, elapsedSeconds: 10) == nil)
        // Unknown total → hidden.
        #expect(ImportMatchProgress.etaText(completed: 20, total: nil, elapsedSeconds: 10) == nil)
        // 10 done in 30 s (3 s/item), 90 to go → 270 s → "about 5 min left" (rounded from 4.5).
        let eta = ImportMatchProgress.etaText(completed: 10, total: 100, elapsedSeconds: 30)
        #expect(eta == "about 5 min left")
        // Almost done → "under a minute".
        #expect(ImportMatchProgress.etaText(completed: 98, total: 100, elapsedSeconds: 98)
                == "under a minute left")
    }

    @Test func humanDurationBuckets() {
        #expect(ImportMatchProgress.humanDuration(20) == "under a minute")
        #expect(ImportMatchProgress.humanDuration(180) == "3 min")
        #expect(ImportMatchProgress.humanDuration(3600) == "1 h")
        #expect(ImportMatchProgress.humanDuration(3900) == "1 h 5 min")
    }

    // MARK: - Coordinator emits monotonic progress

    private struct FakeImporter: LibraryImporter {
        let source = "gog"
        let count: Int
        var dataSets: [ImportDataSet] { [] }
        func authenticate() async throws {}
        func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
            let rows = (0..<count).map {
                ImportStagingRow(source: "gog", externalID: "g\($0)", name: "Game \($0)", platform: "pc")
            }
            return ImportFetchResult(rows: rows)
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ImportProgress] = []
        func record(_ p: ImportProgress) { lock.withLock { values.append(p) } }
        var matching: [ImportProgress] { lock.withLock { values.filter { $0.phase == .matching } } }
    }

    @Test(.timeLimit(.minutes(1)))
    func coordinatorEmitsMonotonicMatchingProgress() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let coordinator = ImportSyncCoordinator(staging: ImportStagingStore(db))
        let recorder = ProgressRecorder()
        _ = try await coordinator.run(FakeImporter(count: 5), matcher: FakeImportMatcher()) {
            recorder.record($0)
        }
        let matching = recorder.matching
        #expect(!matching.isEmpty)
        #expect(matching.allSatisfy { $0.total == 5 })                       // stable total
        #expect(matching.map(\.completed) == Array(0..<5))                    // 0,1,2,3,4 monotonic
    }

    // MARK: - Cancel is clickable (plain button, no menu)

    @MainActor
    @Test(.timeLimit(.minutes(2)))
    func cancelButtonIsClickable() async throws {
        final class Box: @unchecked Sendable { var cancelled = false }
        let box = Box()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sheet = PSNSyncProgressSheet(
            progress: ImportProgress(phase: .matching, completed: 3, total: 10, detail: "Elden Ring"),
            onCancel: { box.cancelled = true }, now: { now })
        let window = ClickProbeWindow(sheet, size: NSSize(width: 420, height: 320))
        defer { window.close() }
        try await window.settle()
        _ = try await window.sweep(band: 300, stepX: 16, stepY: 16,
                                   observe: { box.cancelled ? 1 : 0 }, until: { box.cancelled })
        #expect(box.cancelled)
    }
}
