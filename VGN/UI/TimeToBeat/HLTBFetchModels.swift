import Foundation

/// A game the bulk run could not match confidently — offered for a one-by-one pick
/// after the pass (PLAN §5.3).
struct HLTBAmbiguousGame: Sendable, Hashable, Identifiable {
    var gameID: Int64
    var title: String
    var year: Int?
    var candidates: [HLTBCandidate]
    var id: Int64 { gameID }
}

/// A single-game pick request — the inspector's "Fetch from HowLongToBeat" produced
/// several plausible matches, so the user chooses one (PLAN §5.3).
struct HLTBPickerRequest: Identifiable, Sendable {
    let id = UUID()
    var gameID: Int64
    var title: String
    var year: Int?
    var candidates: [HLTBCandidate]
}

/// The bulk "Fetch Missing Time Estimates…" run (PLAN §5.3): serial, progress + Cancel,
/// a live summary, an ambiguous list to resolve one-by-one afterwards, and a hard stop
/// on the first unexpected response — "VGN stopped and made no further requests."
///
/// `@MainActor @Observable`. Everything already cached is served without requests; a
/// re-run only queries what is still missing and not negatively cached (the search
/// client's DB cache does that transparently). Nothing here is written from a `body`.
@MainActor
@Observable
final class HLTBBulkFetchModel {
    enum Phase: Sendable, Equatable { case running, finished, stopped }

    let sourceLabel = "HowLongToBeat"

    private let store: LibraryStore
    private let makeSearch: @Sendable () -> any HLTBSearching

    private(set) var phase: Phase = .running
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var currentTitle = ""
    private(set) var filled = 0
    private(set) var notFound = 0
    private(set) var ambiguous: [HLTBAmbiguousGame] = []
    private(set) var stoppedReason: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: LibraryStore, makeSearch: @escaping @Sendable () -> any HLTBSearching) {
        self.store = store
        self.makeSearch = makeSearch
    }

    /// Begin the run over `gameIDs` (already the resolved scope).
    func start(gameIDs: [Int64]) {
        total = gameIDs.count
        phase = gameIDs.isEmpty ? .finished : .running
        guard !gameIDs.isEmpty else { return }
        let search = makeSearch()
        task = Task { [weak self] in await self?.run(gameIDs: gameIDs, search: search) }
    }

    private func run(gameIDs: [Int64], search: any HLTBSearching) async {
        let facts = (try? await store.timeToBeatFacts(gameIDs: gameIDs)) ?? [:]
        for id in gameIDs {
            if Task.isCancelled {
                phase = .stopped; stoppedReason = "Cancelled."
                return
            }
            guard let f = facts[id] else { completed += 1; continue }
            currentTitle = f.title
            do {
                let candidates = try await search.search(title: f.title)
                switch HLTBMatcher.match(title: f.title, year: f.year, candidates: candidates) {
                case .confident(let candidate):
                    let result = try? await store.applyHLTBTimes(gameID: id, candidate: candidate)
                    if result?.didWrite == true { filled += 1 } else { notFound += 1 }
                case .ambiguous(let list):
                    ambiguous.append(HLTBAmbiguousGame(gameID: id, title: f.title, year: f.year, candidates: list))
                case .notFound:
                    notFound += 1
                }
            } catch is CancellationError {
                phase = .stopped
                stoppedReason = "Cancelled."
                return
            } catch let error as ImportError {
                phase = .stopped
                stoppedReason = Self.reason(from: error)
                return
            } catch {
                phase = .stopped
                stoppedReason = "the request failed"
                return
            }
            completed += 1
        }
        phase = .finished
    }

    /// Cancel the run (finishes the item in flight, then stops).
    func cancel() { task?.cancel() }

    /// Resolve one ambiguous game with the user's chosen candidate.
    func pick(gameID: Int64, candidate: HLTBCandidate) {
        guard ambiguous.contains(where: { $0.gameID == gameID }) else { return }
        ambiguous.removeAll { $0.gameID == gameID }
        let store = self.store
        Task { [weak self] in
            let result = try? await store.applyHLTBTimes(gameID: gameID, candidate: candidate)
            if result?.didWrite == true { self?.filled += 1 } else { self?.notFound += 1 }
        }
    }

    /// Drop an ambiguous game without filling it.
    func skip(gameID: Int64) { ambiguous.removeAll { $0.gameID == gameID } }

    var isRunning: Bool { phase == .running }

    /// "12 filled · 4 not found · 3 ambiguous · stopped: …".
    var summaryLine: String {
        var parts = "\(filled) filled · \(notFound) not found · \(ambiguous.count) ambiguous"
        if let reason = stoppedReason { parts += " · stopped: \(reason)" }
        return parts
    }

    /// The reassurance line shown when a run stopped on a reject (PLAN §5.3).
    var stoppedNote: String? {
        phase == .stopped && stoppedReason != "Cancelled."
            ? "VGN stopped and made no further requests."
            : nil
    }

    static func reason(from error: ImportError) -> String {
        if case .rejected(let reject) = error { return reject.reason.message }
        if case .budgetExceeded = error { return "the per-run request budget was reached" }
        return "an unexpected response"
    }
}
