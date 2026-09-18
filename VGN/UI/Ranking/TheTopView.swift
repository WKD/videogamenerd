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
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .help("Export this chart as CSV (⌘E)")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            ContentUnavailableView {
                Label("Nothing ranked yet", systemImage: "list.number")
            } description: {
                Text("Tier and rank some games and they'll chart here.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.items) { item in
                        switch item {
                        case .divider(let divider):
                            TopDividerView(divider: divider)
                        case .game(let row):
                            TopRowView(row: row, model: model, loader: loader)
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
        switch press.key {
        case .upArrow:
            if option { Task { await model.moveFocusedByOne(up: true) } } else { model.moveFocus(up: true) }
            return .handled
        case .downArrow:
            if option { Task { await model.moveFocusedByOne(up: false) } } else { model.moveFocus(up: false) }
            return .handled
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

    var body: some View {
        HStack(spacing: 8) {
            TierChip(letter: divider.tier.letter, colorHex: divider.tier.colorHex, size: 20)
            Text(divider.tier.label).font(.subheadline.weight(.semibold))
            Text("^[\(divider.placedCount) game](inflect: true)")
                .font(.caption).foregroundStyle(.secondary)
            if divider.unplacedCount > 0 {
                Text("· \(divider.unplacedCount) unplaced").font(.caption).foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(Color(hex: divider.tier.colorHex) ?? .secondary)
                .frame(height: 2)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }
}

// MARK: - Row

private struct TopRowView: View {
    let row: TopGameRow
    let model: TheTopModel
    let loader: any CoverLoading

    @State private var dropEdge: Edge?

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
        .overlay(alignment: dropEdge == .top ? .top : .bottom) {
            if dropEdge != nil { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focus(row.id) }
        .modifier(DraggableIf(enabled: !model.filterActive && row.isPlaced,
                              item: RankingDragItem(gameIDs: [row.id], sourceTierID: row.tier?.id)))
        .dropDestination(for: RankingDragItem.self) { items, location in
            drop(items, location: location)
        } isTargeted: { hovering in
            if !hovering { dropEdge = nil }
        }
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
            TierChip(letter: letter, colorHex: row.tier?.colorHex, size: 18)
        }
        if !row.isPlaced {
            Button("Place") { model.goToDuel() }.buttonStyle(.borderless).font(.caption)
        }
    }

    private func drop(_ items: [RankingDragItem], location: CGPoint) -> Bool {
        dropEdge = nil
        guard !model.filterActive, let id = items.flatMap(\.gameIDs).first,
              let tier = row.tier, let tierIndex = row.tierIndex else { return false }
        let before = location.y < coverSize * 2.0 / 3.0
        let gap = before ? tierIndex : tierIndex + 1
        Task { await model.reorder(gameID: id, toTier: tier.id, gap: gap) }
        return true
    }
}

/// Conditionally attaches `.draggable` (macOS 15 has no boolean form).
private struct DraggableIf: ViewModifier {
    let enabled: Bool
    let item: RankingDragItem

    func body(content: Content) -> some View {
        if enabled { content.draggable(item) } else { content }
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
