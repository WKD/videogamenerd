import Foundation
import Testing
import GRDB
@testable import VGN

#if DEBUG
/// Prints the Library Stats report timing at 2 000 games (PLAN §6.4 / §9). Asserts
/// **correctness only** — a wall-clock ceiling would flake under parallel test load
/// (same rule as ``ScalePerfTests``). Run explicitly:
/// `xcodebuild … test -only-testing:VGNTests/LibraryStatsReportPerfTests`.
struct LibraryStatsReportPerfTests {

    private func bestMS(_ body: () async throws -> Void) async rethrows -> Double {
        var best = Double.greatestFiniteMagnitude
        let clock = ContinuousClock()
        for _ in 0..<3 {
            let start = clock.now
            try await body()
            best = min(best, Double((clock.now - start).components.attoseconds) / 1e15)
        }
        return best
    }

    private func f(_ ms: Double) -> String { String(format: "%.2f", ms) }

    @Test(arguments: [2000])
    func reportScales(_ n: Int) async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let lib = LibraryStore(db)
        await PerfSeeder.seed(into: lib, count: n)
        let stats = LibraryStatsStore(db)

        let all = try await bestMS { _ = try await stats.report(scope: .all) }
        let owned = try await bestMS { _ = try await stats.report(scope: .owned) }
        let played = try await bestMS { _ = try await stats.report(scope: .played) }

        print("VGN scale perf @\(n): statsReport all=\(f(all))ms owned=\(f(owned))ms played=\(f(played))ms")

        // Correctness sanity: the scoped totals bracket the whole library.
        let report = try await stats.report(scope: .all)
        #expect(report.totalGames == n)
        #expect(report.playedGames <= n)
        #expect(report.addedByMonth.count == 12)
    }
}
#endif
