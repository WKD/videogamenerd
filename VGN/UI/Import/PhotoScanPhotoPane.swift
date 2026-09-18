import SwiftUI
import ImageIO

/// The review sheet's left pane (PLAN §6.2 step 5): the source photo, zoomable and
/// pannable, with a clickable highlighted region per detected spine. Selecting or
/// hovering a row highlights its `tileRect`; clicking a region selects the row.
struct PhotoScanPhotoPane: View {
    @Bindable var model: PhotoScanModel
    @Binding var hoveredRowID: UUID?

    @State private var loaded: LoadedPhoto?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipped()
            controls
        }
        .task(id: model.selectedPhotoName) { await loadSelectedPhoto() }
    }

    @ViewBuilder private var content: some View {
        if let loaded, let photo = model.selectedPhotoName {
            GeometryReader { geo in
                let fit = Self.aspectFit(loaded.pixelSize, in: geo.size)
                let scale = fit.width / max(1, loaded.pixelSize.width)
                ZStack(alignment: .topLeading) {
                    loaded.image
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                    ForEach(model.rows(onPhoto: photo)) { row in
                        regionOverlay(row, scale: scale)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .scaleEffect(zoom)
                .offset(pan)
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom = min(5, max(1, $0.magnification)) }
                )
                .simultaneousGesture(
                    DragGesture().onChanged { pan = $0.translation }
                )
            }
        } else {
            ContentUnavailableView("No photo", systemImage: "photo")
        }
    }

    private func regionOverlay(_ row: ScanReviewRow, scale: CGFloat) -> some View {
        let rect = row.item.tileRect
        let isActive = model.selectedRowID == row.id || hoveredRowID == row.id
        return RoundedRectangle(cornerRadius: 3)
            .stroke(isActive ? Color.accentColor : Color.yellow.opacity(0.5),
                    lineWidth: isActive ? 2.5 : 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(isActive ? 0.18 : 0))
            )
            .frame(width: CGFloat(rect.width) * scale, height: CGFloat(rect.height) * scale)
            .offset(x: CGFloat(rect.x) * scale, y: CGFloat(rect.y) * scale)
            .onTapGesture { model.selectRow(row.id) }
            .onHover { hoveredRowID = $0 ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID) }
    }

    private var controls: some View {
        HStack {
            if let name = model.selectedPhotoName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { zoom = min(5, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Button("Reset") { withAnimation { zoom = 1; pan = .zero } }
                .disabled(zoom == 1 && pan == .zero)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    // MARK: Loading

    private func loadSelectedPhoto() async {
        guard let name = model.selectedPhotoName else { loaded = nil; return }
        if loaded?.name == name { return }
        zoom = 1; pan = .zero
        guard let url = model.photoURL(named: name) else { loaded = nil; return }
        let result = await Task.detached(priority: .userInitiated) { LoadedPhoto.load(name: name, url: url) }.value
        loaded = result
    }

    static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// A decoded photo plus its pixel dimensions (for scaling the overlay).
struct LoadedPhoto: Equatable {
    let name: String
    let image: Image
    let pixelSize: CGSize

    static func == (lhs: LoadedPhoto, rhs: LoadedPhoto) -> Bool { lhs.name == rhs.name }

    static func load(name: String, url: URL) -> LoadedPhoto? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        #if canImport(AppKit)
        let image = Image(nsImage: NSImage(cgImage: cgImage, size: size))
        #else
        let image = Image(decorative: cgImage, scale: 1)
        #endif
        return LoadedPhoto(name: name, image: image, pixelSize: size)
    }
}
