import SwiftUI

/// A big aspect-fit cover on a neutral backing (PLAN §5.2 — "box shapes vary
/// wildly, so art is aspect-*fit* on a neutral backing rather than cropped"),
/// used by the Duel and Triage screens and reusable by the Tier Board / The Top
/// lane. Loads the thumbnail through the shared `CoverLoading` seam and falls
/// back to the generated `PlaceholderCover` (the day-one state).
struct RankingCoverView: View {
    let title: String
    var coverFile: String?
    var platformID: String?
    let loader: any CoverLoading

    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background.secondary)
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        PlaceholderCover(title: title, platformID: platformID)
                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(6)
            }
            .task(id: coverFile) {
                await load(pixelSize: CGSize(width: geo.size.width * displayScale,
                                             height: geo.size.height * displayScale))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private func load(pixelSize: CGSize) async {
        guard let coverFile else { image = nil; return }
        image = await loader.thumbnail(for: coverFile, pixelSize: pixelSize)
    }
}

#if DEBUG
#Preview("Ranking cover") {
    HStack(spacing: 16) {
        RankingCoverView(title: "Bloodborne", platformID: "ps4", loader: NoopCoverLoader())
        RankingCoverView(title: "Metal Gear Solid 3", platformID: "ps2", loader: NoopCoverLoader())
    }
    .frame(height: 360)
    .padding()
}
#endif
