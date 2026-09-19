import Foundation

/// A Delicious Library 2 database as a ``LibraryImporter`` (PLAN §5.5) — the first
/// **file** importer. It reads the chosen `.deliciouslibrary2` file read-only, maps
/// every VideoGame row to a staging row through ``DeliciousMapping``, and reports
/// progress. No network, no cache, no budget/pacer; it still runs through the shared
/// ``ImportSyncCoordinator`` so staging / matching / commit behave identically to GOG.
///
/// `authenticate()` is a no-op (a file needs no account). The summary reads
/// "N games read from Delicious Library" via ``ImportFetchResult/fromFile``.
struct DeliciousImporter: LibraryImporter, Sendable {
    let reader: DeliciousLibraryReader
    var platformPolicy: ImportPlatformPolicy

    init(reader: DeliciousLibraryReader, platformPolicy: ImportPlatformPolicy = .macWhenAvailable) {
        self.reader = reader
        self.platformPolicy = platformPolicy
    }

    let source = ImportSourceID.delicious

    /// One "data set": the file itself. No request cost — a file read never hits the
    /// network, so Force-refresh / budget UI shows nothing to spend.
    var dataSets: [ImportDataSet] {
        [ImportDataSet(id: "delicious.file", title: "Delicious Library", estimatedRequests: 0)]
    }

    /// A file needs no session.
    func authenticate() async throws {}

    func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
        progress(ImportProgress(phase: .fetching, detail: "Reading Delicious Library"))
        // Reading is synchronous SQLite work; hop off the calling actor.
        let policy = platformPolicy
        let reader = self.reader
        let games = try await Task.detached(priority: .userInitiated) {
            try reader.readGames()
        }.value

        progress(ImportProgress(phase: .staging, detail: "Mapping \(games.count) games"))
        let rows = DeliciousMapping.stagingRows(for: games, policy: policy)
        return ImportFetchResult(rows: rows, fromFile: games.count)
    }
}
