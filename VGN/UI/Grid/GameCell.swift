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
    var cellWidth: CGFloat = 150

    var onTap: () -> Void = {}
    var onCommandTap: () -> Void = {}
    var onShiftTap: () -> Void = {}

    @Environment(\.displayScale) private var displayScale

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

            Text(game.year.map(String.init) ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .onTapGesture(perform: onTap)
        .gesture(TapGesture().modifiers(.command).onEnded(onCommandTap))
        .gesture(TapGesture().modifiers(.shift).onEnded(onShiftTap))
        .task(id: coverTaskID) { await loadCover() }
        .help(game.title)
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
                    TierChip(letter: letter, colorHex: game.tierColorHex, size: 22)
                }
                Spacer(minLength: 0)
                if game.isCompilationMember {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.45), in: Circle())
                        .help("Part of a compilation")
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if game.owned {
                    statusBadge(system: "shippingbox.fill", tint: .blue, help: "Owned")
                }
                if game.played {
                    statusBadge(system: "gamecontroller.fill", tint: .green, help: "Played")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(6)
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
