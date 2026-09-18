import SwiftUI

/// Choose a platform + format when marking a game owned needs a decision
/// (PLAN §8: picker limited to the game's platforms, "Other…" reveals all,
/// format from `ProductFormat.allCases`).
struct OwnershipPickerSheet: View {
    let request: OwnershipRequest
    let onClose: () -> Void

    @State private var showAllPlatforms = false
    @State private var platformID: String
    @State private var format: ProductFormat = .physical

    init(request: OwnershipRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _platformID = State(initialValue: request.gamePlatforms.first?.id
                            ?? request.allPlatforms.first?.id ?? "")
        _showAllPlatforms = State(initialValue: request.gamePlatforms.isEmpty)
    }

    private var platformChoices: [PlatformInfo] {
        showAllPlatforms || request.gamePlatforms.isEmpty
            ? request.allPlatforms
            : request.gamePlatforms
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add a copy")
                .font(.title3.bold())
                .padding([.top, .horizontal], 20)
            Text(request.title)
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            Form {
                Picker("Platform", selection: $platformID) {
                    ForEach(platformChoices) { Text($0.name).tag($0.id) }
                }
                if !request.gamePlatforms.isEmpty {
                    Toggle("Show all platforms (Other…)", isOn: $showAllPlatforms)
                }
                Picker("Format", selection: $format) {
                    ForEach(ProductFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.capitalized).tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Copy") {
                    request.perform(platformID, format)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(platformID.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 380)
    }
}

/// Choose which owned copies to remove (PLAN §8). Compilation copies warn that
/// the whole compilation is affected and list its member games.
struct CopyRemovalSheet: View {
    let request: CopyRemovalRequest
    let onClose: () -> Void

    @State private var selected: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remove copies")
                .font(.title3.bold())
                .padding([.top, .horizontal], 20)
            Text(request.title)
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            Form {
                ForEach(request.copies) { copy in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(copy.label, isOn: Binding(
                            get: { selected.contains(copy.productID) },
                            set: { on in
                                if on { selected.insert(copy.productID) }
                                else { selected.remove(copy.productID) }
                            }
                        ))
                        if copy.isCompilation {
                            Label(
                                "Removing this un-owns the whole compilation: "
                                    + copy.compilationMembers.joined(separator: ", "),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    request.perform(Array(selected))
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 400)
        .onAppear {
            // A single copy is pre-checked for a one-click removal.
            if request.copies.count == 1, let only = request.copies.first {
                selected = [only.productID]
            }
        }
    }
}

/// "Group as compilation…" from a multi-selection (PLAN §8): name the product,
/// pick the platform + format, and optionally merge each game's existing single
/// copy on that platform into it.
struct GroupCompilationSheet: View {
    let request: GroupCompilationRequest
    let onClose: () -> Void

    @State private var title: String = ""
    @State private var platformID: String
    @State private var format: ProductFormat = .physical
    @State private var mergeSingles = true

    init(request: GroupCompilationRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _platformID = State(initialValue: request.platforms.first?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Group as compilation")
                .font(.title3.bold())
                .padding([.top, .horizontal], 20)
            Text("^[\(request.games.count) game](inflect: true) → one product")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20)

            Form {
                TextField("Title", text: $title, prompt: Text("e.g. The ICO & Shadow of the Colossus Collection"))
                Picker("Platform", selection: $platformID) {
                    ForEach(request.platforms) { Text($0.name).tag($0.id) }
                }
                Picker("Format", selection: $format) {
                    ForEach(ProductFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Merge existing single copies on this platform", isOn: $mergeSingles)
                Section {
                    ForEach(request.games, id: \.id) { game in
                        Text(game.title).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Group") {
                    request.perform(title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    platformID, format, mergeSingles)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(platformID.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 420)
    }
}
