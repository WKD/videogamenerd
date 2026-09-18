import SwiftUI

/// The removable active-filter chips shown under the toolbar (PLAN §8). One chip
/// per value, grouped by kind — reading e.g. "Genre: RPG or Adventure" — each
/// removable by click or keyboard (focus a chip, press ⌫/Space), plus a trailing
/// "Clear all". Hidden when no facet is active.
struct FilterChipsBar: View {
    @Bindable var vm: LibraryViewModel

    var body: some View {
        let chips = vm.filterChips
        if !chips.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in
                        ChipView(chip: chip) { vm.removeFilterChip(chip) }
                    }
                    Button("Clear all") { vm.clearAllFilters() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.leading, 4)
                        .help("Remove every active filter")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
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
