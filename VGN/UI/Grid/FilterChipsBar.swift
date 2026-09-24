import SwiftUI

/// The removable active-filter chips shown under the toolbar (PLAN §8). One chip
/// per value, grouped by kind — reading e.g. "Genre: RPG or Adventure" — each
/// removable by click or keyboard (focus a chip, press ⌫/Space), plus a trailing
/// "Clear all". Hidden when no facet is active.
struct FilterChipsBar: View {
    @Bindable var vm: LibraryViewModel
    /// Test hook: reports the laid-out frames (bar coordinate space) so a hosted test can
    /// check the count's alignment. Nil in the app.
    var layoutProbe: ((FilterChipsBarPart, CGRect) -> Void)? = nil

    /// Horizontal inset of the bar = the grid's content inset, so the chips start over the
    /// first grid column and the count ends over the last one (owner 2026-09-25).
    static let horizontalInset: CGFloat = LibraryGridView.contentInset
    nonisolated static let coordinateSpace = "filterChipsBar"

    var body: some View {
        let chips = vm.filterChips
        // A search alone is a chip too ("Search: “souls”"), so a search-only filter shows the
        // bar — and its count — as well. Hidden (zero height) when nothing is filtered.
        if !chips.isEmpty {
            // The count sits OUTSIDE the wrapping chips: pinned to the trailing edge, its text
            // baseline on the FIRST chip row's baseline (the flow layout exposes its first
            // item's baseline), never wrapping with the chips (owner 2026-09-25).
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // NOT a ScrollView: a scroll view whose top edge touches the window toolbar
                // never delivers clicks to its buttons on macOS (they land on its clip view) —
                // the ✕ and "Clear all" were dead in the real window. A wrapping row also
                // keeps every chip visible. Guarded by `FilterChipsClickTests`.
                FilterChipsFlowLayout(spacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                        ChipView(chip: chip) { vm.removeFilterChip(chip) }
                            // e.g. "filter.chip.tier:1", "filter.chip.status:finished".
                            .accessibilityIdentifier(A11yID.filterChip(chip.id))
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(Self.coordinateSpace))
                            } action: { if index == 0 { layoutProbe?(.firstChip, $0) } }
                    }
                    Button("Clear all") { vm.clearAllFilters() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.leading, 4)
                        .padding(.vertical, 3)
                        .accessibilityIdentifier(A11yID.filterClearAll)
                        .help("Remove every active filter")
                    // One-click escape from a scoped search to the whole library.
                    if vm.selection != .all,
                       !vm.filter.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Search all") { vm.searchAllScope() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .padding(.vertical, 3)
                            .help("Search the whole library, not just this list")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                countView
                    .padding(.leading, 12)
                    // Offered its size before the chips: the chips wrap first (down to their
                    // widest chip), only then does the count fall back to its compact form.
                    .layoutPriority(1)
            }
            .padding(.horizontal, Self.horizontalInset)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named(Self.coordinateSpace))
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { layoutProbe?(.bar, $0) }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier(A11yID.filterChips)
        }
    }

    /// "37 of 443 games", or — when even that does not fit next to the widest chip —
    /// "37 games". Single line, never truncated mid-number.
    @ViewBuilder
    private var countView: some View {
        let shown = vm.games.count
        let total = vm.counts.count(for: vm.selection)
        let selected = vm.selectedGameIDs.count
        if let full = FilterCountSummary.text(shown: shown, total: total, selected: selected,
                                              loaded: vm.gamesLoaded),
           let compact = FilterCountSummary.text(shown: shown, total: total, selected: selected,
                                                 loaded: vm.gamesLoaded, compact: true) {
            ViewThatFits(in: .horizontal) {
                countText(full)
                countText(compact)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(A11yID.filterCount)
            .accessibilityLabel(FilterCountSummary.accessibilityLabel(
                shown: shown, total: total, selected: selected, loaded: vm.gamesLoaded) ?? "")
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(Self.coordinateSpace))
            } action: { layoutProbe?(.count, $0) }
        }
    }

    private func countText(_ string: String) -> some View {
        Text(string)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// The parts `FilterChipsBar.layoutProbe` reports.
enum FilterChipsBarPart: Hashable, Sendable { case bar, firstChip, count }

/// The chips' wrapping row: `RankingFlowLayout`'s wrapping, plus the two things the bar
/// needs to put the count beside it —
/// - a minimum width of its widest item (so the bar's `HStack` knows how far the chips can
///   squeeze before the count must shorten), and
/// - a first-text-baseline = its first item's (rows are top-aligned, the first item sits at
///   the top-left), so the count lines up with the FIRST row, not a multi-row bar's middle.
struct FilterChipsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width.map { max($0, widest) }
        return RankingFlowLayout(spacing: spacing)
            .sizeThatFits(proposal: ProposedViewSize(width: width, height: proposal.height),
                          subviews: subviews, cache: &cache)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        RankingFlowLayout(spacing: spacing)
            .placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout Void) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: .unspecified)[.firstTextBaseline]
    }
}

/// One filter chip: a capsule with the chip text and a remove button. Focusable
/// and keyboard-removable (⌫ / delete while focused).
private struct ChipView: View {
    let chip: FilterChip
    let onRemove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(chip.text).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(chip.fullLabel)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(focused ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
        )
        .overlay(Capsule().strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Capsule())
        .focusable()
        .focused($focused)
        .accessibilityLabel(chip.fullLabel)
        .accessibilityAddTraits(.isButton)
        .onKeyPress(.delete) { onRemove(); return .handled }
        .onKeyPress(.deleteForward) { onRemove(); return .handled }
        .onKeyPress(.space) { onRemove(); return .handled }
        .onTapGesture(count: 2, perform: onRemove)   // double-click the chip to remove
    }
}

#if DEBUG
#Preview("Filter chips") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    vm.applyTiers([TierInfo(id: 1, letter: "S", label: "Masterpiece", colorHex: "#FF3B30", sort: 0),
                   TierInfo(id: 2, letter: "A", label: "Excellent", colorHex: "#FF9500", sort: 1)])
    var f = LibraryFilter(scope: .all)
    f.searchText = "souls"
    f.genres = ["RPG", "Adventure"]
    f.tierIDs = [1, 2]
    f.formats = [.rom, .physical]
    f.platforms = ["ps4", "snes"]
    vm.setFilter(f)
    return FilterChipsBar(vm: vm).frame(width: 620)
}
#endif
