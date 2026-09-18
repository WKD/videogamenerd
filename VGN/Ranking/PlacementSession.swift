import Foundation

/// A resumable binary-insertion duel session that places one game into one
/// tier's ordered list in ⌈log₂(n+1)⌉ comparisons.
///
/// The session is a pure value: it holds a *snapshot* of the tier taken when it
/// began, the current search interval, and a full answer history for undo. It
/// performs no I/O and, on completion, hands back `[RankMutation]` for the DB
/// lane to apply.
///
/// **Ordering convention.** `opponents` is ordered best→worst (index 0 is rank #1
/// within the tier). "Candidate wins" means the placed game is *better* than the
/// opponent, so it sorts *above* it. Insertion index `lo` is where the game lands
/// in that ordering.
///
/// **Precondition.** The game already carries `tier` (it sits in the tier's
/// unplaced tail — that is what queues it). The session therefore only ever needs
/// to assign a key or renumber the tier; it never changes tier membership.
///
/// The state is `Codable` so a session survives relaunch, and `revalidated(against:)`
/// recovers safely if the tier changed underneath it.
struct PlacementSession: Codable, Sendable, Equatable {

    /// The game being placed.
    let gameID: GameID
    /// The tier it is being placed into.
    let tier: TierID
    /// The tier's sort value (carried for convenience / border logic).
    let tierSort: Int

    /// Snapshot of the tier's placed items (best→worst) at session start, minus
    /// the game being placed.
    private(set) var opponents: [RankedItem]

    /// Current binary-search interval [lo, hi]; the game will be inserted at some
    /// index in this range. Complete when `lo == hi`.
    private(set) var lo: Int
    private(set) var hi: Int

    /// Bounds before each answer, for `undo`.
    private(set) var history: [Bounds]

    /// Resolved comparisons this session, in order.
    private(set) var answers: [Answer]

    /// Set when the user defers this game (`↓`). The queue moves on; no mutation.
    private(set) var skipped: Bool

    struct Bounds: Codable, Sendable, Equatable { var lo: Int; var hi: Int }
    struct Answer: Codable, Sendable, Equatable {
        var opponent: GameID
        /// True if the candidate (placed game) won this duel.
        var candidateWon: Bool
    }

    enum Result: Sendable, Equatable {
        case candidateWins
        case opponentWins
    }

    // MARK: - Lifecycle

    init(placing gameID: GameID, into slice: TierSlice) {
        self.gameID = gameID
        self.tier = slice.tier
        self.tierSort = slice.sort
        self.opponents = slice.placed.filter { $0.id != gameID }
        self.lo = 0
        self.hi = opponents.count
        self.history = []
        self.answers = []
        self.skipped = false
    }

    // MARK: - Queries

    var isComplete: Bool { lo >= hi }

    /// Insertion index once complete (0…opponents.count).
    var insertionIndex: Int { lo }

    /// The opponent to duel next, or `nil` when complete/skipped.
    var nextOpponent: GameID? {
        guard !skipped, !isComplete else { return nil }
        return opponents[currentMid].id
    }

    private var currentMid: Int { lo + (hi - lo) / 2 }

    /// Comparisons answered so far.
    var comparisonsMade: Int { answers.count }

    /// Upper bound on the number of comparisons for the FULL placement (used for
    /// the "3 of ~6" progress readout).
    var estimatedTotal: Int {
        Self.ceilLog2(opponents.count + 1)
    }

    /// Comparisons still needed from the current interval.
    var comparisonsRemaining: Int {
        Self.ceilLog2(hi - lo + 1)
    }

    // MARK: - Actions

    /// Record an answer and narrow the interval. No-op if complete/skipped.
    mutating func answer(_ result: Result) {
        guard !skipped, !isComplete else { return }
        let mid = currentMid
        history.append(Bounds(lo: lo, hi: hi))
        let candidateWon = (result == .candidateWins)
        answers.append(Answer(opponent: opponents[mid].id, candidateWon: candidateWon))
        if candidateWon {
            hi = mid          // candidate sorts at/above mid
        } else {
            lo = mid + 1      // candidate sorts below mid
        }
    }

    /// Undo the last answer, restoring the exact prior interval. Returns false if
    /// there is nothing to undo.
    @discardableResult
    mutating func undo() -> Bool {
        guard let prior = history.popLast() else { return false }
        lo = prior.lo
        hi = prior.hi
        if !answers.isEmpty { answers.removeLast() }
        return true
    }

    /// Defer this game — the queue advances and the game is re-queued later. No
    /// mutation is produced.
    mutating func skip() {
        skipped = true
    }

    // MARK: - Completion

    /// The mutations that place the game, or `nil` if the session is not yet
    /// complete (or was skipped).
    func makeMutations() -> [RankMutation]? {
        guard !skipped, isComplete else { return nil }
        let keys = opponents.map(\.key)
        switch RankKeySpace.placement(inserting: lo, into: keys) {
        case .key(let k):
            return [.setKey(id: gameID, key: k)]
        case .renumber(let newKeys):
            var ids = opponents.map(\.id)
            ids.insert(gameID, at: lo)
            precondition(ids.count == newKeys.count)
            let items = zip(ids, newKeys).map { RankedItem(id: $0.0, key: $0.1) }
            return [.renumber(tier: tier, items: items)]
        }
    }

    /// The `Comparison` records this session produced (for the duel log). The DB
    /// lane stamps the real dates; `date` here is left 0 and should be overwritten.
    func comparisons(context: Comparison.Context = .placement, date: Double = 0) -> [Comparison] {
        answers.map { a in
            a.candidateWon
                ? Comparison(winner: gameID, loser: a.opponent, date: date, context: context)
                : Comparison(winner: a.opponent, loser: gameID, date: date, context: context)
        }
    }

    // MARK: - Resume / revalidation

    /// Re-derive a safe session against a possibly-changed tier snapshot (opponents
    /// deleted, moved, or reordered while the session was persisted).
    ///
    /// Kept answers are treated as facts ("candidate above/below opponent X"). The
    /// new interval is the intersection of all still-valid facts. If the facts have
    /// become contradictory (someone reordered the tier), the session restarts its
    /// search cleanly rather than misplacing the game. History is dropped (undo does
    /// not cross a resume). The game is never lost and never crashes.
    func revalidated(against slice: TierSlice) -> PlacementSession {
        var s = self
        let newOpponents = slice.placed.filter { $0.id != gameID }
        s.opponents = newOpponents
        s.history = []

        var index: [GameID: Int] = [:]
        for (i, item) in newOpponents.enumerated() { index[item.id] = i }

        var lo = 0
        var hi = newOpponents.count
        var kept: [Answer] = []
        var contradictory = false
        for a in answers {
            guard let j = index[a.opponent] else { continue } // opponent gone → drop fact
            if a.candidateWon {
                hi = Swift.min(hi, j)      // candidate above opponent j
            } else {
                lo = Swift.max(lo, j + 1)  // candidate below opponent j
            }
            kept.append(a)
            if lo > hi { contradictory = true; break }
        }

        if contradictory {
            s.answers = []
            s.setBounds(lo: 0, hi: newOpponents.count)
        } else {
            s.answers = kept
            s.setBounds(lo: lo, hi: hi)
        }
        return s
    }

    // MARK: - Private mutators (keep stored props private(set))

    private mutating func setBounds(lo: Int, hi: Int) {
        self.lo = lo
        self.hi = hi
    }

    // MARK: - Helpers

    /// ⌈log₂(n)⌉ for n ≥ 1; 0 for n ≤ 1.
    static func ceilLog2(_ n: Int) -> Int {
        guard n > 1 else { return 0 }
        var v = n - 1
        var bits = 0
        while v > 0 { v >>= 1; bits += 1 }
        return bits
    }
}
