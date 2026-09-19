import Foundation
import Testing
@testable import VGN

/// The shared import review model (PLAN §14.3): buckets, pre-ticking, platform policy
/// re-map + per-row override, alternatives pick, ignore/restore persistence, the commit
/// payload, an idempotent second import, and a large-list build time (printed).
@MainActor
@Suite(.serialized)
struct ImportReviewModelTests {

    // MARK: Fixtures

    private func match(_ igdbID: Int64, _ name: String, year: Int? = nil,
                       score: Double, slugs: [String] = ["pc", "mac"]) -> ScanMatch {
        ScanMatch(igdbID: igdbID, name: name, releaseYear: year, coverImageID: "co\(igdbID)",
                  platformSlugs: slugs, score: score, matchedName: name)
    }

    /// Two ordinary games (one confident, one plausible), one soundtrack (noise), one
    /// Linux-only. Returns the seeded staging store and a matching sync result.
    private func seed() async throws -> (AppDatabase, ImportStagingStore, ImportSyncResult) {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let rows = [
            ImportStagingRow(source: "gog", externalID: "10", name: "Baldur's Gate",
                             platform: "mac", releaseYear: 1998, macAvailable: true),
            ImportStagingRow(source: "gog", externalID: "20", name: "Windows Only Game",
                             platform: "pc", releaseYear: 2005, macAvailable: false),
            ImportStagingRow(source: "gog", externalID: "30", name: "Great OST",
                             platform: "pc", ignoreReason: .soundtrackOrGoodies),
            ImportStagingRow(source: "gog", externalID: "40", name: "Penguin Quest",
                             platform: "pc", macAvailable: false, linuxOnly: true),
        ]
        try await staging.upsert(rows)
        let summary = ImportSyncSummary(
            source: "gog", fromCache: 2, fromNetwork: 3, stagedTotal: 4,
            newCount: 3, ignoredCount: 1, budgetUsed: 3, ownedGap: 1)
        let matches = [
            ImportMatchResult(externalID: "10", name: "Baldur's Gate",
                              outcome: ScanMatchOutcome(
                                best: match(101, "Baldur's Gate", year: 1998, score: 0.97),
                                alternatives: [match(102, "Baldur's Gate II", year: 2000, score: 0.80)],
                                bucket: .confident)),
            ImportMatchResult(externalID: "20", name: "Windows Only Game",
                              outcome: ScanMatchOutcome(
                                best: match(201, "Windows Only Game", year: 2005, score: 0.80),
                                alternatives: [], bucket: .plausible)),
        ]
        let result = ImportSyncResult(summary: summary, matches: matches, rows: rows)
        return (db, staging, result)
    }

    private func model(_ staging: ImportStagingStore, _ result: ImportSyncResult) -> ImportReviewModel {
        ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging, result: result)
    }

    // MARK: Tests

    @Test(.timeLimit(.minutes(1)))
    func bucketsAndPreTick() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        #expect(m.rows(in: .new).count == 3)          // BG, Windows game, Penguin Quest
        #expect(m.rows(in: .ignored).count == 1)       // the soundtrack
        #expect(m.rows(in: .alreadyMatched).isEmpty)
        // Only the confident match is pre-ticked.
        #expect(m.rows.first { $0.externalID == "10" }?.include == true)
        #expect(m.rows.first { $0.externalID == "20" }?.include == false)
        #expect(m.committableCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func ownedGapNoteSurfaces() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        #expect(m.summary.ownedGapNote?.contains("1 product") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func platformPolicyRemapAndOverride() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        // Default: Mac where available.
        #expect(m.rows.first { $0.externalID == "10" }?.platform == "mac")
        // Always PC re-maps every pending row.
        m.platformPolicy = .alwaysPC
        #expect(m.rows.allSatisfy { $0.platform == "pc" })
        // Back to Mac-when-available.
        m.platformPolicy = .macWhenAvailable
        #expect(m.rows.first { $0.externalID == "10" }?.platform == "mac")   // has Mac build
        #expect(m.rows.first { $0.externalID == "20" }?.platform == "pc")    // Windows only
        // Per-row override sticks.
        m.setPlatform("mac", externalID: "20")
        #expect(m.rows.first { $0.externalID == "20" }?.platform == "mac")
    }

    @Test(.timeLimit(.minutes(1)))
    func linuxOnlyFlagCarried() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        #expect(m.rows.first { $0.externalID == "40" }?.linuxOnly == true)
        #expect(m.rows.first { $0.externalID == "40" }?.platform == "pc")
    }

    @Test(.timeLimit(.minutes(1)))
    func alternativesPickUpdatesRow() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        let alt = match(102, "Baldur's Gate II", year: 2000, score: 0.95)
        m.chooseAlternative(alt, externalID: "10")
        let row = m.rows.first { $0.externalID == "10" }
        #expect(row?.proposedMatch?.igdbID == 102)
        #expect(row?.include == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func ignoreAndRestorePersist() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        m.ignore("20")
        #expect(m.rows.first { $0.externalID == "20" }?.bucket == .ignored)
        await pollAsync(until: { ((try? await staging.titles(source: "gog")) ?? [])
            .first { $0.externalID == "20" }?.ignored == true })

        // Reopening rebuilds from the persisted decision.
        let reopened = model(staging, result)
        await reopened.load()
        #expect(reopened.rows.first { $0.externalID == "20" }?.bucket == .ignored)

        // Restore the noise row.
        reopened.restore("30")
        await pollAsync(until: { ((try? await staging.titles(source: "gog")) ?? [])
            .first { $0.externalID == "30" }?.ignored == false })
    }

    @Test(.timeLimit(.minutes(1)))
    func commitPayloadForTickedRows() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        m.setInclude(true, externalID: "20")   // tick the plausible one too
        let items = m.commitItems()
        #expect(items.count == 2)
        let bg = try #require(items.first { $0.externalID == "10" })
        #expect(bg.platformID == "mac")
        #expect(bg.format == .digital)
        #expect(bg.source == "gog")
        if case .newGame(let spec) = bg.target {
            #expect(spec.igdbID == 101)
            #expect(spec.title == "Baldur's Gate")
        } else { Issue.record("expected newGame target") }
    }

    @Test(.timeLimit(.minutes(2)))
    func commitCreatesGamesAndSecondImportProposesNothing() async throws {
        let (_, staging, result) = try await seed()
        let m = model(staging, result)
        await m.load()
        m.setInclude(true, externalID: "20")
        m.commit()
        await poll(1_000, until: { m.committed })
        #expect(m.successMessage?.contains("imported from GOG") == true)

        // The committed rows are now matched, so a second review proposes nothing new.
        let second = model(staging, result)
        await second.load()
        #expect(second.rows(in: .alreadyMatched).count == 2)
        #expect(second.committableCount == 0)
        #expect(second.commitItems().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func successMessageCountsImportedAndExisting() {
        let result = ImportCommitResult(gamesCreated: 3, productsAdded: 1, skippedExisting: 2)
        let message = ImportReviewModel.successMessage(from: result, sourceLabel: "GOG")
        #expect(message == "4 games imported from GOG · 2 already in your library")
    }

    @Test(.timeLimit(.minutes(2)))
    func largeListBuildTimeIsPrinted() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        var rows: [ImportStagingRow] = []
        var matches: [ImportMatchResult] = []
        rows.reserveCapacity(1_000)
        for i in 0..<1_000 {
            let ext = String(i)
            rows.append(ImportStagingRow(source: "gog", externalID: ext, name: "Game \(i)",
                                         platform: "pc", releaseYear: 2000 + i % 20,
                                         macAvailable: i % 2 == 0))
            matches.append(ImportMatchResult(externalID: ext, name: "Game \(i)",
                outcome: ScanMatchOutcome(best: match(Int64(10_000 + i), "Game \(i)", score: 0.95),
                                          alternatives: [], bucket: .confident)))
        }
        try await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: "gog", stagedTotal: 1_000, newCount: 1_000),
            matches: matches, rows: rows)
        let m = model(staging, result)
        let clock = ContinuousClock()
        let start = clock.now
        await m.load()
        let elapsed = start.duration(to: clock.now)
        print("ImportReviewModel: built \(m.rows.count) rows in \(elapsed)")
        #expect(m.rows.count == 1_000)
    }
}
