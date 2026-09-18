import Foundation
import GRDB

// Placement / refine / border duels (PLAN §7). Resumable — all state lives in the
// database, in the `app_state` blob under ``RankingStore/duelStateKey`` — so a
// killed-and-relaunched app continues exactly where it stopped. The active
// ``PlacementSession`` is revalidated against the current library on every load,
// because games can be added, deleted, un-played or re-tiered between launches.
//
// ## Undo horizon (⌘Z)
// Two levels, and always at least "the whole current placement session + the last
// completed action":
//  1. **Per-answer**, within the current placement session: each ⌘Z reverses one
//     duel answer, restoring the exact search interval and deleting the comparison
//     row it logged. Undoing the *completing* answer also reverses the applied key
//     (or renumber) via the captured `completionPriorStates`, dropping the game
//     back to unplaced.
//  2. **One-step**, for the last *completed* action (a finalized placement, a
//     refine swap, a border accept, a move, a re-place, a clear-tier, an
//     auto-placement): ⌘Z restores the touched games' prior `(tier, key)` and
//     deletes any comparison rows it logged. Up to ``maxUndoDepth`` deep.
//
// A placement stays per-answer-undoable until the user *answers the next duel*
// (which finalizes it into the one-step history) — merely viewing the next prompt
// does not lose the per-answer horizon.

extension RankingStore {

    // MARK: - Persisted duel state

    static let duelStateKey = "ranking.duel"
    static let maxUndoDepth = 50

    /// A game's ranking position, captured so an operation can be undone.
    struct GameRankState: Codable, Sendable, Equatable {
        var gameID: Int64
        var tier: Int64?
        var key: RankKey?
    }

    /// One reversible completed action in the one-step undo history.
    struct CompletedAction: Codable, Sendable, Equatable {
        var priorStates: [GameRankState]
        var comparisonIDs: [Int64]
        var kind: String
    }

    /// The whole persisted duel state (Codable blob in `app_state`).
    struct DuelState: Codable, Sendable, Equatable {
        /// The current placement session (in-progress, or just-completed and kept
        /// for per-answer undo until the next answer finalizes it).
        var session: PlacementSession?
        /// Comparison row ids logged for `session.answers`, parallel by index.
        var sessionLog: [Int64]
        /// Prior `(tier, key)` of the games the completing answer touched — set iff
        /// `session` is complete; used to reverse the applied placement on undo.
        var completionPriorStates: [GameRankState]?
        /// One-step undo history of completed actions (bounded).
        var history: [CompletedAction]
        /// Recently dismissed border pairs (bounded), so a dismissed border is not
        /// re-asked immediately even when it is the only refine candidate (PLAN §7).
        var dismissedBorders: [PairKey]

        init(session: PlacementSession? = nil, sessionLog: [Int64] = [],
             completionPriorStates: [GameRankState]? = nil, history: [CompletedAction] = [],
             dismissedBorders: [PairKey] = []) {
            self.session = session
            self.sessionLog = sessionLog
            self.completionPriorStates = completionPriorStates
            self.history = history
            self.dismissedBorders = dismissedBorders
        }
    }

    static let maxDismissedBorders = 32

    static func loadDuelState(_ db: Database) throws -> DuelState {
        guard let row = try AppStateRecord.fetchOne(db, key: duelStateKey) else { return DuelState() }
        return (try? JSONDecoder().decode(DuelState.self, from: Data(row.json.utf8))) ?? DuelState()
    }

    static func saveDuelState(_ state: DuelState, _ db: Database) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try AppStateRecord(key: duelStateKey, json: json, updatedAt: Date()).save(db)
    }

    static func pushHistory(_ action: CompletedAction, _ state: inout DuelState) {
        state.history.append(action)
        if state.history.count > maxUndoDepth {
            state.history.removeFirst(state.history.count - maxUndoDepth)
        }
    }

    /// Capture → apply → push one reversible completed action.
    static func applyStructural(_ mutations: [RankMutation], comparisonIDs: [Int64], kind: String,
                                _ state: inout DuelState, _ db: Database) throws {
        let prior = try captureStates(touchedIDs(mutations), db)
        try applyMutations(mutations, db)
        pushHistory(CompletedAction(priorStates: prior, comparisonIDs: comparisonIDs, kind: kind), &state)
    }

    // MARK: - Session revalidation

    /// Re-derive a safe session against the current library (opponents may have
    /// been deleted / reordered). Returns `nil` when the *placing* game itself is
    /// gone, un-played, or moved to another tier — in which case the session must
    /// be dropped and the queue re-consulted.
    ///
    /// When the tier is **unchanged** (the common case) the session is returned
    /// as-is, which crucially preserves its internal undo history —
    /// `PlacementSession.revalidated(against:)` drops that history, so it is only
    /// called when the tier's placed games actually changed underneath the session.
    static func revalidateSession(_ session: PlacementSession, snapshot: RankSnapshot,
                                  _ db: Database) throws -> PlacementSession? {
        guard let row = try Row.fetchOne(db, sql: "SELECT played, tier_id FROM games WHERE id = ?",
                                         arguments: [session.gameID]) else { return nil }
        let played: Bool = row["played"]
        let tier = row["tier_id"] as Int64?
        guard played, tier == session.tier else { return nil }
        guard let slice = snapshot.slice(for: session.tier) else { return nil }
        let currentOpponents = slice.placed.filter { $0.id != session.gameID }
        if currentOpponents == session.opponents { return session }  // unchanged → keep undo history
        return session.revalidated(against: slice)
    }

    // MARK: - What to show next

    enum Current {
        case placement(PlacementSession)   // active; `nextOpponent` non-nil
        case refine(RefinePair)
        case border(RefinePair)
        case none
    }

    /// The next unit of work: unplaced placements first, then the top-priority
    /// refine/border pair that has not been recently dismissed (PLAN §7).
    static func nextItem(_ snapshot: RankSnapshot, log: [Comparison], _ state: DuelState) -> RankQueue.Item? {
        if let first = RankQueue.placements(snapshot).first {
            return .place(game: first.game, tier: first.tier)
        }
        for pair in RefineMode.pairs(snapshot, log: log) {
            if case .border = pair.context, state.dismissedBorders.contains(PairKey(pair.upper, pair.lower)) {
                continue
            }
            return .refine(pair)
        }
        return nil
    }

    /// Resolve the current duel, draining trivial (no-opponent) placements
    /// silently and persisting a fresh session when one starts. May write.
    static func resolveCurrent(_ db: Database) throws -> Current {
        var iterations = 0
        while true {
            iterations += 1
            precondition(iterations < 1_000_000, "resolveCurrent runaway")
            var state = try loadDuelState(db)
            let snapshot = try loadSnapshot(db)

            // 1. Resume an active persisted session (highest priority).
            if let session = state.session {
                if let valid = try revalidateSession(session, snapshot: snapshot, db) {
                    if !valid.isComplete, valid.nextOpponent != nil {
                        if valid != session { state.session = valid; try saveDuelState(state, db) }
                        return .placement(valid)
                    }
                    // Complete → keep for per-answer undo, but peek the next item.
                    if valid != session { state.session = valid; try saveDuelState(state, db) }
                } else {
                    state.session = nil; state.sessionLog = []; state.completionPriorStates = nil
                    try saveDuelState(state, db)
                    continue
                }
            }

            // 2. Peek the queue.
            let log = try loadLog(db)
            guard let item = nextItem(snapshot, log: log, state) else { return .none }
            switch item {
            case let .place(game, tier):
                guard let slice = snapshot.slice(for: tier) else { return .none }
                let session = PlacementSession(placing: game, into: slice)
                if session.nextOpponent == nil {
                    // Trivial: no opponents in this tier → assign the initial key
                    // now (silent auto-placement) and advance.
                    try applyStructural(session.makeMutations() ?? [], comparisonIDs: [],
                                        kind: "autoPlace", &state, db)
                    try saveDuelState(state, db)
                    continue
                }
                // Persist as the active session unless a completed session is being
                // preserved for per-answer undo (then return a transient prompt;
                // `answer` will finalize the old session first).
                if state.session == nil {
                    state.session = session; state.sessionLog = []; state.completionPriorStates = nil
                    try saveDuelState(state, db)
                }
                return .placement(session)
            case let .refine(pair):
                if case .border = pair.context { return .border(pair) }
                return .refine(pair)
            }
        }
    }

    // MARK: - Duel API

    /// What to show next in the Duel view, or `nil` when the queue is empty.
    func currentDuel() async throws -> DuelPrompt? {
        try await dbWriter.write { db in
            switch try Self.resolveCurrent(db) {
            case let .placement(session):
                guard let opponent = session.nextOpponent else { return nil }
                return DuelPrompt(kind: .placement, candidate: session.gameID, opponent: opponent,
                                  candidateTier: session.tier, opponentTier: session.tier,
                                  comparisonsMade: session.comparisonsMade,
                                  estimatedTotal: session.estimatedTotal)
            case let .refine(pair):
                let tier = Self.withinTier(pair)
                return DuelPrompt(kind: .refine, candidate: pair.upper, opponent: pair.lower,
                                  candidateTier: tier, opponentTier: tier,
                                  comparisonsMade: 0, estimatedTotal: 0)
            case let .border(pair):
                let tiers = Self.borderTiers(pair)
                return DuelPrompt(kind: .border, candidate: pair.upper, opponent: pair.lower,
                                  candidateTier: tiers.upper, opponentTier: tiers.lower,
                                  comparisonsMade: 0, estimatedTotal: 0)
            case .none:
                return nil
            }
        }
    }

    /// Answer the current duel by naming the winning game (PLAN §7 `←`/`→`). One
    /// transaction: narrows the placement / resolves the refine, logs a comparison,
    /// and applies any resulting mutations. Persists the session after every answer.
    @discardableResult
    func answer(winner: Int64) async throws -> DuelOutcome {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            let snapshot = try Self.loadSnapshot(db)

            // Case A: continue an active, incomplete placement session.
            if let session = state.session,
               let valid = try Self.revalidateSession(session, snapshot: snapshot, db),
               !valid.isComplete, let opponent = valid.nextOpponent,
               winner == valid.gameID || winner == opponent {
                var s = valid
                if valid.answers.count != session.answers.count {
                    state.sessionLog = Array(state.sessionLog.suffix(valid.answers.count))
                }
                let candidateWon = (winner == s.gameID)
                s.answer(candidateWon ? .candidateWins : .opponentWins)
                let loser = candidateWon ? opponent : s.gameID
                let cid = try Self.insertComparison(winner: winner, loser: loser, context: "placement", db)
                state.sessionLog.append(cid)
                try Self.applyCompletionIfNeeded(&s, &state, db)
                state.session = s
                try Self.saveDuelState(state, db)
                return .placed(gameID: s.gameID, complete: s.isComplete)
            }

            // Otherwise we are answering the NEXT item: finalize / drop the session.
            if let session = state.session {
                if let valid = try Self.revalidateSession(session, snapshot: snapshot, db), valid.isComplete {
                    Self.pushHistory(CompletedAction(priorStates: state.completionPriorStates ?? [],
                                                     comparisonIDs: state.sessionLog, kind: "placement"),
                                     &state)
                }
                state.session = nil; state.sessionLog = []; state.completionPriorStates = nil
            }

            let log = try Self.loadLog(db)
            guard let item = Self.nextItem(snapshot, log: log, state) else {
                try Self.saveDuelState(state, db); return .none
            }
            switch item {
            case let .place(game, tier):
                guard let slice = snapshot.slice(for: tier) else {
                    try Self.saveDuelState(state, db); return .none
                }
                var session = PlacementSession(placing: game, into: slice)
                guard let opponent = session.nextOpponent else {
                    try Self.applyStructural(session.makeMutations() ?? [], comparisonIDs: [],
                                             kind: "autoPlace", &state, db)
                    try Self.saveDuelState(state, db)
                    return .placed(gameID: game, complete: true)
                }
                guard winner == game || winner == opponent else {
                    try Self.saveDuelState(state, db); return .none
                }
                let candidateWon = (winner == game)
                session.answer(candidateWon ? .candidateWins : .opponentWins)
                let loser = candidateWon ? opponent : game
                let cid = try Self.insertComparison(winner: winner, loser: loser, context: "placement", db)
                state.sessionLog = [cid]
                try Self.applyCompletionIfNeeded(&session, &state, db)
                state.session = session
                try Self.saveDuelState(state, db)
                return .placed(gameID: game, complete: session.isComplete)

            case let .refine(pair):
                if case .border = pair.context {
                    return try Self.resolveBorderAnswer(pair, winner: winner, snapshot: snapshot, &state, db)
                }
                return try Self.resolveRefineAnswer(pair, winner: winner, snapshot: snapshot, &state, db)
            }
        }
    }

    /// Apply the placement mutations if the session just completed, capturing prior
    /// state so the completing answer can be undone.
    private static func applyCompletionIfNeeded(_ session: inout PlacementSession,
                                                _ state: inout DuelState, _ db: Database) throws {
        if session.isComplete {
            let mutations = session.makeMutations() ?? []
            state.completionPriorStates = try captureStates(touchedIDs(mutations), db)
            try applyMutations(mutations, db)
        } else {
            state.completionPriorStates = nil
        }
    }

    private static func resolveRefineAnswer(_ pair: RefinePair, winner: Int64, snapshot: RankSnapshot,
                                            _ state: inout DuelState, _ db: Database) throws -> DuelOutcome {
        guard winner == pair.upper || winner == pair.lower else {
            try saveDuelState(state, db); return .none
        }
        let loser = winner == pair.upper ? pair.lower : pair.upper
        let cid = try insertComparison(winner: winner, loser: loser, context: "refine", db)
        switch RefineMode.resolve(pair, winner: winner, in: snapshot) {
        case let .reorder(mutations):
            let prior = try captureStates(touchedIDs(mutations), db)
            try applyMutations(mutations, db)
            pushHistory(CompletedAction(priorStates: prior, comparisonIDs: [cid], kind: "refine"), &state)
            try saveDuelState(state, db)
            return .refined(swapped: true)
        case .noChange, .suggestion:
            pushHistory(CompletedAction(priorStates: [], comparisonIDs: [cid], kind: "refineConfirm"), &state)
            try saveDuelState(state, db)
            return .refined(swapped: false)
        }
    }

    private static func resolveBorderAnswer(_ pair: RefinePair, winner: Int64, snapshot: RankSnapshot,
                                            _ state: inout DuelState, _ db: Database) throws -> DuelOutcome {
        guard winner == pair.upper || winner == pair.lower else {
            try saveDuelState(state, db); return .none
        }
        let loser = winner == pair.upper ? pair.lower : pair.upper
        // A border duel is persisted as `refine` (PLAN §4 schema), which also
        // deprioritises the pair in the refine queue = "dismissal remembered".
        let cid = try insertComparison(winner: winner, loser: loser, context: "refine", db)
        pushHistory(CompletedAction(priorStates: [], comparisonIDs: [cid], kind: "border"), &state)
        try saveDuelState(state, db)
        if case let .suggestion(suggestion) = RefineMode.resolve(pair, winner: winner, in: snapshot) {
            return .border(suggestion)
        }
        return .border(nil)
    }

    /// Accept a border suggestion: move the game into the target tier as unplaced,
    /// so a placement duel finds its exact new spot (PLAN §7 — a tier change
    /// re-queues). Undoable (⌘Z).
    func acceptBorderSuggestion(_ suggestion: BorderSuggestion) async throws {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            let mutations = RankMoves.setTierUnplaced(suggestion.game, tier: suggestion.toTier)
            try Self.applyStructural(mutations, comparisonIDs: [], kind: "borderAccept", &state, db)
            try Self.saveDuelState(state, db)
        }
    }

    /// Dismiss a border suggestion (PLAN §7): remember the pair so it is not
    /// re-asked immediately. No ranking mutation — the game stays where it is
    /// (which, together with the border comparison the duel already logged, may
    /// surface later as a dispute, by design).
    func dismissBorderSuggestion(_ suggestion: BorderSuggestion) async throws {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            // The border pair is (bottom of the higher tier, top of the lower); the
            // suggestion carries the moved game, so recover the game it beat from the
            // current snapshot to remember the exact pair.
            let key = PairKey(suggestion.game, try Self.borderOpponent(suggestion, db))
            state.dismissedBorders.append(key)
            if state.dismissedBorders.count > Self.maxDismissedBorders {
                state.dismissedBorders.removeFirst(state.dismissedBorders.count - Self.maxDismissedBorders)
            }
            try Self.saveDuelState(state, db)
        }
    }

    /// The game a promoted border game beat: the bottom of the higher tier (for a
    /// promote) or the top of the lower tier (for a demote). Recovered from the
    /// current snapshot; falls back to the game itself if the border is gone.
    private static func borderOpponent(_ suggestion: BorderSuggestion, _ db: Database) throws -> Int64 {
        let snapshot = try loadSnapshot(db)
        switch suggestion.kind {
        case .promote:
            return snapshot.slice(for: suggestion.toTier)?.placed.last?.id ?? suggestion.game
        case .demote:
            return snapshot.slice(for: suggestion.toTier)?.placed.first?.id ?? suggestion.game
        }
    }

    /// Defer the current placement game (PLAN §7 `↓`): re-queue it to the back of
    /// its tier. A no-op on a refine/border prompt (those are answered, not
    /// deferred).
    func skip() async throws {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)
            let snapshot = try Self.loadSnapshot(db)
            let now = Date()

            if let session = state.session,
               let valid = try Self.revalidateSession(session, snapshot: snapshot, db), !valid.isComplete {
                try db.execute(sql: "UPDATE games SET updated_at = ? WHERE id = ?", arguments: [now, valid.gameID])
                state.session = nil; state.sessionLog = []; state.completionPriorStates = nil
                try Self.saveDuelState(state, db)
                return
            }

            if let session = state.session {
                if let valid = try Self.revalidateSession(session, snapshot: snapshot, db), valid.isComplete {
                    Self.pushHistory(CompletedAction(priorStates: state.completionPriorStates ?? [],
                                                     comparisonIDs: state.sessionLog, kind: "placement"), &state)
                }
                state.session = nil; state.sessionLog = []; state.completionPriorStates = nil
            }
            let log = try Self.loadLog(db)
            if case let .place(game, _)? = Self.nextItem(snapshot, log: log, state) {
                try db.execute(sql: "UPDATE games SET updated_at = ? WHERE id = ?", arguments: [now, game])
            }
            try Self.saveDuelState(state, db)
        }
    }

    /// Undo (⌘Z). See the file header for the horizon. Returns false when there is
    /// nothing left to undo.
    @discardableResult
    func undo() async throws -> Bool {
        try await dbWriter.write { db in
            var state = try Self.loadDuelState(db)

            // 1. Per-answer undo of the current session.
            if var session = state.session, !session.answers.isEmpty {
                if session.isComplete, let prior = state.completionPriorStates {
                    try Self.restoreStates(prior, db)
                    state.completionPriorStates = nil
                }
                session.undo()
                if let cid = state.sessionLog.popLast() { try Self.deleteComparison(cid, db) }
                state.session = session
                try Self.saveDuelState(state, db)
                return true
            }

            // 2. One-step undo of the last completed action.
            if let action = state.history.popLast() {
                try Self.restoreStates(action.priorStates, db)
                for cid in action.comparisonIDs { try Self.deleteComparison(cid, db) }
                try Self.saveDuelState(state, db)
                return true
            }
            return false
        }
    }

    // MARK: - Pair helpers

    static func withinTier(_ pair: RefinePair) -> Int64 {
        if case let .withinTier(tier) = pair.context { return tier }
        return 0
    }

    static func borderTiers(_ pair: RefinePair) -> (upper: Int64, lower: Int64) {
        if case let .border(upper, lower) = pair.context { return (upper, lower) }
        return (0, 0)
    }
}
