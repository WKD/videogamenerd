import SwiftUI

/// The ask-once "Mark N Games as Owned" sheet (owner decision 2026-09-19, PLAN §8).
/// One format picker for the whole batch; ambiguous games (several platforms) are
/// listed first with their own platform popup so the owner can fix them in place;
/// single-platform games collapse into a disclosure for big batches. Already-owned
/// games are reported, not shown. Confirm writes every copy in one transaction.
struct BatchOwnershipSheet: View {
    @Bindable var model: BatchOwnershipModel
    let onClose: () -> Void

    @State private var showSimple = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A string literal so SwiftUI applies the `inflect:` grammar agreement
            // ("1 Game" / "4 Games"); `model.title` is a runtime String and `Text(String)`
            // renders verbatim, which leaked the raw `^[…](inflect:)` markup.
            Text("Mark ^[\(model.rows.count) Game](inflect: true) as Owned")
                .font(.title3.bold())
                .padding([.top, .horizontal], 20)
            summary
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 2)

            Form {
                Picker("Format", selection: $model.format) {
                    ForEach(ProductFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if !model.ambiguousRows.isEmpty {
                    Section("Choose a platform") {
                        ForEach(model.ambiguousRows) { row in
                            Picker(row.title, selection: platformBinding(row)) {
                                ForEach(model.options(for: row)) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                }

                if !model.simpleRows.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showSimple) {
                            ForEach(model.simpleRows) { row in
                                HStack {
                                    Text(row.title)
                                    Spacer()
                                    Text(model.platformName(row.platformID))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        } label: {
                            Text("^[\(model.simpleRows.count) game](inflect: true) on its primary platform")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Mark Owned") {
                    model.confirm()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    // "3 games · 2 already owned — unchanged". Each piece is a string LITERAL so the
    // `inflect:` grammar agreement is applied — joining runtime Strings and rendering the
    // result verbatim leaked the raw `^[…](inflect:)` markup. Extra skips only when present.
    private var summary: Text {
        var text = Text("^[\(model.rows.count) game](inflect: true) to mark owned")
        if model.alreadyOwnedCount > 0 {
            text = text + Text(" · \(model.alreadyOwnedCount) already owned — unchanged")
        }
        if model.noPlatformCount > 0 {
            text = text + Text(" · ^[\(model.noPlatformCount) game](inflect: true) without a platform — skipped")
        }
        return text
    }

    private func platformBinding(_ row: BatchOwnershipRow) -> Binding<String> {
        Binding(
            get: { model.rows.first { $0.gameID == row.gameID }?.platformID ?? row.platformID },
            set: { model.setPlatform($0, for: row.gameID) }
        )
    }
}

#if DEBUG
#Preview("Batch owned — mixed") {
    let games = [
        GameSummary(id: 1, title: "Elden Ring", owned: false, platformIDs: ["ps5", "ps4", "pc"]),
        GameSummary(id: 2, title: "Hades II", owned: false, platformIDs: ["switch", "pc"]),
        GameSummary(id: 3, title: "Celeste", owned: false, platformIDs: ["switch"]),
        GameSummary(id: 4, title: "Hollow Knight", owned: false, platformIDs: ["pc"]),
        GameSummary(id: 5, title: "Tunic", owned: true, platformIDs: ["pc"]),
    ]
    return BatchOwnershipSheet(
        model: BatchOwnershipModel(games: games, allPlatforms: PlatformLabels.all,
                                   preferences: InMemoryBatchOwnershipPreferences(),
                                   onConfirm: { _ in }),
        onClose: {})
}
#endif
