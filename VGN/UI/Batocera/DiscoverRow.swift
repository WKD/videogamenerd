import SwiftUI

/// The "From the vault" row shown in Play Next below the regular picks (PLAN §16, replacing
/// the Batocera-only Discover row). Never-played Batocera ROMs and matched PS Plus entries,
/// scored by the owner's taste (``DiscoverScorer``), rotated weekly. Reads the injected
/// ``BatoceraEnvironment``; renders nothing when the vault is empty or Play Next has "not
/// enough data" (no ranked games).
struct DiscoverRowView: View {
    /// The Play Next bracket the vault is fitted to and the "Ask Claude" answer is keyed by.
    var bracket: TimeBracket? = nil

    @Environment(\.batoceraEnvironment) private var env
    /// The same second-opinion provider as the regular picks (PLAN §7b) — nil ⇒ no button.
    @Environment(\.playNextEnvironment) private var playNextEnv
    @State private var model: DiscoverModel?

    var body: some View {
        Group {
            if let model, model.isVisible {
                content(model)
            }
        }
        .task {
            guard model == nil, let env else { return }
            let m = DiscoverModel(backend: env.discover, thumbnails: env.thumbnails,
                                  openURL: env.openURL, bracket: bracket,
                                  secondOpinion: playNextEnv?.secondOpinion)
            model = m
            m.load()
        }
        .onChange(of: bracket) { _, newValue in model?.setBracket(newValue) }
    }

    @ViewBuilder
    private func content(_ model: DiscoverModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("From the vault", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Text("within reach · your taste").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.canAskClaude {
                    Button {
                        model.askClaude()
                    } label: {
                        Label("Ask Claude", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .disabled(model.secondOpinionState == .asking)
                    .accessibilityIdentifier("discover.askClaude")
                    .help("Ask Claude — sends only your tier list and this vault shortlist, nothing else")
                }
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
                            onShowInCatalogue: { env?.showCatalogue?() },
                            onOpenIGDB: item.entry.igdbID != nil
                                ? { model.openIGDB(item.entry) } : nil)
                    }
                }
                .padding(.vertical, 2)
            }
            if model.secondOpinionActive {
                DiscoverClaudePanel(model: model)
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
    /// Opens the entry's IGDB page (D7); nil when the entry has no `igdb_id` (no button then).
    var onOpenIGDB: (() -> Void)? = nil

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
                // A quiet "Open on IGDB" button, only for matched entries (D7). Never steals the
                // card's primary click; never shown (nor disabled) without an id.
                if let onOpenIGDB {
                    Button { onOpenIGDB() } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .controlSize(.small).buttonStyle(.borderless)
                    .help("Open on IGDB")
                    .accessibilityLabel("Open \(entry.name) on IGDB")
                    .accessibilityIdentifier("discover.openIGDB")
                }
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

    private var systemLabel: String { DiscoverSecondOpinion.systemLabel(for: entry) }

    /// Render the reason's Markdown bold ("**Elden Ring** (S)").
    private func reasonText(_ sentence: String) -> AttributedString {
        (try? AttributedString(markdown: sentence)) ?? AttributedString(sentence)
    }
}
