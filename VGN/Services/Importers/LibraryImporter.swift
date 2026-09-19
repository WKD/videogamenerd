import Foundation

/// The one protocol every library importer implements (PLAN §5.5 / §14.4): sign in,
/// fetch cache-first, and emit generic ``ImportStagingRow`` values for the shared
/// review sheet. GOG is the first implementation; PSN (§13) is the second. The
/// coordinator (``ImportSyncCoordinator``) drives any conformer identically.
protocol LibraryImporter: Sendable {
    /// Stable source id (`ImportSourceID.gog`, `.psn`) for the staging + cache tables.
    var source: String { get }

    /// The data sets this importer fetches, with their cold-fetch request cost — the
    /// Force-refresh confirmation shows "this will cost N requests" (PLAN §14.2).
    var dataSets: [ImportDataSet] { get }

    /// Ensure a valid session/token exists, refreshing if needed. Throws
    /// ``ImportError/notAuthenticated`` when the user must sign in.
    func authenticate() async throws

    /// Fetch everything (cache-first, budgeted, paced, validated) and return the
    /// staging rows. Reports coarse progress through `progress`. On any bogus response
    /// it throws ``ImportError/rejected(_:)`` — it never retries or tries a variant
    /// (PLAN §14.5).
    func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult
}

/// The outcome of a ``LibraryImporter/fetch(progress:)``: the staging rows plus the
/// cache/network accounting the summary line needs (PLAN §14.2).
struct ImportFetchResult: Sendable, Equatable {
    var rows: [ImportStagingRow]
    var fromCache: Int
    var fromNetwork: Int
    var budgetUsed: Int
    /// Product ids seen on the library pages that were not in the owned-id list
    /// (PLAN §14.2 — reported, not fatal). Carried into ``ImportSyncSummary/ownedGap``.
    var ownedGap: Int

    init(rows: [ImportStagingRow], fromCache: Int = 0, fromNetwork: Int = 0,
         budgetUsed: Int = 0, ownedGap: Int = 0) {
        self.rows = rows
        self.fromCache = fromCache
        self.fromNetwork = fromNetwork
        self.budgetUsed = budgetUsed
        self.ownedGap = ownedGap
    }
}
