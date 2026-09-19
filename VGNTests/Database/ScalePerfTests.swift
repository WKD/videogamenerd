import Foundation
import Testing
import GRDB
@testable import VGN

#if DEBUG
/// Whole-app scale timings at 2 000 and 10 000 games (PLAN §9/§10). These print
/// the real figures for the hardening handoff and assert **correctness only** — a
/// wall-clock ceiling would flake under parallel test load. Run explicitly:
/// `xcodebuild … test -only-testing:VGNTests/ScalePerfTests`.
struct ScalePerfTests {

    /// Best of three runs, in milliseconds.
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

    @Test(arguments: [2000, 10000])
    func hotQueriesScale(_ n: Int) async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let lib = LibraryStore(db)
        let rank = RankingStore(db)
        let rec = RecommendationStore(db)
        await PerfSeeder.seed(into: lib, count: n)

        let grid = try await bestMS {
            _ = try await lib.gamesOnce(filter: LibraryFilter(scope: .all, sort: .tierRank))
        }
        let sidebar = try await bestMS { _ = try await lib.sidebarCountsOnce() }
        let fts = try await bestMS {
            _ = try await lib.gamesOnce(filter: LibraryFilter(searchText: "shadow", scope: .all))
        }
        let tierBoard = try await bestMS { _ = try await rank.tierBoardOnce() }
        let theTop = try await bestMS { _ = try await rank.theTopOnce(filter: LibraryFilter(scope: .all)) }
        let recommend = try await bestMS { _ = try await rec.recommend(bracket: TimeBracket(shelf: .fewWeeks)) }
        let enqueue = try await bestMS {
            _ = try await db.dbWriter.write { d in
                try EnrichmentCoordinator.enqueueMissingJobs(now: Date(), db: d)
            }
        }

        print("""
        VGN scale perf @\(n): grid=\(f(grid))ms sidebar=\(f(sidebar))ms fts=\(f(fts))ms \
        tierBoard=\(f(tierBoard))ms theTop=\(f(theTop))ms recommend=\(f(recommend))ms \
        enqueueMissing=\(f(enqueue))ms
        """)

        let all = try await lib.gamesOnce(filter: LibraryFilter(scope: .all))
        #expect(all.count == n)
    }

    @Test(arguments: [2000, 10000])
    func catalogTitleIndexScale(_ n: Int) async throws {
        let index = CatalogTitleIndex(catalog: TestCatalog.catalog)
        let entries: [CatalogCacheEntry] = (0..<n).map { i in
            CatalogCacheEntry(
                igdbID: Int64(i),
                json: Data("{\"id\":\(i),\"name\":\"Shadow Kingdom \(i)\"}".utf8),
                fetchedAt: Date())
        }
        let clock = ContinuousClock()
        let bStart = clock.now
        await index.upsert(entries)
        let build = Double((clock.now - bStart).components.attoseconds) / 1e15
        let sStart = clock.now
        let hits = await index.search("shadow king", limit: 12)
        let search = Double((clock.now - sStart).components.attoseconds) / 1e15
        print("VGN scale perf @\(n): catalogTitleIndex build=\(f(build))ms search=\(f(search))ms (hits=\(hits.count))")
        #expect(hits.count <= 12)
        #expect(!hits.isEmpty)
    }
}
#endif
