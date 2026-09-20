import SwiftUI

/// The link / change-match search sheet (PLAN §5.1): a prefilled, freely-editable
/// search field, an "Only <platform>" toggle, live IGDB results (cover, title, year,
/// platforms, type badge, an "already in your library" marker), keyboard navigation,
/// double-click to choose, and empty / error / not-configured states.
struct IGDBLinkSheet: View {
    @Bindable var model: IGDBLinkModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            resultsArea
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task { model.start(); searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.sheetTitle).font(.headline)
                Spacer()
                if !model.platformSlugs.isEmpty {
                    ForEach(model.platformSlugs, id: \.self) { PlatformChip(slug: $0) }
                }
                if let year = model.year { Text(String(year)).foregroundStyle(.secondary) }
            }
            Text("Current: \(model.currentTitle)").font(.caption).foregroundStyle(.secondary)

            TextField("Search IGDB…", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { model.chooseSelected() }
                .accessibilityIdentifier("reconcile.searchField")

            if model.canConstrainPlatform {
                Toggle(model.platformToggleLabel, isOn: $model.onlyThisPlatform)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsArea: some View {
        switch model.phase {
        case .idle:
            centered("Type at least 3 characters to search.", systemImage: "magnifyingglass")
        case .searching:
            VStack { ProgressView().controlSize(.small); Text("Searching…").font(.caption).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            centered("No IGDB matches. Try a different title (e.g. the English name).",
                     systemImage: "questionmark.circle")
        case .error:
            centered("Couldn't reach IGDB. Check your connection and try again.",
                     systemImage: "exclamationmark.triangle")
        case .notConfigured:
            notConfigured
        case .results:
            resultList
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, row in
                    IGDBLinkRowView(row: row, isSelected: index == model.selectedIndex)
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.choose(row) }
                        .onTapGesture { model.selectedIndex = index }
                        .listRowBackground(index == model.selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .listStyle(.inset)
            .onKeyPress(.downArrow) { model.moveSelection(by: 1); scrollTo(proxy); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(by: -1); scrollTo(proxy); return .handled }
            .onKeyPress(.return) { model.chooseSelected(); return .handled }
        }
    }

    private func scrollTo(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(model.selectedIndex, anchor: .center) }
    }

    private var notConfigured: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("IGDB isn’t configured").font(.headline)
            Text("Add your Twitch (IGDB) client id and secret in Settings to search and link games.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings…") }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered(_ text: String, systemImage: String) -> some View {
        ContentUnavailableView(text, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            let selected = model.results.indices.contains(model.selectedIndex) ? model.results[model.selectedIndex] : nil
            if let selected, let url = IGDBWebLink.searchURL(name: selected.result.name) {
                Link(destination: url) { Label("Open on IGDB", systemImage: "arrow.up.forward.square") }
                    .font(.caption)
            }
            Spacer()
            Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            Button(model.isLinked ? "Change Match" : "Link") { model.chooseSelected() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedIsChoosable == false)
                .accessibilityIdentifier("reconcile.linkButton")
        }
        .padding(16)
    }

    private var selectedIsChoosable: Bool {
        guard model.results.indices.contains(model.selectedIndex) else { return false }
        return model.results[model.selectedIndex].isChoosable
    }

}

/// One IGDB search result row in the link sheet.
private struct IGDBLinkRowView: View {
    let row: IGDBLinkResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.result.name).font(.body).lineLimit(1)
                    if let year = row.result.releaseYear {
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let badge = typeBadge { chip(badge, tint: .secondary) }
                }
                if !row.result.platformSlugs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(row.result.platformSlugs.prefix(6), id: \.self) { slug in
                            Text(PlatformLabels.short(slug)).font(.caption2)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                if row.alreadyInLibrary {
                    Label("Already in your library — choosing this merges the two",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                } else if row.isBundle {
                    Label("Bundle — links as a compilation (expands into its games)",
                          systemImage: "square.stack.3d.up")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(row.isChoosable ? 1 : 0.5)
    }

    private var typeBadge: String? {
        switch row.result.gameType {
        case .bundle, .pack: return "Bundle"
        case .remake: return "Remake"
        case .remaster: return "Remaster"
        case .port: return "Port"
        case .expandedGame: return "Expanded"
        default: return nil
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
    }

    @ViewBuilder
    private var cover: some View {
        Group {
            if let imageID = row.result.coverImageID,
               let url = IGDBImageURL.cover(imageID: imageID, size: .coverSmall) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary).font(.caption2))
    }
}
