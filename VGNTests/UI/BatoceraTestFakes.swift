import Foundation
@testable import VGN

/// A recording fake ``BatoceraBackend`` for the Settings model tests (no `/Volumes`, no DB).
final class FakeBatoceraBackend: BatoceraBackend, @unchecked Sendable {
    nonisolated let isLive: Bool
    private let lock = NSLock()
    private var _summary: BatoceraSyncSummary
    private var _status: BatoceraCatalogStatus
    private var _calls: [SyncCall] = []

    struct SyncCall: Sendable, Equatable { var force: Bool; var skip: Set<String> }

    init(isLive: Bool = true, summary: BatoceraSyncSummary = BatoceraSyncSummary(),
         status: BatoceraCatalogStatus = .empty) {
        self.isLive = isLive
        self._summary = summary
        self._status = status
    }

    var calls: [SyncCall] { lock.withLock { _calls } }
    func setSummary(_ s: BatoceraSyncSummary) { lock.withLock { _summary = s } }

    func sync(root: URL, force: Bool, skip: Set<String>,
              progress: @Sendable @escaping (BatoceraSyncProgress) -> Void) async -> BatoceraSyncSummary {
        lock.withLock { _calls.append(SyncCall(force: force, skip: skip)) }
        return lock.withLock { _summary }
    }

    func status() async -> BatoceraCatalogStatus { lock.withLock { _status } }
}

/// A fake ``DiscoverBackend`` for the Discover model tests (no DB).
final class FakeDiscoverBackend: DiscoverBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _ranked: [RankedGame]
    private var _pool: [RomCatalogEntry]
    private var _played: Set<String>
    private var _notInterested: [Int64] = []

    init(ranked: [RankedGame] = [], pool: [RomCatalogEntry] = [], played: Set<String> = []) {
        self._ranked = ranked
        self._pool = pool
        self._played = played
    }

    var notInterestedCalls: [Int64] { lock.withLock { _notInterested } }
    func setPool(_ p: [RomCatalogEntry]) { lock.withLock { _pool = p } }

    func rankedGames() async throws -> [RankedGame] { lock.withLock { _ranked } }
    func pool(limit: Int) async throws -> [RomCatalogEntry] { lock.withLock { Array(_pool.prefix(limit)) } }
    func playedSystems() async throws -> Set<String> { lock.withLock { _played } }
    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo] {
        Dictionary(uniqueKeysWithValues: Set(ids).map { ($0, ExemplarInfo(title: "Game \($0)", tierLetter: "S")) })
    }
    func setNotInterested(catalogID: Int64) async throws {
        lock.withLock { _notInterested.append(catalogID) }
    }
}

/// Poll an async condition on the main actor with a hard timeout (for the models' background
/// tasks) — no wall-clock assertion, just a bounded wait so a stuck test fails instead of hangs.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock().now + timeout
    while !condition() && ContinuousClock().now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
