import SwiftUI

/// Tier Board (PLAN §7, view 1) — classic tier-list rows: a coloured letter block
/// on the left, compact cover tiles wrapping to as many lines as needed on the
/// right, and a dimmed unplaced tail after a thin divider. Drag between rows to
/// re-tier, within a row to fine-order; multi-selection drags move the set. All
/// logic lives in ``TierBoardModel``.
struct TierBoardView: View {
    @State private var model: TierBoardModel
    private let loader: any CoverLoading
    @Environment(\.rankingActions) private var actions
    @FocusState private var focused: Bool

    init(env: RankingEnvironment) {
        _model = State(initialValue: TierBoardModel(backend: env.backend))
        self.loader = env.coverLoader
    }

    /// Preview / test seam: inject a model built over a fake backend.
    init(model: TierBoardModel, loader: any CoverLoading) {
        _model = State(initialValue: model)
        self.loader = loader
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            board
            tray
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: handleKey)
        .task {
            model.installActions(actions)
            await model.start()
            focused = true
        }
        .onDisappear { model.stop() }
    }

    // MARK: Header (size control + board-level Place button)

    private var header: some View {
        HStack(spacing: 14) {
            if model.totalUnplaced > 0 {
                Button {
                    model.goToDuel()
                } label: {
                    Label("Place ^[\(model.totalUnplaced) game](inflect: true)", systemImage: "flag.2.crossed")
                }
                .buttonStyle(.borderedProminent)
                .help("Run duels for every unplaced game")
            }
            Spacer()
            Image(systemName: "photo").foregroundStyle(.secondary).font(.caption)
            Slider(value: $model.tileWidth,
                   in: TierBoardModel.minTileWidth...TierBoardModel.maxTileWidth)
                .frame(width: 120)
                .help("Tile size")
            Image(systemName: "photo.fill").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Board rows

    private var board: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.rows) { row in
                    TierRowView(row: row, model: model, loader: loader)
                    Divider()
                }
            }
        }
    }

    // MARK: Unranked tray (played, no tier — collapsed by default)

    @ViewBuilder
    private var tray: some View {
        if !model.unrankedTray.isEmpty {
            Divider()
            UnrankedTrayView(model: model, loader: loader)
        }
    }

    // MARK: Keyboard routing (PLAN §7)

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let option = press.modifiers.contains(.option)
        let command = press.modifiers.contains(.command)

        if command, press.key == KeyEquivalent("z") {
            Task { await model.undo() }; return .handled
        }
        switch press.key {
        case .leftArrow:
            if option { Task { await model.nudgeWithinTier(forward: false) } }
            else { model.moveFocus(.left) }
            return .handled
        case .rightArrow:
            if option { Task { await model.nudgeWithinTier(forward: true) } }
            else { model.moveFocus(.right) }
            return .handled
        case .upArrow:
            if option { Task { await model.nudgeAcrossTier(up: true) } }
            else { model.moveFocus(.up) }
            return .handled
        case .downArrow:
            if option { Task { await model.nudgeAcrossTier(up: false) } }
            else { model.moveFocus(.down) }
            return .handled
        case .return:
            model.inspectFocused(); return .handled
        default:
            break
        }
        guard press.modifiers.isEmpty || press.modifiers == [.shift] else { return .ignored }
        let ch = press.characters
        if ch == "0" { Task { await model.clearSelectionTier() }; return .handled }
        if ch.count == 1, "sabcdfSABCDF".contains(ch) {
            Task { await model.retierSelection(letter: ch) }; return .handled
        }
        return .ignored
    }
}

// MARK: - One tier row

private struct TierRowView: View {
    let row: TierBoardRow
    let model: TierBoardModel
    let loader: any CoverLoading

    @State private var targetedGap: Int?
    @State private var tailTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            letterBlock
            VStack(alignment: .leading, spacing: 8) {
                placedFlow
                if !row.unplaced.isEmpty { unplacedTail }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(rowBackground)
    }

    // Left coloured letter block — a tier drop target without a position.
    private var letterBlock: some View {
        VStack(spacing: 4) {
            TierChip(letter: row.tier.letter, colorHex: row.tier.colorHex, size: 30)
            Text(row.tier.label)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(row.total)")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .frame(width: 86)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 10)
        .background((Color(hex: row.tier.colorHex) ?? .gray).opacity(tailTargeted ? 0.30 : 0.14))
        .contentShape(Rectangle())
        .dropDestination(for: RankingDragItem.self) { items, _ in
            drop(items, target: .tail)
        } isTargeted: { tailTargeted = $0 }
    }

    private var placedFlow: some View {
        RankingFlowLayout(spacing: 8) {
            ForEach(Array(row.placed.enumerated()), id: \.element.id) { index, game in
                tile(game)
                    .overlay(alignment: .leading) { insertionBar(before: index) }
                    .overlay(alignment: .trailing) { insertionBar(after: index) }
                    .dropDestination(for: RankingDragItem.self) { items, location in
                        drop(items, target: .gap(gap(for: index, at: location)))
                    } isTargeted: { hovering in
                        targetedGap = hovering ? index : (targetedGap == index ? nil : targetedGap)
                    }
            }
            if row.placed.isEmpty {
                Text("Drop games here")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(height: model.tileWidth * 4.0 / 3.0)
                    .dropDestination(for: RankingDragItem.self) { items, _ in
                        drop(items, target: .gap(0))
                    } isTargeted: { _ in }
            }
        }
    }

    private var unplacedTail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(.separator).frame(height: 1)
                Text("^[\(row.unplaced.count) unplaced](inflect: true)")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                Button("Place") { model.goToDuel() }
                    .buttonStyle(.borderless).font(.caption2)
                Rectangle().fill(.separator).frame(height: 1)
            }
            RankingFlowLayout(spacing: 8) {
                ForEach(row.unplaced) { game in
                    tile(game).opacity(0.5)
                }
            }
        }
        .dropDestination(for: RankingDragItem.self) { items, _ in
            drop(items, target: .tail)
        } isTargeted: { tailTargeted = $0 }
    }

    private func tile(_ game: GameSummary) -> some View {
        TierTileView(game: game, width: model.tileWidth,
                     selected: model.isSelected(game.id),
                     focused: model.focusedID == game.id,
                     tooltip: model.tooltip(for: game),
                     loader: loader)
            .onTapGesture { model.select(game.id) }
            .highPriorityGesture(
                TapGesture().modifiers(.command).onEnded { model.select(game.id, additive: true) }
            )
            .draggable(RankingDragItem(gameIDs: model.dragIDs(startingAt: game.id),
                                       sourceTierID: row.tier.id)) {
                TierTileView(game: game, width: model.tileWidth, selected: true,
                             focused: false, loader: loader)
            }
            .contextMenu {
                Button("Re-place (run duels)") { Task { await model.rePlace(game.id) } }
                Button("Remove from tier") { Task { await model.clearGame(game.id) } }
                if model.nextTierID(after: row.tier.id) != nil {
                    Divider()
                    Button("Pull up first of next tier") { Task { await model.pullUpFromBelow(row.tier.id) } }
                    Button("Push down last to next tier") { Task { await model.pushDownToBelow(row.tier.id) } }
                }
            }
    }

    @ViewBuilder
    private func insertionBar(before index: Int) -> some View {
        if targetedGap == index {
            Capsule().fill(Color.accentColor).frame(width: 3)
        }
    }
    @ViewBuilder
    private func insertionBar(after index: Int) -> some View {
        EmptyView()
    }

    private var rowBackground: some View {
        Rectangle().fill(.background)
    }

    // A drop's gap = its tile index (pointer in the left half) or index+1 (right).
    private func gap(for index: Int, at location: CGPoint) -> Int {
        location.x < model.tileWidth / 2 ? index : index + 1
    }

    private func drop(_ items: [RankingDragItem], target: TierDropTarget) -> Bool {
        let ids = items.flatMap(\.gameIDs)
        guard !ids.isEmpty else { return false }
        targetedGap = nil; tailTargeted = false
        Task { await model.drop(ids, toTier: row.tier.id, target: target) }
        return true
    }
}

// MARK: - One compact tile (fixed size + equatable ⇒ per-tile invalidation)

private struct TierTileView: View {
    let game: GameSummary
    let width: Double
    let selected: Bool
    let focused: Bool
    var tooltip: String = ""
    let loader: any CoverLoading

    var body: some View {
        RankingCoverView(title: game.title, coverFile: game.coverFile,
                         platformID: game.platformIDs.first, loader: loader)
            .frame(width: width, height: width * 4.0 / 3.0)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : (focused ? Color.secondary : .clear),
                                  lineWidth: selected || focused ? 2.5 : 0)
            }
            .help(tooltip.isEmpty ? game.title : tooltip)
    }
}

// MARK: - Unranked tray

private struct UnrankedTrayView: View {
    @Bindable var model: TierBoardModel
    let loader: any CoverLoading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.trayExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.trayExpanded ? "chevron.down" : "chevron.right")
                    Text("Unranked").font(.callout.weight(.medium))
                    Text("\(model.unrankedTray.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if model.unrankedTray.count > 20 {
                        Button("Triage…") { model.goToDuel() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 8)

            if model.trayExpanded {
                ScrollView(.horizontal) {
                    RankingFlowLayout(spacing: 8) {
                        ForEach(model.unrankedTray) { game in
                            TierTileView(game: game, width: model.tileWidth, selected: false,
                                         focused: false, loader: loader)
                                .draggable(RankingDragItem(gameIDs: [game.id], sourceTierID: nil))
                                .help(game.title)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
                .frame(maxHeight: model.tileWidth * 4.0 / 3.0 + 24)
            }
        }
        .background(.background.secondary)
    }
}

#if DEBUG
#Preview("Tier Board — small") {
    let backend = ScriptedRankingBackend.previewBoard(placedPerTier: 3, unplacedPerTier: 1)
    return TierBoardView(model: TierBoardModel(backend: backend), loader: NoopCoverLoader())
        .frame(width: 900, height: 620)
}

#Preview("Tier Board — empty") {
    let backend = ScriptedRankingBackend.previewBoard(placedPerTier: 0, unplacedPerTier: 0)
    return TierBoardView(model: TierBoardModel(backend: backend), loader: NoopCoverLoader())
        .frame(width: 900, height: 620)
}

#Preview("Tier Board — 300 tiles") {
    let backend = ScriptedRankingBackend.previewBoard(placedPerTier: 50, unplacedPerTier: 0)
    return TierBoardView(model: TierBoardModel(backend: backend), loader: NoopCoverLoader())
        .frame(width: 1000, height: 700)
}
#endif
