import SwiftUI

/// The compilation editor sheet (PLAN §5.1/§8): edit a product's title, platform,
/// format, edition/region; drag-reorder / remove / add members via the same
/// quick-search as Quick Add; "Fill from IGDB bundle" with a diff preview. The
/// view is a thin shell over ``CompilationEditorModel``.
struct CompilationEditorView: View {
    @Bindable var model: CompilationEditorModel
    var loader: (any CoverLoading)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailsSection
                        Divider()
                        membersSection
                        Divider()
                        addMemberSection
                        bundleSection
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 620)
        .task { await model.load() }
        .alert("Remove game?", isPresented: orphanPresented, presenting: model.orphanConfirm) { _ in
            Button("Remove from library", role: .destructive) { Task { await model.confirmOrphanRemoval() } }
            Button("Cancel", role: .cancel) { model.cancelOrphanRemoval() }
        } message: { confirm in
            Text("\u{201C}\(confirm.title)\u{201D} is not owned or played anywhere else. "
                 + "Removing it from this compilation deletes it from the library.")
        }
        .alert("Fill from IGDB bundle", isPresented: bundlePresented, presenting: model.bundleDiff) { diff in
            if !diff.isEmpty {
                Button("Add \(diff.toAdd.count)") { Task { await model.applyBundleDiff() } }
            }
            Button("Cancel", role: .cancel) { model.cancelBundleDiff() }
        } message: { diff in
            Text(bundleDiffMessage(diff))
        }
        .alert("Compilation", isPresented: errorPresented, presenting: model.errorMessage) { _ in
            Button("OK") { model.dismissError() }
        } message: { Text($0) }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isCompilation ? "Edit compilation" : "Edit product")
                    .font(.title2.bold())
                Text("^[\(model.members.count) game](inflect: true)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                Task { await model.saveDetails(); model.onClose() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.headline)
            TextField("Title", text: $model.titleText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Platform", selection: $model.platformID) {
                    ForEach(model.allPlatforms) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 220)
                Spacer()
            }
            Picker("Format", selection: $model.format) {
                ForEach(ProductFormat.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            HStack {
                TextField("Edition (optional)", text: $model.editionText)
                    .textFieldStyle(.roundedBorder)
                TextField("Region (optional)", text: $model.regionText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: Members (drag-reorder + remove)

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Members").font(.headline)
            if model.members.isEmpty {
                Text("No games yet. Add one below.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // A plain reorderable list; drag the row handles to reorder.
                List {
                    ForEach(model.members) { member in
                        HStack {
                            Text(member.title)
                            if let tier = member.tierLetter {
                                Text(tier).font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await model.removeMember(member.gameID) }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Remove from the compilation")
                        }
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(height: min(260, CGFloat(model.members.count) * 30 + 12))
                .listStyle(.inset)
            }
        }
    }

    // MARK: Add a member (quick-search)

    private var addMemberSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a game").font(.headline)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your library, then IGDB…", text: $model.query)
                    .textFieldStyle(.plain)
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

            if !model.searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.searchResults) { result in
                        Button {
                            Task { await model.addMember(result) }
                        } label: {
                            HStack {
                                Text(result.title)
                                if let year = result.year {
                                    Text(String(year)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if result.alreadyMember {
                                    Text("Added").font(.caption).foregroundStyle(.secondary)
                                } else if result.source == .local {
                                    Text("In library").font(.caption).foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(result.alreadyMember)
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.2)))
            }
        }
    }

    // MARK: Bundle

    @ViewBuilder
    private var bundleSection: some View {
        if model.igdbID != nil {
            Button {
                Task { await model.fillFromBundle() }
            } label: {
                Label("Fill from IGDB bundle…", systemImage: "square.stack.3d.down.right")
            }
            .buttonStyle(.borderless)
            .help("Re-fetch the IGDB bundle's members and add any that are missing.")
        }
    }

    private func bundleDiffMessage(_ diff: BundleDiff) -> String {
        if diff.isEmpty { return "The IGDB bundle adds nothing new." }
        let names = diff.toAdd.prefix(8).map(\.title).joined(separator: ", ")
        let more = diff.toAdd.count > 8 ? " …" : ""
        return "Add \(diff.toAdd.count) missing game(s): \(names)\(more)"
    }

    // MARK: Alert bindings

    private var orphanPresented: Binding<Bool> {
        Binding(get: { model.orphanConfirm != nil }, set: { if !$0 { model.cancelOrphanRemoval() } })
    }
    private var bundlePresented: Binding<Bool> {
        Binding(get: { model.bundleDiff != nil }, set: { if !$0 { model.cancelBundleDiff() } })
    }
    private var errorPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } })
    }
}

#if DEBUG
#Preview("Compilation editor") {
    CompilationEditorView(model: PreviewCompilationEditor.mgsLegacy())
}
#endif
