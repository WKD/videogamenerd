import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Top (PLAN §7, view 2) — a numbered #1…#N chart with inline tier dividers,
/// podium treatment for the top 10, filter-aware derived vs global numbering,
/// drag reorder (only when unfiltered), and CSV export. A thin shell over
/// ``TheTopModel``.
struct TheTopView: View {
    @State private var model: TheTopModel
    private let loader: any CoverLoading
    @Environment(\.rankingActions) private var actions
    @Environment(\.rankingLibraryFilter) private var libraryFilter
    @FocusState private var focused: Bool

    init(env: RankingEnvironment) {
        _model = State(initialValue: TheTopModel(backend: env.backend))
        self.loader = env.coverLoader
    }

    init(model: TheTopModel, loader: any CoverLoading) {
        _model = State(initialValue: model)
        self.loader = loader
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            distributionStrip
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11yID.theTop)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: handleKey)
        .task {
            model.installActions(actions)
            if let libraryFilter { model.setFilter(libraryFilter) }
            await model.start()
            focused = true
        }
        .onDisappear { model.stop() }
        .onChange(of: libraryFilter) { _, new in if let new { model.setFilter(new) } }
    }

    // MARK: Header (filter chips + export)

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.filterChips.enumerated()), id: \.offset) { _, chip in
                Text(chip)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            if model.filterActive {
                Text("dragging off while filtered")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                export()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier(A11yID.topExport)
            .help("Export this chart as CSV (⌘E)")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Distribution strip (games per tier, placed / unplaced)

    @ViewBuilder
    private var distributionStrip: some View {
        if !model.rows.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.distribution) { div in
                        HStack(spacing: 4) {
                            TierChip(letter: div.tier.letter, colorHex: div.tier.colorHex, size: 16,
                                     label: div.tier.label)
                            Text("\(div.placedCount)").font(.caption.monospacedDigit())
                            if div.unplacedCount > 0 {
                                Text("+\(div.unplacedCount)")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            EmptyStateView(
                systemImage: "list.number",
                title: "Nothing ranked yet",
                message: "Tier and rank some games and they'll chart here, from your number one down.",
                actions: [
                    EmptyStateAction(title: "Start ranking", systemImage: "square.stack.3d.up.fill",
                                     isProminent: true) { model.goToDuel() },
                ])
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .divider(let divider):
                            TopDividerView(divider: divider, model: model,
                                           flatIndex: index, anchorID: item.id)
                        case .game(let row):
                            TopRowView(row: row, model: model, loader: loader,
                                       flatIndex: index, anchorID: item.id)
                                .accessibilityIdentifier(A11yID.topRow(row.id))
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let option = press.modifiers.contains(.option)
        let command = press.modifiers.contains(.command)
        if command, press.key == KeyEquivalent("z") { Task { await model.undo() }; return .handled }
        if command, press.key == KeyEquivalent("e") { export(); return .handled }
        let dividerFocused = model.focusedDividerLower != nil
        switch press.key {
        case .upArrow:
            if option, dividerFocused { Task { await model.nudgeFocusedDivider(down: false) } }
            else if option { Task { await model.moveFocusedByOne(up: true) } }
            else { model.moveFocus(up: true) }
            return .handled
        case .downArrow:
            if option, dividerFocused { Task { await model.nudgeFocusedDivider(down: true) } }
            else if option { Task { await model.moveFocusedByOne(up: false) } }
            else { model.moveFocus(up: false) }
            return .handled
        case .escape:
            model.cancelDividerDrag(); return .handled
        case .return:
            model.inspectFocused(); return .handled
        default:
            return .ignored
        }
    }

    // MARK: CSV export via NSSavePanel

    private func export() {
        let filename = model.exportFilename
        Task {
            let csv = await model.csvExport()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? Data(csv.utf8).write(to: url)
        }
    }
}

// MARK: - Divider

private struct TopDividerView: View {
    let divider: TopDivider
    let model: TheTopModel
    let flatIndex: Int
    let anchorID: String
    @State private var rowHeight: CGFloat = TheTopModel.dividerStepHeight

    /// A divider can be dragged only when it has a tier above it and no filter.
    private var draggable: Bool { divider.upperTierID != nil && !model.filterActive }
    private var isDragging: Bool {
        model.dividerDrag?.lowerTierID == divider.tier.id && (model.dividerDrag?.k ?? 0) != 0
    }
    private var isFocused: Bool { model.focusedDividerLower == divider.tier.id }

    var body: some View {
        HStack(spacing: 8) {
            if draggable {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            TierChip(letter: divider.tier.letter, colorHex: divider.tier.colorHex, size: 20,
                     label: divider.tier.label)
            Text(divider.tier.label).font(.subheadline.weight(.semibold))
            Text("^[\(divider.placedCount) game](inflect: true)")
                .font(.caption).foregroundStyle(.secondary)
            if divider.unplacedCount > 0 {
                Text("· \(divider.unplacedCount) unplaced").font(.caption).foregroundStyle(.tertiary)
            }
            if isDragging, let preview = model.dividerPreviewText() {
                Text(preview)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: Capsule())
            }
            Rectangle()
                .fill(Color(hex: divider.tier.colorHex) ?? .secondary)
                .frame(height: isFocused || isDragging ? 3 : 2)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
        .contentShape(Rectangle())
        .background(RowHeightReader($rowHeight))
        .overlay(alignment: .top) {
            if model.insertionEdge(for: anchorID) == .above {
                TopInsertionLine(colorHex: model.dropLineColorHex, letter: model.dropLineTierLetter)
            }
        }
        .overlay(alignment: .bottom) {
            if model.insertionEdge(for: anchorID) == .below {
                TopInsertionLine(colorHex: model.dropLineColorHex, letter: model.dropLineTierLetter)
            }
        }
        .onTapGesture { if draggable { model.focusDivider(lowerTierID: divider.tier.id) } }
        .gesture(draggable ? dragGesture : nil)
        .onDrop(of: [.vgnRankingItem],
                delegate: TopDropDelegate(model: model, flatIndex: flatIndex,
                                          anchorID: anchorID, rowHeight: rowHeight))
        .help(draggable ? "Drag to move the S/A boundary; ⌥↑/⌥↓ when focused" : "")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let upper = divider.upperTierID else { return }
                model.updateDividerDrag(upperTierID: upper, lowerTierID: divider.tier.id,
                                        pixels: value.translation.height)
            }
            .onEnded { _ in Task { await model.commitDividerDrag() } }
    }
}

// MARK: - Row

private struct TopRowView: View {
    let row: TopGameRow
    let model: TheTopModel
    let loader: any CoverLoading
    let flatIndex: Int
    let anchorID: String

    @State private var rowHeight: CGFloat = 44

    private var coverSize: CGFloat {
        switch row.bucket {
        case .top3: return 96
        case .top10: return 60
        case .compact, .unplaced: return 40
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            rankColumn
            RankingCoverView(title: row.row.game.title, coverFile: row.row.game.coverFile,
                             platformID: row.row.game.platformIDs.first, loader: loader)
                .frame(width: coverSize, height: coverSize * 4.0 / 3.0)
            info
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, row.bucket == .top3 ? 8 : 4)
        .background(model.focusedID == row.id ? Color.accentColor.opacity(0.12) : .clear)
        .background(RowHeightReader($rowHeight))
        .overlay(alignment: .top) {
            if model.insertionEdge(for: anchorID) == .above {
                TopInsertionLine(colorHex: model.dropLineColorHex, letter: model.dropLineTierLetter)
            }
        }
        .overlay(alignment: .bottom) {
            if model.insertionEdge(for: anchorID) == .below {
                TopInsertionLine(colorHex: model.dropLineColorHex, letter: model.dropLineTierLetter)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focus(row.id) }
        .modifier(TopDragSource(enabled: !model.filterActive && row.isPlaced,
                                gameID: row.id, sourceTierID: row.tier?.id, model: model))
        .onDrop(of: [.vgnRankingItem],
                delegate: TopDropDelegate(model: model, flatIndex: flatIndex,
                                          anchorID: anchorID, rowHeight: rowHeight))
    }

    private var rankColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let rank = row.displayRank {
                Text("#\(rank)")
                    .font(rankFont).monospacedDigit()
                    .foregroundStyle(row.bucket == .top3 ? Color.accentColor : .primary)
            } else {
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
            }
            if let score = row.score {
                Text(score.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(score.isApproximate ? .tertiary : .secondary)
            }
            if let overall = row.overallRank {
                Text("#\(overall) overall").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 72, alignment: .trailing)
    }

    private var rankFont: Font {
        switch row.bucket {
        case .top3: return .largeTitle.weight(.bold)
        case .top10: return .title2.weight(.semibold)
        default: return .body
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.row.game.title)
                .font(row.bucket == .top3 ? .title3.weight(.semibold) : .body)
                .lineLimit(1)
                .opacity(row.isPlaced ? 1 : 0.5)
            HStack(spacing: 6) {
                if let year = row.row.game.year { Text(String(year)).foregroundStyle(.secondary) }
                ForEach(row.row.game.platformIDs.prefix(3), id: \.self) { PlatformChip(slug: $0) }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let letter = row.tier?.letter {
            TierChip(letter: letter, colorHex: row.tier?.colorHex, size: 18,
                     label: row.tier?.label, score: row.score)
        }
        if !row.isPlaced {
            Button("Place") { model.goToDuel() }.buttonStyle(.borderless).font(.caption)
        }
    }

}

// MARK: - Drag source / drop feedback

/// Conditionally makes a row a drag source. Uses `.onDrag` (not `.draggable`) so
/// the dragged game id is captured **synchronously** at drag start into the model
/// — hover feedback then never has to decode the pasteboard provider (which is
/// async). The provider still carries the private `RankingDragItem` UTType so a
/// `DropDelegate` (and only in-app targets) accept it.
private struct TopDragSource: ViewModifier {
    let enabled: Bool
    let gameID: Int64
    let sourceTierID: Int64?
    let model: TheTopModel

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                model.beginDrag(gameID: gameID, sourceTierID: sourceTierID)
                return Self.provider(gameID: gameID, sourceTierID: sourceTierID)
            }
        } else {
            content
        }
    }

    private static func provider(gameID: Int64, sourceTierID: Int64?) -> NSItemProvider {
        let item = RankingDragItem(gameIDs: [gameID], sourceTierID: sourceTierID)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.vgnRankingItem.identifier,
                                             visibility: .ownProcess) { completion in
            completion(try? JSONEncoder().encode(item), nil)
            return nil
        }
        return provider
    }
}

/// Per-row/-divider drop target. `dropUpdated` gives `info.location` in the row's
/// coordinate space (unlike `.dropDestination`'s `isTargeted` Bool), so it can set
/// the insertion line; `performDrop` lands the game exactly where that line shows.
private struct TopDropDelegate: DropDelegate {
    let model: TheTopModel
    let flatIndex: Int
    let anchorID: String
    let rowHeight: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        !model.filterActive && info.hasItemsConforming(to: [.vgnRankingItem])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let edge = TheTopDropGeometry.edge(locationY: info.location.y, rowHeight: rowHeight)
        model.updateDropTarget(flatIndex: flatIndex, edge: edge)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        model.clearDropTarget(ownedBy: anchorID)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.commitDrop()
    }
}

/// A 2 pt accent (or destination-tier) insertion line with the small leading knob
/// of an AppKit table view. When the drop would change tier, the knob carries the
/// destination tier's letter and the line takes its colour (a subtle hint that
/// reads in light and dark).
private struct TopInsertionLine: View {
    var colorHex: String?
    var letter: String?

    private var color: Color { colorHex.flatMap { Color(hex: $0) } ?? .accentColor }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(color).frame(width: 10, height: 10)
                if let letter {
                    Text(letter)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Rectangle().fill(color).frame(height: 2)
        }
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
        .transition(.identity)
    }
}

/// Reports its container's height into a binding (to size the upper/lower-half
/// split for the drop delegate). Writes only on change.
private struct RowHeightReader: View {
    @Binding var height: CGFloat
    init(_ height: Binding<CGFloat>) { _height = height }

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { height = geo.size.height }
                .onChange(of: geo.size.height) { _, new in height = new }
        }
    }
}

#if DEBUG
#Preview("The Top — unfiltered") {
    TheTopView(model: TheTopModel(backend: ScriptedRankingBackend.previewTop(n: 24)),
               loader: NoopCoverLoader())
        .frame(width: 720, height: 720)
}

#Preview("The Top — filtered") {
    TheTopView(model: TheTopModel(backend: ScriptedRankingBackend.previewTop(n: 24, filtered: true),
                                  filter: LibraryFilter(scope: .platform("ps2"))),
               loader: NoopCoverLoader())
        .frame(width: 720, height: 720)
}

#Preview("The Top — short list") {
    TheTopView(model: TheTopModel(backend: ScriptedRankingBackend.previewTop(n: 5)),
               loader: NoopCoverLoader())
        .frame(width: 720, height: 520)
}
#endif
