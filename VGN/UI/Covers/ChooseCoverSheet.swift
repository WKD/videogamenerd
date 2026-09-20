import SwiftUI
import UniformTypeIdentifiers

/// The "Choose Cover…" sheet (PLAN §5.2 step 4): every candidate from every provider
/// in a grid grouped by provider, plus a local "Choose File…" alternative and the
/// current cover for reference. Picking one downloads it, files it through the normal
/// cover write path, and marks it user-edited so enrichment never replaces it.
///
/// No observable state is written from `body`: selection changes happen in button /
/// tap actions, and loads happen in `.task`.
struct ChooseCoverSheet: View {
    @Bindable var model: ChooseCoverModel
    /// The current-cover preview loader (the same `vm.coverLoader`).
    let loader: any CoverLoading

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .accessibilityIdentifier("chooseCover.sheet")
        .task { await model.load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose Cover").font(.headline)
                Text(model.title).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            loadingState
        case .failed(let message):
            errorState(message)
        case .loaded(let candidates):
            if candidates.isEmpty && model.currentCoverFile == nil {
                emptyState
            } else {
                loadedGrid
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Finding covers…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load covers", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await model.load() } }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No covers found", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("No provider had box art for this game. You can still drop or choose an image file.")
        } actions: {
            Button("Choose File…") { chooseFile() }
        }
    }

    private var loadedGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let current = model.currentCoverFile {
                    section(title: "Current") {
                        CoverTile(
                            label: "In your library",
                            sublabel: nil,
                            isSelected: false,
                            isCurrent: true,
                            load: { px in await loader.thumbnail(for: current, pixelSize: px) }
                        )
                        .frame(width: 128)
                    }
                }
                ForEach(model.groups) { group in
                    section(title: group.title) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(group.candidates) { candidate in
                                candidateTile(candidate)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func section<Inner: View>(title: String, @ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            inner()
        }
    }

    private func candidateTile(_ candidate: CoverCandidate) -> some View {
        CoverTile(
            label: providerName(candidate.providerID),
            sublabel: sublabel(for: candidate),
            isSelected: model.selection == candidate.id,
            isCurrent: false,
            load: { _ in await model.preview(for: candidate, maxPixel: 256) }
        )
        // Double-click chooses immediately; single click selects. Declaring the
        // count:2 gesture first lets SwiftUI resolve the double before the single.
        .onTapGesture(count: 2) { Task { await model.use(candidate) } }
        .onTapGesture { model.selection = candidate.id }
        .accessibilityIdentifier("chooseCover.candidate")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Choose File…") { chooseFile() }
                .disabled(model.isSaving)
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Use This Cover") { Task { await model.useSelected() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selection == nil || model.isSaving)
                .accessibilityIdentifier("chooseCover.use")
        }
        .padding(16)
    }

    // MARK: Actions / labels

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Cover"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.useFile(url) }
    }

    private func providerName(_ id: String) -> String {
        switch id {
        case "igdb": return "IGDB"
        case "libretro": return "libretro"
        default: return id.capitalized
        }
    }

    private func sublabel(for candidate: CoverCandidate) -> String? {
        var parts: [String] = []
        if let kind = candidate.kind { parts.append(kind) }
        if let region = candidate.region { parts.append(region) }
        if let size = candidate.pixelSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Cover tile

/// One cover candidate (or the current cover) in the grid: an async-loaded preview
/// with a placeholder fallback, a provider label and an optional region/size line,
/// and a selection / current highlight.
private struct CoverTile: View {
    let label: String
    let sublabel: String?
    let isSelected: Bool
    let isCurrent: Bool
    /// Loads a preview at the given pixel size; `nil` shows the placeholder frame.
    let load: (CGSize) async -> CGImage?

    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image {
                    // Fill + clip to the portrait tile, exactly as the grid crops a cover,
                    // so a landscape IGDB artwork previews the way it will actually look
                    // (D1 — the owner isn't surprised by the crop).
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: isSelected || isCurrent ? 3 : 1)
            )

            VStack(spacing: 1) {
                Text(label).font(.caption).lineLimit(1)
                if let sublabel {
                    Text(sublabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(displayScale)") {
            let px = CGSize(width: 256 * displayScale, height: 341 * displayScale)
            let loaded = await load(px)
            if !Task.isCancelled { image = loaded }
        }
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isCurrent { return .secondary }
        return .clear
    }
}

#if DEBUG
/// A canned backend for previews / snapshots — no network, placeholder images.
private struct PreviewChooseCoverBackend: ChooseCoverProviding {
    let candidates: [CoverCandidate]
    func coverCandidates(forGameID id: Int64) async -> [CoverCandidate] { candidates }
    func candidateThumbnail(for candidate: CoverCandidate, maxPixel: Int) async -> sending CGImage? { nil }
    func chooseCandidate(_ candidate: CoverCandidate, forGameID id: Int64) async throws {}
    func importCoverFile(_ url: URL, forGameID id: Int64) async throws {}
}

private func previewCandidate(_ provider: String, _ region: String?, _ w: Int, _ h: Int) -> CoverCandidate {
    CoverCandidate(
        providerID: provider,
        remoteURL: URL(string: "https://example.com/\(provider)-\(region ?? "x").png")!,
        label: provider, score: 1, isConfident: true,
        region: region, pixelSize: CGSize(width: w, height: h))
}

#Preview("Choose Cover — candidates") {
    let backend = PreviewChooseCoverBackend(candidates: [
        previewCandidate("libretro", "Europe", 512, 700),
        previewCandidate("libretro", "USA", 512, 700),
        previewCandidate("libretro", "Japan", 512, 700),
        previewCandidate("igdb", nil, 528, 748),
    ])
    return ChooseCoverSheet(
        model: ChooseCoverModel(gameID: 1, title: "The Legend of Zelda: Ocarina of Time",
                                currentCoverFile: nil, backend: backend),
        loader: NoopCoverLoader())
}

#Preview("Choose Cover — empty") {
    ChooseCoverSheet(
        model: ChooseCoverModel(gameID: 1, title: "Obscure Homebrew",
                                currentCoverFile: nil,
                                backend: PreviewChooseCoverBackend(candidates: [])),
        loader: NoopCoverLoader())
}
#endif
