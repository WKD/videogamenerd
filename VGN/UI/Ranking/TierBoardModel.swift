import Observation
import SwiftUI

/// One drag/drop or keyboard override, expressed as a call to
/// `RankingStore.move(gameID:toTier:atIndex:)`. `atIndex == nil` ⇒ the unplaced
/// tail. Pure value so the index math is unit-tested with no database.
struct RankMove: Equatable, Sendable {
    var gameID: Int64
    var toTier: Int64
    var atIndex: Int?
}

/// Where a drop lands inside a tier row.
enum TierDropTarget: Equatable, Sendable {
    /// Between placed tiles at this gap index (0 = before the first tile,
    /// `placed.count` = after the last).
    case gap(Int)
    /// The dimmed unplaced tail / the row's letter block ⇒ no fine position.
    case tail
}

/// The plan for a drop: the store calls to issue, plus the board the model shows
/// immediately (optimistic) before the observation reconciles it.
struct TierDropPlan: Equatable, Sendable {
    var moves: [RankMove]
    var board: [TierBoardRow]
    var isNoOp: Bool { moves.isEmpty }
}

/// All Tier Board logic (PLAN §7, view 1). The view is a thin shell; drag index
/// math, optimistic apply + reconciliation, multi-selection moves and the
/// keyboard map all live here and are unit-tested against a fake ``RankingBackend``
/// and end-to-end on an in-memory database.
@MainActor
@Observable
final class TierBoardModel {
    // MARK: Displayed state
    private(set) var rows: [TierBoardRow] = []
    private(set) var tiers: [TierInfo] = []
    /// Played games with no tier at all — the collapsed tray at the bottom.
    private(set) var unrankedTray: [GameSummary] = []
    /// Rank-derived 1–10 scores per game (tooltip only — PLAN §7 extension).
    private(set) var scores: [Int64: DerivedScoreValue] = [:]
    private(set) var isLoading = true

    /// The selected game ids (multi-select; drags move the whole set).
    var selection: Set<Int64> = []
    /// The keyboard focus anchor (arrows / nudges act on it).
    private(set) var focusedID: Int64?

    /// Compact tile width in points (PLAN §7 — ~72–96 pt with a size control).
    var tileWidth: Double = 84
    static let minTileWidth: Double = 64
    static let maxTileWidth: Double = 120

    /// Columns per wrapped line, measured by the view; drives spatial arrow nav.
    var columns: Int = 6

    /// True while the tray is expanded.
    var trayExpanded = false

    // MARK: Seams
    private let backend: any RankingBackend
    private var actions: RankingViewActions
    private var tierByID: [Int64: TierInfo] = [:]

    // Live + reconciliation bookkeeping.
    private var liveTasks: [Task<Void, Never>] = []
    private var latestBoard: [TierBoardRow]?
    private var latestTray: [GameSummary]?
    private var inFlight = 0

    init(backend: any RankingBackend, actions: RankingViewActions = RankingViewActions()) {
        self.backend = backend
        self.actions = actions
    }

    /// Wire the shell hooks once the SwiftUI environment is available (the model
    /// is created in `init`, before the environment resolves).
    func installActions(_ actions: RankingViewActions) { self.actions = actions }

    // MARK: Lifecycle

    func start() async {
        if tiers.isEmpty { await loadTiers() }
        rows = (try? await backend.tierBoardOnce()) ?? []
        unrankedTray = (try? await backend.unrankedPlayedGames()) ?? []
        scores = (try? await backend.derivedScores()) ?? [:]
        isLoading = false
        subscribeLive()
    }

    func stop() {
        for task in liveTasks { task.cancel() }
        liveTasks.removeAll()
    }

    private func loadTiers() async {
        tiers = (try? await backend.tiers()) ?? []
        tierByID = Dictionary(uniqueKeysWithValues: tiers.map { ($0.id, $0) })
    }

    private func subscribeLive() {
        guard liveTasks.isEmpty else { return }
        liveTasks.append(Task { [backend] in
            // Treat an emission as a "something changed" signal and re-read, rather than
            // adopting its payload: an emission produced BEFORE a local move can be
            // delivered AFTER that move's reconcile, and adopting it would overwrite the
            // fresh board with a stale one (seen as a flaky test and, in the app, as a
            // tile snapping back until the next emission).
            for await board in backend.tierBoardStream() {
                self.latestBoard = board
                guard self.inFlight == 0 else { continue }
                if let fresh = try? await backend.tierBoardOnce() {
                    if self.inFlight == 0 { self.rows = fresh; self.latestBoard = fresh }
                } else {
                    self.rows = board
                }
            }
        })
        liveTasks.append(Task { [backend] in
            for await tray in backend.unrankedGamesStream() {
                self.latestTray = tray
                guard self.inFlight == 0 else { continue }
                if let fresh = try? await backend.unrankedPlayedGames() {
                    if self.inFlight == 0 { self.unrankedTray = fresh; self.latestTray = fresh }
                } else {
                    self.unrankedTray = tray
                }
            }
        })
    }

    func tier(_ id: Int64) -> TierInfo? { tierByID[id] }

    // MARK: Selection

    func select(_ id: Int64, additive: Bool = false) {
        if additive {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        focusedID = id
    }

    func isSelected(_ id: Int64) -> Bool { selection.contains(id) }

    /// The dragged set for a tile: the whole selection if the tile is part of it,
    /// otherwise just that tile (and it becomes the selection).
    func dragIDs(startingAt id: Int64) -> [Int64] {
        if selection.contains(id), selection.count > 1 {
            return orderedSelection()
        }
        selection = [id]
        focusedID = id
        return [id]
    }

    /// The current selection in board reading order (tiers top→bottom, placed
    /// then unplaced within a row).
    func orderedSelection() -> [Int64] {
        flatIDs().filter { selection.contains($0) }
    }

    private func flatIDs() -> [Int64] {
        rows.flatMap { $0.placed.map(\.id) + $0.unplaced.map(\.id) }
    }

    // MARK: Drop (drag & drop entry point)

    /// Handle a drop of `gameIDs` onto `toTier` at `target`. Applies the plan
    /// optimistically, issues the store moves, then reconciles.
    func drop(_ gameIDs: [Int64], toTier: Int64, target: TierDropTarget) async {
        let plan = Self.planDrop(board: rows, gameIDs: gameIDs, toTier: toTier, target: target)
        guard !plan.isNoOp else { return }
        await apply(plan)
        // Keep the moved games selected.
        selection = Set(gameIDs)
    }

    /// Optimistically show `plan.board`, run its moves, then adopt the observed
    /// truth (PLAN §7 — "the UI must not flicker between intermediate states").
    private func apply(_ plan: TierDropPlan) async {
        rows = plan.board
        inFlight += 1
        // A multi-move drop is one transaction / one undo step (PLAN §7 follow-up).
        if plan.moves.count > 1 {
            try? await backend.moveBatch(plan.moves)
        } else if let move = plan.moves.first {
            try? await backend.move(gameID: move.gameID, toTier: move.toTier, atIndex: move.atIndex)
        }
        inFlight -= 1
        if inFlight == 0 { await reconcile() }
    }

    /// Pull authoritative state after a batch of writes (the live stream may lag
    /// the awaited writes, so fetch once to be exact).
    private func reconcile() async {
        if let board = try? await backend.tierBoardOnce() { rows = board; latestBoard = board }
        if let tray = try? await backend.unrankedPlayedGames() { unrankedTray = tray; latestTray = tray }
        if let s = try? await backend.derivedScores() { scores = s }
    }

    /// Tooltip text for a tile (title + derived score).
    func tooltip(for game: GameSummary) -> String {
        guard let score = scores[game.id] else { return game.title }
        return "\(game.title)  ·  \(score.formatted())"
    }

    // MARK: Divider moves via the row context menu (PLAN §7 extension)

    func nextTierID(after tierID: Int64) -> Int64? {
        guard let i = tiers.firstIndex(where: { $0.id == tierID }), i + 1 < tiers.count else { return nil }
        return tiers[i + 1].id
    }

    /// "Pull up": move the first placed game of the tier below into this tier.
    func pullUpFromBelow(_ tierID: Int64) async {
        guard let lower = nextTierID(after: tierID) else { return }
        await moveDivider(upperTierID: tierID, lowerTierID: lower, by: 1)
    }

    /// "Push down": move the last placed game of this tier into the tier below.
    func pushDownToBelow(_ tierID: Int64) async {
        guard let lower = nextTierID(after: tierID) else { return }
        await moveDivider(upperTierID: tierID, lowerTierID: lower, by: -1)
    }

    private func moveDivider(upperTierID: Int64, lowerTierID: Int64, by k: Int) async {
        inFlight += 1
        _ = try? await backend.moveDivider(between: upperTierID, and: lowerTierID, by: k)
        inFlight -= 1
        if inFlight == 0 { await reconcile() }
    }

    // MARK: Pure planner (unit-tested)

    nonisolated static func planDrop(board: [TierBoardRow], gameIDs: [Int64],
                         toTier: Int64, target: TierDropTarget) -> TierDropPlan {
        let ids = orderedForBoard(board, ids: gameIDs)
        guard !ids.isEmpty, board.contains(where: { $0.tier.id == toTier }) else {
            return TierDropPlan(moves: [], board: board)
        }
        if ids.count == 1 {
            return planSingle(board: board, gameID: ids[0], toTier: toTier, target: target)
        }
        return planMulti(board: board, gameIDs: ids, toTier: toTier, target: target)
    }

    /// Reorder `ids` into board reading order so a multi-move keeps relative order.
    nonisolated private static func orderedForBoard(_ board: [TierBoardRow], ids: [Int64]) -> [Int64] {
        let flat = board.flatMap { $0.placed.map(\.id) + $0.unplaced.map(\.id) }
        let want = Set(ids)
        return flat.filter { want.contains($0) }
    }

    nonisolated private static func planSingle(board: [TierBoardRow], gameID: Int64,
                                   toTier: Int64, target: TierDropTarget) -> TierDropPlan {
        guard let loc = locate(board, gameID) else { return TierDropPlan(moves: [], board: board) }
        switch target {
        case .tail:
            // Already unplaced in the target tier ⇒ nothing to do.
            if loc.tierID == toTier, loc.section == .unplaced {
                return TierDropPlan(moves: [], board: board)
            }
            let move = RankMove(gameID: gameID, toTier: toTier, atIndex: nil)
            return TierDropPlan(moves: [move], board: applyLocally(board, move))
        case .gap(let dropGap):
            let sameTierPlaced = (loc.tierID == toTier && loc.section == .placed)
            let atIndex: Int
            if sameTierPlaced {
                let from = loc.index
                // Dropping into its own slot (either side) is a no-op.
                if dropGap == from || dropGap == from + 1 {
                    return TierDropPlan(moves: [], board: board)
                }
                // Removing the tile shifts everything after it left by one.
                atIndex = dropGap > from ? dropGap - 1 : dropGap
            } else {
                let others = board.first { $0.tier.id == toTier }?.placed.count ?? 0
                atIndex = max(0, min(dropGap, others))
            }
            let move = RankMove(gameID: gameID, toTier: toTier, atIndex: atIndex)
            return TierDropPlan(moves: [move], board: applyLocally(board, move))
        }
    }

    nonisolated private static func planMulti(board: [TierBoardRow], gameIDs: [Int64],
                                  toTier: Int64, target: TierDropTarget) -> TierDropPlan {
        switch target {
        case .tail:
            let moves = gameIDs.map { RankMove(gameID: $0, toTier: toTier, atIndex: nil) }
            var b = board
            for m in moves { b = applyLocally(b, m) }
            return TierDropPlan(moves: moves, board: b)
        case .gap(let dropGap):
            guard let targetRow = board.first(where: { $0.tier.id == toTier }) else {
                return TierDropPlan(moves: [], board: board)
            }
            let selected = Set(gameIDs)
            let displayed = targetRow.placed.map(\.id)
            let retained = displayed.filter { !selected.contains($0) }
            // dropGap is a gap in the *displayed* placed array; count retained
            // tiles before it to find where the block lands among retained.
            let clampedGap = max(0, min(dropGap, displayed.count))
            let insertAt = displayed[0..<clampedGap].filter { !selected.contains($0) }.count
            let finalOrder = Array(retained[0..<insertAt]) + gameIDs + Array(retained[insertAt...])

            // Realise `finalOrder` with left-to-right moves from the first
            // divergence (each `move(F[i], toTier, i)` settles F[0...i] at the
            // front — correct whatever the starting arrangement).
            let current = targetRow.placed.map(\.id)
            var firstDiff = 0
            while firstDiff < min(current.count, finalOrder.count),
                  current[firstDiff] == finalOrder[firstDiff] { firstDiff += 1 }
            var moves: [RankMove] = []
            for i in firstDiff..<finalOrder.count {
                moves.append(RankMove(gameID: finalOrder[i], toTier: toTier, atIndex: i))
            }
            var b = board
            for m in moves { b = applyLocally(b, m) }
            return TierDropPlan(moves: moves, board: b)
        }
    }

    // MARK: Local board application (optimistic, mirrors RankMoves semantics)

    private enum Section { case placed, unplaced }
    private struct Loc { var tierID: Int64; var section: Section; var index: Int }

    nonisolated private static func locate(_ board: [TierBoardRow], _ id: Int64) -> Loc? {
        for row in board {
            if let i = row.placed.firstIndex(where: { $0.id == id }) {
                return Loc(tierID: row.tier.id, section: .placed, index: i)
            }
            if let i = row.unplaced.firstIndex(where: { $0.id == id }) {
                return Loc(tierID: row.tier.id, section: .unplaced, index: i)
            }
        }
        return nil
    }

    nonisolated static func applyLocally(_ board: [TierBoardRow], _ move: RankMove) -> [TierBoardRow] {
        guard var summary = board.flatMap({ $0.placed + $0.unplaced }).first(where: { $0.id == move.gameID })
        else { return board }
        var result = board.map { row -> TierBoardRow in
            var r = row
            r.placed.removeAll { $0.id == move.gameID }
            r.unplaced.removeAll { $0.id == move.gameID }
            return r
        }
        guard let ri = result.firstIndex(where: { $0.tier.id == move.toTier }) else { return board }
        summary.tierID = move.toTier
        summary.tierLetter = result[ri].tier.letter
        summary.tierColorHex = result[ri].tier.colorHex
        if let atIndex = move.atIndex {
            summary.rankKey = summary.rankKey ?? 1   // becomes placed
            let clamped = max(0, min(atIndex, result[ri].placed.count))
            result[ri].placed.insert(summary, at: clamped)
        } else {
            summary.rankKey = nil
            result[ri].unplaced.append(summary)
        }
        return result
    }

    // MARK: Keyboard — re-tier, clear, nudge, undo, inspect (PLAN §7/§8)

    /// `S…F` — re-tier the selection into the new tier's unplaced tail.
    func retierSelection(letter: String) async {
        guard let tier = tiers.first(where: { $0.letter.caseInsensitiveCompare(letter) == .orderedSame })
        else { return }
        let ids = orderedSelection().isEmpty ? focusArray() : orderedSelection()
        guard !ids.isEmpty else { return }
        var moves: [RankMove] = []
        var b = rows
        for id in ids where Self.locate(b, id)?.tierID != tier.id || Self.locate(b, id)?.section == .placed {
            let m = RankMove(gameID: id, toTier: tier.id, atIndex: nil)
            moves.append(m); b = Self.applyLocally(b, m)
        }
        guard !moves.isEmpty else { return }
        // setTier keeps a game that already has the tier in place; the board move
        // path re-queues, which is what "press S on an S game" should do here.
        await apply(TierDropPlan(moves: moves, board: b))
    }

    /// `0` — clear the selection's tier entirely (leaves the board).
    func clearSelectionTier() async {
        let ids = orderedSelection().isEmpty ? focusArray() : orderedSelection()
        guard !ids.isEmpty else { return }
        var b = rows
        for id in ids {
            b = b.map { row in
                var r = row
                r.placed.removeAll { $0.id == id }
                r.unplaced.removeAll { $0.id == id }
                return r
            }
        }
        rows = b
        inFlight += 1
        for id in ids { try? await backend.clearTier(id) }
        inFlight -= 1
        selection.removeAll()
        focusedID = nil
        if inFlight == 0 { await reconcile() }
    }

    /// `⌥←` / `⌥→` — nudge the focused game one slot within its tier.
    func nudgeWithinTier(forward: Bool) async {
        guard let id = focusedID, let loc = Self.locate(rows, id), loc.section == .placed else { return }
        let target = forward ? loc.index + 1 : loc.index - 1
        guard let row = rows.first(where: { $0.tier.id == loc.tierID }),
              target >= 0, target < row.placed.count else { return }
        // Convert the target *position* to a drop gap and reuse the single planner.
        let gap = forward ? target + 1 : target
        await drop([id], toTier: loc.tierID, target: .gap(gap))
        focusedID = id
        selection = [id]
    }

    /// `⌥↑` / `⌥↓` — move the focused game to the adjacent tier's tail.
    func nudgeAcrossTier(up: Bool) async {
        guard let id = focusedID, let loc = Self.locate(rows, id),
              let tierIndex = tiers.firstIndex(where: { $0.id == loc.tierID }) else { return }
        let target = up ? tierIndex - 1 : tierIndex + 1
        guard target >= 0, target < tiers.count else { return }
        await drop([id], toTier: tiers[target].id, target: .tail)
        focusedID = id
        selection = [id]
    }

    func undo() async {
        inFlight += 1
        _ = try? await backend.undo()
        inFlight -= 1
        if inFlight == 0 { await reconcile() }
    }

    /// Context menu — "Re-place": keep the tier, re-queue for duels.
    func rePlace(_ gameID: Int64) async {
        inFlight += 1
        try? await backend.rePlace(gameID)
        inFlight -= 1
        if inFlight == 0 { await reconcile() }
    }

    /// Context menu — remove a single game from its tier entirely.
    func clearGame(_ gameID: Int64) async {
        rows = rows.map { row in
            var r = row
            r.placed.removeAll { $0.id == gameID }
            r.unplaced.removeAll { $0.id == gameID }
            return r
        }
        inFlight += 1
        try? await backend.clearTier(gameID)
        inFlight -= 1
        selection.remove(gameID)
        if focusedID == gameID { focusedID = nil }
        if inFlight == 0 { await reconcile() }
    }

    /// `↩` — open the inspector on the focused game (via the shell action).
    func inspectFocused() {
        guard let id = focusedID ?? selection.first, let inspect = actions.inspect else { return }
        inspect(id)
    }

    private func focusArray() -> [Int64] { focusedID.map { [$0] } ?? [] }

    // MARK: Placement pointers (unplaced tails / tray → Duel)

    var totalUnplaced: Int { rows.reduce(0) { $0 + $1.unplaced.count } }

    func goToDuel() { actions.goToDuel?() }

    // MARK: Spatial arrow navigation (approximate; columns fed by the view)

    /// Move focus by a direction across the wrapped rows. `columns` is the number
    /// of tiles per line the view currently shows.
    func moveFocus(_ direction: MoveCommandDirection) {
        let flat = flatIDs()
        guard !flat.isEmpty else { return }
        guard let current = focusedID, let idx = flat.firstIndex(of: current) else {
            setFocus(flat.first)
            return
        }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -max(1, columns)
        case .down: step = max(1, columns)
        @unknown default: step = 0
        }
        let next = max(0, min(flat.count - 1, idx + step))
        setFocus(flat[next])
    }

    private func setFocus(_ id: Int64?) {
        focusedID = id
        if let id { selection = [id] }
    }
}
