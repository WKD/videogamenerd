import SwiftUI

/// The "From the vault" row shown in Play Next below the regular picks (PLAN §16, replacing
/// the Batocera-only Discover row). Never-played Batocera ROMs and matched PS Plus entries,
/// scored by the owner's taste (``DiscoverScorer``), rotated weekly. Reads the injected
/// ``BatoceraEnvironment``; renders nothing when the vault is empty or Play Next has "not
/// enough data" (no ranked games).
struct DiscoverRowView: View {
    @Environment(\.batoceraEnvironment) private var env
    @State private var model: DiscoverModel?

    var body: some View {
        Group {
            if let model, model.isVisible {
                content(model)
            }
        }
        .task {
            guard model == nil, let env else { return }
            let m = DiscoverModel(backend: env.discover, thumbnails: env.thumbnails)
            model = m
            m.load()
        }
    }

    @ViewBuilder
    private func content(_ model: DiscoverModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("From the vault", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Text("within reach · your taste").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.shuffle()
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .controlSize(.small)
                .accessibilityIdentifier("discover.shuffle")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.items) { item in
                        DiscoverCardView(
                            item: item, loader: model.thumbnails,
                            onAdd: { env?.addToLibrary?([item.entry.id]) },
                            onNotInterested: { model.notInterested(item.entry) },
                            onShowInCatalogue: { env?.showCatalogue?() })
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }
}

/// One Discover card (PLAN §15): thumbnail, title, system, year, genre, the taste reason(s),
/// ★ rating, and the Add to Library… / Not Interested / Show in Catalogue actions.
struct DiscoverCardView: View {
    let item: DiscoverItem
    let loader: BatoceraThumbnailLoader?
    let onAdd: () -> Void
    let onNotInterested: () -> Void
    let onShowInCatalogue: () -> Void

    private var entry: RomCatalogEntry { item.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                RomCatalogThumb(entry: entry, loader: loader, width: 52, height: 68)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.subheadline).bold().lineLimit(2)
                    HStack(spacing: 5) {
                        Text(systemLabel)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                        if entry.vaultSource == .psn {
                            Text("+ PS Plus")
                                .font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.blue.opacity(0.2), in: Capsule())
                        }
                        if let year = entry.releaseYear { Text(String(year)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let rating = entry.crowdRating0to100 {
                        Label(String(format: "%.0f", rating), systemImage: "star.fill")
                            .font(.caption2).foregroundStyle(.yellow).labelStyle(.titleAndIcon)
                    }
                }
            }
            if let genre = entry.genre, !genre.isEmpty {
                Text(genre).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(Array(item.sentences.enumerated()), id: \.offset) { _, sentence in
                Text(reasonText(sentence)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button("Add…") { onAdd() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("discover.add")
                Menu {
                    Button("Not Interested") { onNotInterested() }
                    Button("Show in the Vault") { onShowInCatalogue() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(10)
        .frame(width: 210, height: 190, alignment: .topLeading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.15)))
    }

    private var systemLabel: String {
        // A PS Plus entry's `system` is already a VGN platform slug (PLAN §16).
        if entry.vaultSource == .psn { return PlatformLabels.short(entry.system) }
        if let slug = BatoceraSystems.platformSlug(for: entry.system) { return PlatformLabels.short(slug) }
        return entry.system
    }

    /// Render the reason's Markdown bold ("**Elden Ring** (S)").
    private func reasonText(_ sentence: String) -> AttributedString {
        (try? AttributedString(markdown: sentence)) ?? AttributedString(sentence)
    }
}
