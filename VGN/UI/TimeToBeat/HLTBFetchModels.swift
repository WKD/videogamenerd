import Foundation

/// Whether a HowLongToBeat run **fills gaps** (only empty `ttb_*` fields, PLAN §5.3
/// "Fetch Missing Time Estimates…") or **replaces** all three times when HLTB has the
/// game (PLAN §5.3 "Refresh Time Estimates from HowLongToBeat…", the suspicious-estimate
/// repair). One code path, two write methods — the client, pacing, cap, matcher and
/// stop-on-first-unexpected-response are shared.
enum HLTBWriteMode: Sendable, Equatable {
    case fillGaps
    case replace
}

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
    /// Whether accepting the pick fills gaps or replaces the three times.
    var mode: HLTBWriteMode = .fillGaps
}

/// The bulk "Fetch Missing Time Estimates…" / "Refresh Time Estimates…" run (PLAN §5.3):
/// serial, progress + Cancel, a live summary, an ambiguous list to resolve one-by-one
/// afterwards, and a hard stop on the first unexpected response — "VGN stopped and made
/// no further requests." In `.replace` mode it first asks for confirmation (the count +
/// "values will be replaced") and every replaced game's previous times are collected so
/// the caller can register **one** Undo step for the whole batch.
///
/// `@MainActor @Observable`. Everything already cached is served without requests; a
/// re-run only queries what is still missing and not negatively cached (the search
/// client's DB cache does that transparently). Nothing here is written from a `body`.
@MainActor
@Observable
final class HLTBBulkFetchModel {
    enum Phase: Sendable, Equatable { case confirm, running, finished, stopped }

    let sourceLabel = "HowLongToBeat"
    let mode: HLTBWriteMode

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
    /// Previous times of every game whose estimates were replaced this run (D4 batch Undo).
    private(set) var replacedSnapshots: [Int64: HLTBTimeSnapshot] = [:]

    /// Called once when a `.replace` run ends (finished or stopped), with the snapshots
    /// gathered so far, so the caller can register a single Undo step and a banner.
    var onReplaceFinished: (@MainActor ([Int64: HLTBTimeSnapshot]) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingIDs: [Int64] = []

    init(store: LibraryStore, makeSearch: @escaping @Sendable () -> any HLTBSearching,
         mode: HLTBWriteMode = .fillGaps) {
        self.store = store
        self.makeSearch = makeSearch
        self.mode = mode
    }

    /// Begin the run over `gameIDs` (already the resolved scope). In `.replace` mode this
    /// only stages the run and shows the confirmation; ``confirmAndRun()`` starts it.
    func start(gameIDs: [Int64]) {
        total = gameIDs.count
        pendingIDs = gameIDs
        if mode == .replace {
            phase = gameIDs.isEmpty ? .finished : .confirm
            return
        }
        beginRun()
    }

    /// Confirm a staged `.replace` run (the sheet's "Replace" button).
    func confirmAndRun() {
        guard phase == .confirm else { return }
        beginRun()
    }

    private func beginRun() {
        let gameIDs = pendingIDs
        phase = gameIDs.isEmpty ? .finished : .running
        guard !gameIDs.isEmpty else { return }
        let search = makeSearch()
        task = Task { [weak self] in await self?.run(gameIDs: gameIDs, search: search) }
    }

    private func run(gameIDs: [Int64], search: any HLTBSearching) async {
        let facts = (try? await store.timeToBeatFacts(gameIDs: gameIDs)) ?? [:]
        for id in gameIDs {
            if Task.isCancelled {
                finish(.stopped, reason: "Cancelled.")
                return
            }
            guard let f = facts[id] else { completed += 1; continue }
            currentTitle = f.title
            do {
                let candidates = try await search.search(title: f.title)
                switch HLTBMatcher.match(title: f.title, year: f.year, candidates: candidates) {
                case .confident(let candidate):
                    await apply(gameID: id, candidate: candidate)
                case .ambiguous(let list):
                    ambiguous.append(HLTBAmbiguousGame(gameID: id, title: f.title, year: f.year, candidates: list))
                case .notFound:
                    notFound += 1
                }
            } catch is CancellationError {
                finish(.stopped, reason: "Cancelled.")
                return
            } catch let error as ImportError {
                finish(.stopped, reason: Self.reason(from: error))
                return
            } catch {
                finish(.stopped, reason: "the request failed")
                return
            }
            completed += 1
        }
        finish(.finished, reason: nil)
    }

    /// Write one game's estimates in the run's mode, counting the result and (for replace)
    /// collecting its previous times for the batch Undo.
    private func apply(gameID: Int64, candidate: HLTBCandidate) async {
        switch mode {
        case .fillGaps:
            let result = try? await store.applyHLTBTimes(gameID: gameID, candidate: candidate)
            if result?.didWrite == true { filled += 1 } else { notFound += 1 }
        case .replace:
            let result = try? await store.replaceHLTBTimes(gameID: gameID, candidate: candidate)
            if let result, result.didWrite {
                filled += 1
                if replacedSnapshots[gameID] == nil { replacedSnapshots[gameID] = result.previous }
            } else {
                // HLTB did not know the game — it stays flagged.
                notFound += 1
            }
        }
    }

    private func finish(_ phase: Phase, reason: String?) {
        self.phase = phase
        self.stoppedReason = reason
        if mode == .replace { onReplaceFinished?(replacedSnapshots) }
    }

    /// Cancel the run (finishes the item in flight, then stops).
    func cancel() { task?.cancel() }

    /// Resolve one ambiguous game with the user's chosen candidate.
    func pick(gameID: Int64, candidate: HLTBCandidate) {
        guard ambiguous.contains(where: { $0.gameID == gameID }) else { return }
        ambiguous.removeAll { $0.gameID == gameID }
        Task { [weak self] in await self?.apply(gameID: gameID, candidate: candidate) }
    }

    /// Drop an ambiguous game without filling it.
    func skip(gameID: Int64) { ambiguous.removeAll { $0.gameID == gameID } }

    var isRunning: Bool { phase == .running }
    var needsConfirmation: Bool { phase == .confirm }

    /// The confirmation prompt for a `.replace` run (PLAN §5.3, D4).
    var confirmationMessage: String {
        "^[\(total) game](inflect: true) will have their rushed / main / completionist times "
            + "replaced with HowLongToBeat's, where it has the game. Existing estimates are overwritten."
    }

    /// The sheet title, per mode.
    var sheetTitle: String {
        mode == .replace ? "Refresh Time Estimates" : "Fetch Missing Time Estimates"
    }

    /// "12 filled · 4 not found · 3 ambiguous · stopped: …" ("replaced" in replace mode).
    var summaryLine: String {
        let verb = mode == .replace ? "replaced" : "filled"
        var parts = "\(filled) \(verb) · \(notFound) not found · \(ambiguous.count) ambiguous"
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
