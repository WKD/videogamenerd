import Observation
import SwiftUI

/// Podium weight of a row (PLAN §7 — top 3 large, 4–10 medium, then compact).
enum PodiumBucket: Sendable, Equatable {
    case top3
    case top10
    case compact
    case unplaced
}

/// One row of The Top prepared for display.
struct TopGameRow: Identifiable, Sendable, Equatable {
    var row: TopRow
    var bucket: PodiumBucket
    /// The prominent number: derived position under a filter, else global.
    var displayRank: Int?
    /// The secondary "#41 overall" shown only when a filter narrows the list.
    var overallRank: Int?
    var tier: TierInfo?
    /// Index within the tier's placed games (nil for unplaced) — reorder target.
    var tierIndex: Int?
    var score: DerivedScoreValue?

    var id: Int64 { row.id }
    var isPlaced: Bool { row.isPlaced }
}

/// An inline tier divider (PLAN §7 — coloured rule + letter + count).
struct TopDivider: Identifiable, Sendable, Equatable {
    var tier: TierInfo
    var placedCount: Int
    var unplacedCount: Int
    /// The tier immediately above this one in the chart, if any (for divider drag).
    var upperTierID: Int64?
    var id: Int64 { tier.id }
}

/// A line item in The Top: either a divider or a game row.
enum TopDisplayItem: Identifiable, Sendable, Equatable {
    case divider(TopDivider)
    case game(TopGameRow)

    var id: String {
        switch self {
        case .divider(let d): return "d\(d.id)"
        case .game(let g): return "g\(g.id)"
        }
    }
}

/// All The Top logic (PLAN §7, view 2). Numbered chart with inline tier dividers,
/// podium buckets, filter-aware derived vs global numbering, drag reorder (only
/// when unfiltered), keyboard nudges and CSV export. The view is a thin shell.
@MainActor
@Observable
final class TheTopModel {
    private(set) var rows: [TopRow] = []
    private(set) var tiers: [TierInfo] = []
    private(set) var scores: [Int64: DerivedScoreValue] = [:]
    private(set) var isLoading = true
    private(set) var focusedID: Int64?

    /// The active filter (mirrors the library's, or an in-view default).
    private(set) var filter: LibraryFilter

    private let backend: any RankingBackend
    private var actions: RankingViewActions
    private var tierByID: [Int64: TierInfo] = [:]
    private var liveTask: Task<Void, Never>?
    private var latestRows: [TopRow]?
    private var inFlight = 0

    init(backend: any RankingBackend, filter: LibraryFilter = LibraryFilter(scope: .all),
         actions: RankingViewActions = RankingViewActions()) {
        self.backend = backend
        self.filter = filter
        self.actions = actions
    }

    func installActions(_ actions: RankingViewActions) { self.actions = actions }

    // MARK: Lifecycle

    func start() async {
        if tiers.isEmpty {
            tiers = (try? await backend.tiers()) ?? []
            tierByID = Dictionary(uniqueKeysWithValues: tiers.map { ($0.id, $0) })
        }
        await reload()
        subscribeLive()
    }

    func stop() { liveTask?.cancel(); liveTask = nil }

    /// Adopt a new filter (e.g. the library's changed) and re-subscribe.
    func setFilter(_ new: LibraryFilter) {
        guard new != filter else { return }
        filter = new
        focusedID = nil
        liveTask?.cancel(); liveTask = nil
        Task { await reload(); subscribeLive() }
    }

    private func reload() async {
        rows = (try? await backend.theTopOnce(filter: filter)) ?? []
        scores = (try? await backend.derivedScores()) ?? [:]
        isLoading = false
    }

    private func subscribeLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [backend, filter] in
            // An emission is a "something changed" signal: re-read rather than adopt its
            // payload, which may predate a local move whose reconcile already ran (same
            // stale-overwrite race as the Tier Board).
            for await value in backend.theTopStream(filter: filter) {
                self.latestRows = value
                guard self.inFlight == 0 else { continue }
                let fresh = (try? await backend.theTopOnce(filter: filter)) ?? value
                guard self.inFlight == 0 else { continue }
                self.rows = fresh
                self.latestRows = fresh
                self.scores = (try? await backend.derivedScores()) ?? self.scores
            }
        }
    }

    func tier(_ id: Int64) -> TierInfo? { tierByID[id] }

    // MARK: Filter presentation

    /// True when the chart is narrowed (so numbering is derived and drag is off).
    var filterActive: Bool { filter.hasActiveFacets || filter.scope != .all }

    /// Chips summary, e.g. "Top · PS2 · 1990s" (PLAN §7).
    var filterChips: [String] {
        var chips = ["Top"]
        if let platform = filter.platform { chips.append(PlatformLabels.short(platform)) }
        if case .platform(let slug) = filter.scope { chips.append(PlatformLabels.short(slug)) }
        switch filter.scope {
        case .owned: chips.append("Owned")
        case .played: chips.append("Played")
        case .backlog: chips.append("Backlog")
        case .unranked: chips.append("Unranked")
        default: break
        }
        for decade in filter.decades.sorted() { chips.append("\(decade)s") }
        for genre in filter.genres.sorted() { chips.append(genre) }
        if !filter.searchText.isEmpty { chips.append("“\(filter.searchText)”") }
        return chips
    }

    // MARK: Display items (dividers + podium buckets)

    var items: [TopDisplayItem] { Self.buildItems(rows: rows, tiers: tiers, scores: scores,
                                                   filterActive: filterActive) }

    /// Placed / unplaced counts per tier over the *current* (possibly filtered)
    /// chart — the distribution strip above the list.
    var distribution: [TopDivider] {
        Self.dividers(rows: rows, tiers: tiers)
    }

    nonisolated static func buildItems(rows: [TopRow], tiers: [TierInfo],
                                       scores: [Int64: DerivedScoreValue],
                                       filterActive: Bool) -> [TopDisplayItem] {
        let counts = tierCounts(rows: rows)
        let tierOrder = tiers.map(\.id)
        var items: [TopDisplayItem] = []
        var currentTier: Int64??  = nil
        var placedSeq = 0
        var previousTierID: Int64?
        for row in rows {
            if currentTier != .some(row.tierID) {
                currentTier = .some(row.tierID)
                if let tid = row.tierID, let tier = tiers.first(where: { $0.id == tid }) {
                    let idx = tierOrder.firstIndex(of: tid)
                    let above = idx.flatMap { $0 > 0 ? tierOrder[$0 - 1] : nil }
                    items.append(.divider(TopDivider(tier: tier,
                                                     placedCount: counts[tid]?.placed ?? 0,
                                                     unplacedCount: counts[tid]?.unplaced ?? 0,
                                                     upperTierID: above ?? previousTierID)))
                }
                previousTierID = row.tierID
            }
            let placed = row.isPlaced
            let bucket: PodiumBucket
            if !placed {
                bucket = .unplaced
            } else {
                bucket = placedSeq < 3 ? .top3 : (placedSeq < 10 ? .top10 : .compact)
                placedSeq += 1
            }
            let tierIdx = placed ? tierPlacedIndex(rows: rows, gameID: row.id) : nil
            items.append(.game(TopGameRow(
                row: row,
                bucket: bucket,
                displayRank: filterActive ? row.derivedPosition : row.globalPosition,
                overallRank: filterActive ? row.globalPosition : nil,
                tier: row.tierID.flatMap { tid in tiers.first { $0.id == tid } },
                tierIndex: tierIdx,
                score: scores[row.id])))
        }
        return items
    }

    nonisolated static func dividers(rows: [TopRow], tiers: [TierInfo]) -> [TopDivider] {
        let counts = tierCounts(rows: rows)
        return tiers.map { tier in
            TopDivider(tier: tier, placedCount: counts[tier.id]?.placed ?? 0,
                       unplacedCount: counts[tier.id]?.unplaced ?? 0, upperTierID: nil)
        }
    }

    private nonisolated static func tierCounts(rows: [TopRow]) -> [Int64: (placed: Int, unplaced: Int)] {
        var counts: [Int64: (placed: Int, unplaced: Int)] = [:]
        for row in rows {
            guard let tid = row.tierID else { continue }
            var c = counts[tid] ?? (0, 0)
            if row.isPlaced { c.placed += 1 } else { c.unplaced += 1 }
            counts[tid] = c
        }
        return counts
    }

    /// Index of a placed game within its tier's placed rows in the chart.
    private nonisolated static func tierPlacedIndex(rows: [TopRow], gameID: Int64) -> Int? {
        guard let row = rows.first(where: { $0.id == gameID }), let tid = row.tierID else { return nil }
        var idx = 0
        for r in rows where r.tierID == tid && r.isPlaced {
            if r.id == gameID { return idx }
            idx += 1
        }
        return nil
    }

    // MARK: Reorder (drag / keyboard) — only meaningful when unfiltered

    /// Convert the filtered/unfiltered rows into a Tier-Board-shaped board so the
    /// tested `TierBoardModel.planDrop` index math can be reused for reorder.
    private func boardFromRows() -> [TierBoardRow] {
        var placed: [Int64: [GameSummary]] = [:]
        var unplaced: [Int64: [GameSummary]] = [:]
        for row in rows {
            guard let tid = row.tierID else { continue }
            if row.isPlaced { placed[tid, default: []].append(row.game) }
            else { unplaced[tid, default: []].append(row.game) }
        }
        return tiers.map { TierBoardRow(tier: $0, placed: placed[$0.id] ?? [], unplaced: unplaced[$0.id] ?? []) }
    }

    /// Drop `gameID` into `toTier` at `gap` (index among that tier's placed rows).
    /// Crossing a divider changes the game's tier (PLAN §7). No-op when filtered.
    func reorder(gameID: Int64, toTier: Int64, gap: Int) async {
        guard !filterActive else { return }
        let board = boardFromRows()
        let plan = TierBoardModel.planDrop(board: board, gameIDs: [gameID], toTier: toTier, target: .gap(gap))
        guard !plan.isNoOp else { return }
        inFlight += 1
        for move in plan.moves {
            try? await backend.move(gameID: move.gameID, toTier: move.toTier, atIndex: move.atIndex)
        }
        inFlight -= 1
        if inFlight == 0 { await reload() }
    }

    /// `⌥↑` / `⌥↓` — move the focused game one position in the global order.
    func moveFocusedByOne(up: Bool) async {
        guard !filterActive, let id = focusedID else { return }
        let placedRows = rows.filter { $0.isPlaced }
        guard let gi = placedRows.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? gi - 1 : gi + 1
        guard target >= 0, target < placedRows.count else { return }
        // Neighbour defines the destination tier + slot.
        let neighbour = placedRows[target]
        guard let toTier = neighbour.tierID,
              let neighbourIndex = Self.tierPlacedIndex(rows: rows, gameID: neighbour.id) else { return }
        let gap = up ? neighbourIndex : neighbourIndex + 1
        await reorder(gameID: id, toTier: toTier, gap: gap)
        focusedID = id
    }

    // MARK: Movable dividers (PLAN §7 extension)

    /// The boundary currently being dragged, with its live step `k` (for preview).
    private(set) var dividerDrag: DividerDragState?
    /// The focused divider (its lower tier id) for `⌥↑/⌥↓` keyboard moves.
    private(set) var focusedDividerLower: Int64?

    struct DividerDragState: Equatable, Sendable {
        var upperTierID: Int64
        var lowerTierID: Int64
        var k: Int
    }

    /// Approximate row height used to translate a divider drag into `k` games.
    static let dividerStepHeight: CGFloat = 44

    static func dividerSteps(pixels: CGFloat, stepHeight: CGFloat = dividerStepHeight) -> Int {
        guard stepHeight > 0 else { return 0 }
        return Int((pixels / stepHeight).rounded())
    }

    /// Clamp `k` to the games available on each side (downward ≤ lower placed,
    /// upward ≤ upper placed).
    static func clampDividerK(_ k: Int, upperPlaced: Int, lowerPlaced: Int) -> Int {
        if k > 0 { return min(k, lowerPlaced) }
        if k < 0 { return max(k, -upperPlaced) }
        return 0
    }

    /// New placed counts after a (clamped) divider move.
    static func previewCounts(upperPlaced: Int, lowerPlaced: Int, k: Int) -> (upper: Int, lower: Int) {
        let kc = clampDividerK(k, upperPlaced: upperPlaced, lowerPlaced: lowerPlaced)
        return (upperPlaced + kc, lowerPlaced - kc)
    }

    private func placedCount(_ tierID: Int64?) -> Int {
        guard let tierID else { return 0 }
        return rows.filter { $0.tierID == tierID && $0.isPlaced }.count
    }

    /// Begin / update a divider drag (raw pixels since it started). No-op when filtered.
    func updateDividerDrag(upperTierID: Int64, lowerTierID: Int64, pixels: CGFloat) {
        guard !filterActive else { return }
        // Dragging down (positive pixels) pushes the boundary down = games move up
        // into the upper tier (k > 0).
        let raw = Self.dividerSteps(pixels: pixels)
        let k = Self.clampDividerK(raw, upperPlaced: placedCount(upperTierID), lowerPlaced: placedCount(lowerTierID))
        dividerDrag = DividerDragState(upperTierID: upperTierID, lowerTierID: lowerTierID, k: k)
    }

    /// Preview label, e.g. "S 12 → 14 · A 3 → 1".
    func dividerPreviewText() -> String? {
        guard let d = dividerDrag, d.k != 0,
              let upper = tier(d.upperTierID), let lower = tier(d.lowerTierID) else { return nil }
        let (u, l) = Self.previewCounts(upperPlaced: placedCount(d.upperTierID),
                                        lowerPlaced: placedCount(d.lowerTierID), k: d.k)
        return "\(upper.letter) \(placedCount(d.upperTierID)) → \(u) · \(lower.letter) \(placedCount(d.lowerTierID)) → \(l)"
    }

    func commitDividerDrag() async {
        defer { dividerDrag = nil }
        guard let d = dividerDrag, d.k != 0 else { return }
        await moveDivider(upperTierID: d.upperTierID, lowerTierID: d.lowerTierID, by: d.k)
    }

    func cancelDividerDrag() { dividerDrag = nil }

    func focusDivider(lowerTierID: Int64?) { focusedDividerLower = lowerTierID; if lowerTierID != nil { focusedID = nil } }

    /// `⌥↑/⌥↓` on a focused divider — move it by one placed game.
    func nudgeFocusedDivider(down: Bool) async {
        guard !filterActive, let lower = focusedDividerLower,
              let idx = tiers.firstIndex(where: { $0.id == lower }), idx > 0 else { return }
        let upper = tiers[idx - 1].id
        await moveDivider(upperTierID: upper, lowerTierID: lower, by: down ? 1 : -1)
    }

    func moveDivider(upperTierID: Int64, lowerTierID: Int64, by k: Int) async {
        guard !filterActive else { return }
        inFlight += 1
        _ = try? await backend.moveDivider(between: upperTierID, and: lowerTierID, by: k)
        inFlight -= 1
        if inFlight == 0 { await reload() }
    }

    // MARK: Keyboard focus (↑ ↓)

    func moveFocus(up: Bool) {
        let order = rows.map(\.id)
        guard !order.isEmpty else { return }
        guard let id = focusedID, let idx = order.firstIndex(of: id) else { focusedID = order.first; return }
        let next = up ? max(0, idx - 1) : min(order.count - 1, idx + 1)
        focusedID = order[next]
    }

    func focus(_ id: Int64) { focusedID = id }
    func inspectFocused() { if let id = focusedID, let inspect = actions.inspect { inspect(id) } }
    func goToDuel() { actions.goToDuel?() }

    func undo() async {
        inFlight += 1
        _ = try? await backend.undo()
        inFlight -= 1
        if inFlight == 0 { await reload() }
    }

    // MARK: CSV export (PLAN §7)

    /// Build the CSV. `playtime` maps game id → effective playtime seconds.
    /// UTF-8 BOM prefix for Excel; scores use a dot decimal regardless of locale.
    func csv(playtime: [Int64: Int?]) -> String {
        Self.csv(rows: rows, tiers: tiers, scores: scores, playtime: playtime, filterActive: filterActive)
    }

    /// Gather playtime for the current chart and render the CSV (PLAN §7 export).
    func csvExport() async -> String {
        var playtime: [Int64: Int?] = [:]
        for row in rows {
            let detail = try? await backend.gameDetail(id: row.id)
            playtime[row.id] = detail?.effectivePlaytimeS
        }
        return csv(playtime: playtime)
    }

    nonisolated static func csv(rows: [TopRow], tiers: [TierInfo],
                                scores: [Int64: DerivedScoreValue],
                                playtime: [Int64: Int?], filterActive: Bool) -> String {
        var lines = ["\u{FEFF}rank,derived rank,score,title,year,platforms,tier,playtime"]
        for row in rows {
            let rank = row.globalPosition.map(String.init) ?? ""
            let derived = filterActive ? (row.derivedPosition.map(String.init) ?? "") : rank
            let score = scores[row.id].map { String(format: "%.1f", $0.value) } ?? ""
            let year = row.game.year.map(String.init) ?? ""
            let platforms = row.game.platformIDs.map { PlatformLabels.short($0) }.joined(separator: " ")
            let tier = row.tierLetter ?? ""
            let playSeconds = playtime[row.id] ?? nil
            let play = playSeconds.map { hoursString($0) } ?? ""
            let fields = [rank, derived, score, row.game.title, year, platforms, tier, play]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    /// RFC-4180 escaping: quote fields with comma / quote / newline, double quotes.
    nonisolated static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private nonisolated static func hoursString(_ seconds: Int) -> String {
        let hours = Double(seconds) / 3600
        return String(format: "%.1fh", hours)
    }

    /// A stable filename for the export, reflecting the filter.
    var exportFilename: String {
        let suffix = filterActive ? "-" + filterChips.dropFirst().joined(separator: "-")
            .replacingOccurrences(of: " ", with: "-") : ""
        return "VGN-Top\(suffix).csv"
    }
}
