import AppKit
import SwiftUI

/// One fixed-size grid tile (PLAN §8/§9). A 3:4 cover area with the art
/// aspect-*fit* on a neutral backing (never cropped — box shapes vary wildly by
/// platform, PLAN §5.2), corner badge overlays, a two-line reserved title and a
/// year line. Reads everything from its own `@Observable` box so a cover
/// arriving re-renders only this cell.
struct GameCell: View {
    @Bindable var model: GameCellModel
    let coverLoader: any CoverLoading
    var isSelected: Bool = false
    /// The game's derived 1–10 score, for the tier-badge hover tooltip (nil when
    /// the game is unranked or scores haven't loaded). Passed as a plain value so
    /// only cells whose score changed re-render.
    var score: DerivedScoreValue? = nil
    var cellWidth: CGFloat = 150

    var onTap: () -> Void = {}
    var onCommandTap: () -> Void = {}
    var onShiftTap: () -> Void = {}
    /// Dropping an image file onto the cell sets a manual cover (PLAN §5.2 pt 4).
    var onDropCover: (URL) -> Void = { _ in }

    @Environment(\.displayScale) private var displayScale
    @State private var isDropTargeted = false

    /// What a click does, Finder-style: ⌘ toggles the game in the selection, ⇧ extends
    /// the selection from the anchor, anything else selects only this game. ⌘ wins
    /// when both are held; Caps Lock, ⌥, ⌃ and fn do not change the meaning.
    enum ClickKind: Equatable { case select, toggle, extend }

    nonisolated static func clickKind(for flags: NSEvent.ModifierFlags) -> ClickKind {
        let relevant = flags.intersection(.deviceIndependentFlagsMask)
        if relevant.contains(.command) { return .toggle }
        if relevant.contains(.shift) { return .extend }
        return .select
    }

    private var game: GameSummary { model.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverArea
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: .infinity)

            Text(game.title)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Year, then the platform(s) as small grey pills. Fixed height so every
            // cell keeps the same size whether or not it has a year / platforms.
            HStack(spacing: 4) {
                if let year = game.year {
                    Text(String(year))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(Self.platformPills(for: game.platformIDs), id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
            .clipped()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // ONE tap gesture, modifiers read at click time. Three stacked gestures
        // (`onTapGesture` + `TapGesture().modifiers(…)`) do not work: the plain tap is
        // attached first and wins even while ⌘/⇧ is held, so every click replaced
        // the selection.
        .onTapGesture {
            switch Self.clickKind(for: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags) {
            case .toggle: onCommandTap()
            case .extend: onShiftTap()
            case .select: onTap()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL }) else { return false }
            onDropCover(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .task(id: coverTaskID) { await loadCover() }
        .help(game.title)
        // Collapse the tile into one accessible element carrying the visual-only
        // state (tier / owned / played / ROM) as its value, so the UI smoke suite
        // can assert e.g. "Tier A" without a pixel read — and VoiceOver reads it.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(game.title)
        .accessibilityValue(a11yStateValue)
    }

    /// Labels for the platform pills shown after the year: short names, de-duplicated,
    /// in the order given; at most two are spelled out, the rest collapse into "+n"
    /// (a 140 pt cell has room for the year and about two pills).
    static func platformPills(for platformIDs: [String]) -> [String] {
        var shorts: [String] = []
        for id in platformIDs {
            let label = PlatformLabels.short(id)
            if !shorts.contains(label) { shorts.append(label) }
        }
        guard shorts.count > 2 else { return shorts }
        return Array(shorts.prefix(2)) + ["+\(shorts.count - 2)"]
    }

    /// The tile's visual-only state as a spoken/queried value (PLAN §8 badges).
    private var a11yStateValue: String {
        var parts: [String] = []
        if let letter = game.tierLetter { parts.append("Tier \(letter)") }
        if game.hasPhysical { parts.append("Physical") }
        if game.hasDigital { parts.append("Digital") }
        if game.hasROM { parts.append("ROM") }
        if game.hasSubscription { parts.append("PS Plus") }
        if game.played { parts.append("Played") }
        return parts.isEmpty ? "Unranked" : parts.joined(separator: ", ")
    }

    // The task re-runs (and cancels the previous load) whenever the game id or
    // its cover file changes; SwiftUI cancels it automatically on disappear.
    private var coverTaskID: String { "\(game.id)#\(game.coverFile ?? "")" }

    private func loadCover() async {
        guard let coverFile = game.coverFile else {
            model.thumbnail = nil
            return
        }
        let pixels = CGSize(
            width: cellWidth * displayScale,
            height: cellWidth * 4 / 3 * displayScale
        )
        let image = await coverLoader.thumbnail(for: coverFile, pixelSize: pixels)
        if !Task.isCancelled {
            model.thumbnail = image
        }
    }

    private var coverArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)

            if let thumbnail = model.thumbnail {
                Image(decorative: thumbnail, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)   // aspect-FIT, never cropped
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlaceholderCover(title: game.title, platformID: game.platformIDs.first)
            }

            badges
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var badges: some View {
        VStack {
            HStack(alignment: .top) {
                if let letter = game.tierLetter {
                    // Label comes from the `\.tierLabels` environment; the derived
                    // score (when the game is ranked) enriches the hover tooltip.
                    TierChip(letter: letter, colorHex: game.tierColorHex, size: 22, score: score)
                }
                Spacer(minLength: 0)
                if game.isCompilationMember {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .help(game.compilationTitle.map { "Part of \($0)" } ?? "Part of a compilation")
                }
            }
            Spacer()
            // How I own this game (PLAN §8, wave 17): one badge per distinct format among
            // the really-owned copies — physical (disc) → digital (download) → ROM (chip) →
            // PS Plus (the asset) — then the played controller. Any format badge means owned,
            // so the old generic "Owned" box is gone.
            HStack(spacing: 4) {
                ForEach(FormatBadges.badges(for: game)) { badge in
                    formatBadge(badge)
                }
                if game.played {
                    statusBadge(system: "gamecontroller.fill", tint: .green, help: "Played")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private func formatBadge(_ badge: FormatBadge) -> some View {
        switch badge.kind {
        case .physical:
            statusBadge(system: "opticaldisc.fill", tint: .blue, help: Self.badgeTooltip(badge))
        case .digital:
            statusBadge(system: "arrow.down.circle.fill", tint: .teal, help: Self.badgeTooltip(badge))
        case .rom:
            statusBadge(system: "memorychip.fill", tint: .purple, help: Self.badgeTooltip(badge))
        case .psPlus:
            PSPlusBadgeView(size: 17).help(Self.badgeTooltip(badge))
        }
    }

    /// A format badge's tooltip: format name + the platform(s) of those copies
    /// ("Physical · PS3", "Digital · PS5, PC"); PS Plus adds the expiry note.
    static func badgeTooltip(_ badge: FormatBadge) -> String {
        let name: String
        switch badge.kind {
        case .physical: name = "Physical"
        case .digital: name = "Digital"
        case .rom: name = "ROM"
        case .psPlus: name = "PS Plus"
        }
        let plats = badge.platformIDs.map(PlatformLabels.short).joined(separator: ", ")
        var text = plats.isEmpty ? name : "\(name) · \(plats)"
        if badge.kind == .psPlus { text += " — expires with the subscription" }
        return text
    }

    private func statusBadge(system: String, tint: Color, help: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(tint.opacity(0.9), in: Circle())
            .help(help)
    }
}

#if DEBUG
#Preview("Cell states") {
    let loader = NoopCoverLoader()
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180))], spacing: 14) {
        ForEach(GameSummary.samples) { game in
            GameCell(
                model: GameCellModel(summary: game),
                coverLoader: loader,
                isSelected: game.id == 2
            )
        }
    }
    .padding()
    .frame(width: 520)
}
#endif
