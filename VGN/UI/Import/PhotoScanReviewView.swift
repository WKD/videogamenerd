import SwiftUI

/// The review sheet (PLAN §6.2 step 5): photo on the left (zoom/pan, tile-rect overlay),
/// the detected list on the right grouped by confidence bucket, and one "Add N games"
/// commit. Nothing is added without this step.
struct PhotoScanReviewView: View {
    @Bindable var model: PhotoScanModel
    var onClose: () -> Void = {}

    @State private var hoveredRowID: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PhotoScanPhotoPane(model: model, hoveredRowID: $hoveredRowID)
                    .frame(minWidth: 260, idealWidth: 360)
                detectedList
                    .frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .onAppear { listFocused = true }
    }

    // MARK: Detected list

    private var detectedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    ForEach(buckets, id: \.self) { bucket in
                        Section {
                            ForEach(rows(in: bucket)) { row in
                                PhotoScanRowView(
                                    model: model,
                                    row: row,
                                    isSelected: model.selectedRowID == row.id,
                                    isHovered: hoveredRowID == row.id
                                )
                                .id(row.id)
                                .onHover { hoveredRowID = $0 ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID) }
                                .onTapGesture { model.selectRow(row.id) }
                            }
                        } header: {
                            bucketHeader(bucket)
                        }
                    }
                }
                .padding(10)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .space, .return, KeyEquivalent("x")]) { press in
                handleKey(press)
            }
            .onChange(of: model.selectedRowID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .background {
                // Hidden shortcut sinks: ⌘A select-all, ⌘↩ commit.
                Button("", action: model.selectAllIncludable)
                    .keyboardShortcut("a", modifiers: .command).hidden()
                Button("", action: model.commit)
                    .keyboardShortcut(.return, modifiers: .command).hidden()
            }
        }
    }

    private func bucketHeader(_ bucket: ScanConfidenceBucket) -> some View {
        HStack {
            Text(bucket.sectionTitle).font(.headline)
            Text("\(rows(in: bucket).count)").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var footer: some View {
        HStack {
            Text("\(model.reviewRows.count) detected · \(model.committableCount) selected")
                .foregroundStyle(.secondary)
            if let error = model.commitError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Spacer()
            Button("Close") { onClose() }
            Button(model.commitButtonTitle) { model.commit() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canCommit)
                .overlay(alignment: .trailing) {
                    if model.isCommitting { ProgressView().controlSize(.small).offset(x: 22) }
                }
        }
        .padding(12)
    }

    // MARK: Buckets

    private var buckets: [ScanConfidenceBucket] {
        [.confident, .plausible, .none].filter { bucket in model.reviewRows.contains { $0.bucket == bucket } }
    }

    private func rows(in bucket: ScanConfidenceBucket) -> [ScanReviewRow] {
        model.reviewRows.filter { $0.bucket == bucket }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let option = press.modifiers.contains(.option)
        switch press.key {
        case .upArrow: option ? model.jumpBucket(-1) : model.moveSelection(by: -1)
        case .downArrow: option ? model.jumpBucket(1) : model.moveSelection(by: 1)
        case .space: model.togglePlayedSelected()
        case .return: model.toggleIncludeSelected()
        case KeyEquivalent("x"): model.toggleIncludeSelected()
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - Row

private struct PhotoScanRowView: View {
    @Bindable var model: PhotoScanModel
    let row: ScanReviewRow
    let isSelected: Bool
    let isHovered: Bool

    @State private var searching = false
    @State private var searchText = ""
    @State private var searchResults: [IGDBSearchResult] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                includeCheckbox
                CoverThumb(imageID: row.coverImageID)
                titleBlock
                Spacer(minLength: 8)
                trailingControls
            }
            if searching { searchField }
        }
        .padding(8)
        .background(background)
        .opacity(row.alreadyInLibrary ? 0.55 : 1)
        .contentShape(Rectangle())
    }

    private var includeCheckbox: some View {
        Button {
            model.setInclude(!row.include, rowID: row.id)
        } label: {
            Image(systemName: row.include ? "checkmark.square.fill" : "square")
                .foregroundStyle(row.include ? Color.accentColor : .secondary)
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .disabled(row.alreadyInLibrary)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.matchedTitle ?? row.printedTitle).bold()
                if let year = row.matchedYear { Text(String(year)).foregroundStyle(.secondary) }
                if row.isCompilation {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).help("Compilation")
                }
            }
            if row.showsPrintedTitle, row.matchedTitle != nil {
                Text("spine: \(row.printedTitle)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let label = row.alreadyInLibraryLabel {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                } else {
                    platformChip
                    formatMenu
                }
                if !row.item.editionHints.isEmpty {
                    Text(row.item.editionHints.joined(separator: ", ")).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let seen = row.seenCountLabel {
                    Text(seen).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var platformChip: some View {
        Menu {
            let matchPlatforms = row.selectedMatch?.platformSlugs ?? []
            ForEach(matchPlatforms, id: \.self) { slug in
                Button(PlatformLabels.short(slug)) { model.setPlatform(slug, rowID: row.id) }
            }
            Divider()
            Menu("All platforms") {
                ForEach(PlatformLabels.all) { platform in
                    Button(platform.name) { model.setPlatform(platform.id, rowID: row.id) }
                }
            }
        } label: {
            Text(row.platformSlug.map(PlatformLabels.short) ?? "platform?")
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .background(.tint.opacity(0.2), in: Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var formatMenu: some View {
        Menu {
            ForEach(ProductFormat.allCases, id: \.self) { format in
                Button(format.label) { model.setFormat(format, rowID: row.id) }
            }
        } label: {
            Text(row.format.label).font(.caption2).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { row.played }, set: { _ in model.togglePlayed(rowID: row.id) })) {
                Image(systemName: "gamecontroller")
            }
            .toggleStyle(.button).help("Played (space)")

            confidenceBadge
            alternativesMenu
        }
    }

    private var confidenceBadge: some View {
        Text("\(Int((row.selectedMatch?.score ?? row.item.recognitionConfidence) * 100))%")
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
    }

    private var alternativesMenu: some View {
        Menu {
            if !row.alternatives.isEmpty {
                Section("Alternatives") {
                    ForEach(Array(row.alternatives.enumerated()), id: \.offset) { _, alt in
                        Button {
                            model.chooseMatch(alt, rowID: row.id)
                        } label: {
                            Text("\(alt.name)\(alt.releaseYear.map { " (\($0))" } ?? "")")
                        }
                    }
                }
            }
            Button("Search IGDB…") { searching = true; searchText = row.printedTitle }
            if row.selectedMatch == nil {
                Button("Add via Quick Add…") { model.handToQuickAdd(rowID: row.id) }
            }
            Divider()
            Button("Not a game — ignore", role: .destructive) { model.ignoreRow(row.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Search IGDB…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }
                Button("Done") { searching = false }
            }
            ForEach(searchResults) { result in
                Button {
                    model.chooseSearchResult(result, rowID: row.id)
                    searching = false
                } label: {
                    HStack {
                        Text(result.name)
                        if let year = result.releaseYear { Text(String(year)).foregroundStyle(.secondary) }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func runSearch() {
        Task {
            searchResults = await model.searchIGDB(searchText, rowID: row.id)
        }
    }

    private var background: some ShapeStyle {
        isSelected ? AnyShapeStyle(.tint.opacity(0.18))
            : (isHovered ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear))
    }
}

// MARK: - Cover thumb

private struct CoverThumb: View {
    let imageID: String?

    var body: some View {
        Group {
            if let imageID, let url = IGDBImageURL.cover(imageID: imageID, size: .coverSmall) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 34, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary).font(.caption))
    }
}

#if DEBUG
#Preview("Scan — review") {
    PhotoScanReviewView(model: PhotoScanPreview.reviewModel())
        .frame(width: 900, height: 620)
}
#endif
