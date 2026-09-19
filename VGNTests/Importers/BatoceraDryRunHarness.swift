import Foundation
import Testing
@testable import VGN

/// A **gated** dry-run of the phase-1 sync against the owner's real Batocera share, writing to
/// a TEMP database (never the owner's `vgn.sqlite`), to sanity-check numbers for the handoff.
/// Inert unless `VGN_BATOCERA_DRYRUN=1` — a normal test run **never reads `/Volumes`**. The
/// share is opened read-only; nothing is written to it and no ROM/image is copied.
///
/// Run: `VGN_BATOCERA_DRYRUN=1 VGN_BATOCERA_SHARE=/Volumes/share xcodebuild … test \
///   -only-testing:VGNTests/BatoceraDryRunHarness/dryRunAgainstRealShare`
struct BatoceraDryRunHarness {

    @Test(.timeLimit(.minutes(10)))
    func dryRunAgainstRealShare() async throws {
        guard ProcessInfo.processInfo.environment["VGN_BATOCERA_DRYRUN"] == "1" else {
            print("BATOCERA dry-run skipped (set VGN_BATOCERA_DRYRUN=1 to run).")
            return
        }
        let sharePath = ProcessInfo.processInfo.environment["VGN_BATOCERA_SHARE"] ?? "/Volumes/share"
        let root = URL(fileURLWithPath: sharePath)

        // A throwaway temp-dir database — NEVER the owner's real library.
        let (db, tempDir) = try AppDatabase.temporary()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        _ = try await db.seedPlatforms(from: PlatformCatalog.entriesFromBundle())
        let store = RomCatalogStore(db)
        let sync = BatoceraSync(store: store)

        let start = ContinuousClock().now
        let summary = await sync.sync(root: root, force: true,
                                      skip: BatoceraPreferences.effectiveSkipSet)
        let elapsed = start.duration(to: ContinuousClock().now)

        print("""
        ── BATOCERA DRY RUN (\(sharePath)) ──────────────────────────────
        share reachable      : \(!summary.shareUnavailable)
        systems read         : \(summary.systemsRead)
        systems skipped      : \(summary.systemsSkipped)
        systems unchanged    : \(summary.systemsUnchanged)
        systems failed       : \(summary.systemsFailed)
        unknown systems      : \(summary.unknownSystems.sorted().joined(separator: ", "))
        entries added        : \(summary.entriesAdded)
        folded duplicates    : \(summary.foldedDuplicates)
        promotion candidates : \(summary.candidateCount)
        catalogue total      : \(try await store.totalCount())
        duration             : \(elapsed)
        failures             : \(summary.failures.map { "\($0.system): \($0.reason)" }.joined(separator: "; "))
        ────────────────────────────────────────────────────────────────
        """)

        // Correctness sanity (no wall-clock assertion).
        #expect(!summary.shareUnavailable, "share not mounted at \(sharePath)")
        #expect(summary.systemsRead > 0)
    }
}
