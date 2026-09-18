import SwiftUI

/// A small "Add game manually" sheet — the stop-gap until the real Quick Add
/// palette lands (another lane, built against IGDB). Deliberately self-contained
/// and presentational-logic-free: all the logic is in ``ManualAddModel`` with a
/// testable ``ManualAddModel/makeDraft()``, so the Quick Add lane can absorb this
/// as its "Create '…' manually" row (PLAN §6.1).
@MainActor
@Observable
final class ManualAddModel {
    var title: String = ""
    var platformID: String
    var owned: Bool = true
    var format: ProductFormat = .physical
    var played: Bool = false
    var yearText: String = ""
    /// Optional tier letter (S…F), or nil for none.
    var tierLetter: String?

    let platforms: [PlatformInfo]
    let tiers: [TierInfo]

    init(
        platforms: [PlatformInfo] = PlatformLabels.all,
        tiers: [TierInfo] = TierInfo.defaultTiers,
        defaultPlatform: String? = nil
    ) {
        self.platforms = platforms
        self.tiers = tiers
        if let defaultPlatform, platforms.contains(where: { $0.id == defaultPlatform }) {
            self.platformID = defaultPlatform
        } else {
            self.platformID = platforms.first?.id ?? ""
        }
    }

    /// True when the draft has the minimum needed (a title and a platform).
    var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !platformID.isEmpty
    }

    /// Build the store draft, or nil when required fields are missing. A tier
    /// implies played (the store enforces it too); an empty/garbage year is
    /// dropped rather than guessed.
    func makeDraft() -> GameDraft? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !platformID.isEmpty else { return nil }
        let year = Int(yearText.trimmingCharacters(in: .whitespaces))
        let tierID = tierLetter.flatMap { letter in tiers.first { $0.letter == letter }?.id }
        return GameDraft(
            title: trimmed,
            year: year,
            platformIDs: [platformID],
            owned: owned,
            played: played,
            tierID: tierID,
            format: format,
            source: .manual
        )
    }
}

struct ManualAddSheet: View {
    @State var model: ManualAddModel
    /// Called with a valid draft; the caller performs the store write.
    var onAdd: (GameDraft) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add game manually")
                .font(.title3.bold())
                .padding([.top, .horizontal], 20)

            Form {
                Section {
                    TextField("Title", text: $model.title)
                    Picker("Platform", selection: $model.platformID) {
                        ForEach(model.platforms) { platform in
                            Text(platform.name).tag(platform.id)
                        }
                    }
                    TextField("Year (optional)", text: $model.yearText)
                        .frame(maxWidth: 120)
                }

                Section {
                    Toggle("Owned", isOn: $model.owned)
                    if model.owned {
                        Picker("Format", selection: $model.format) {
                            ForEach(ProductFormat.allCases, id: \.self) { format in
                                Text(format.rawValue.capitalized).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Played", isOn: $model.played)
                }

                Section("Tier (optional)") {
                    Picker("Tier", selection: $model.tierLetter) {
                        Text("None").tag(String?.none)
                        ForEach(model.tiers) { tier in
                            Text("\(tier.letter) · \(tier.label)").tag(String?.some(tier.letter))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let draft = model.makeDraft() { onAdd(draft) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
            .padding(20)
        }
        .frame(width: 420)
    }
}

#if DEBUG
#Preview("Manual add") {
    ManualAddSheet(
        model: ManualAddModel(defaultPlatform: "ps5"),
        onAdd: { _ in },
        onCancel: {}
    )
}
#endif
