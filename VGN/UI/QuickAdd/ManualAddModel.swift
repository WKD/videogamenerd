import SwiftUI

/// The model behind Quick Add's "Create '…' manually" path (PLAN §6.1). Its
/// testable ``makeDraft()`` turns the entered fields into a ``GameDraft``.
///
/// (The standalone `ManualAddSheet` view was a stop-gap that Quick Add absorbed;
/// it has been removed — this model is the surviving, used part.)
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
