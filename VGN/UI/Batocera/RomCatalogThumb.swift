import SwiftUI

/// A ROM box-art thumbnail read from the Batocera share (PLAN §15). Decodes off the main
/// actor through ``BatoceraThumbnailLoader`` and shows a placeholder while loading, when the
/// share is unmounted, or when the entry has no art. Never copies the image anywhere.
struct RomCatalogThumb: View {
    let entry: RomCatalogEntry
    let loader: BatoceraThumbnailLoader?
    var width: CGFloat = 44
    var height: CGFloat = 58

    @State private var image: CGImage?
    @State private var loadedKey: Int64 = -1

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: entry.id) { await load() }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary)
            .overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary).font(.caption))
    }

    private func load() async {
        guard entry.id != loadedKey else { return }
        image = nil
        guard let loader else { return }
        let pixels = Int(max(width, height) * 2)
        let decoded = await loader.thumbnail(
            system: entry.system, thumbnailPath: entry.thumbnailPath,
            imagePath: entry.imagePath, maxPixelSize: pixels)
        if !Task.isCancelled {
            image = decoded
            loadedKey = entry.id
        }
    }
}
