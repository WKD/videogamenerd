import SwiftUI

/// Pure copy + visibility for the two extra Play Next rows (PLAN §7b "Scheduled 2026-09-25",
/// wave 22) — kept free of any view so the show/hide rules are unit-tested at model level.
enum PlayNextExtraRowCopy {
    static let finishTitle = "Finish what you started"
    static let finishSubtitle = "almost there · worth another try"
    static let replayTitle = "Worth replaying"
    static let replaySubtitle = "S/A games that hold up, not played in years"

    /// The finish row shows exactly when it has cards.
    static func showsFinishRow(_ result: PlayNextResult?) -> Bool {
        !(result?.finishWhatYouStarted.isEmpty ?? true)
    }

    /// The replay row shows exactly when it has cards (its footer never shows on its own).
    static func showsReplayRow(_ result: PlayNextResult?) -> Bool {
        !(result?.replay.isEmpty ?? true)
    }

    /// The replay row's quiet footer: "12 more have no last-played date" (count only), or nil.
    static func replayFooter(undatedCount: Int) -> String? {
        guard undatedCount > 0 else { return nil }
        return undatedCount == 1
            ? "1 more has no last-played date"
            : "\(undatedCount) more have no last-played date"
    }
}

/// One extra row of Play Next cards: a title, a quiet subtitle, the cards (the same
/// ``PlayNextAlternativeCard`` the regular alternatives use — Start playing / Not this one /
/// Never / Inspect), and an optional footer. Hidden by the caller when it has no cards.
struct PlayNextExtraRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let suggestions: [PlayNextSuggestion]
    var footer: String? = nil
    let model: PlayNextModel
    let loader: any CoverLoading
    var inspect: (@MainActor (Int64) -> Void)?
    var openURL: (@MainActor (URL) -> Void)?
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(suggestions) { game in
                        PlayNextAlternativeCard(
                            suggestion: game, sentences: model.reasonSentences(for: game),
                            bracket: model.bracket, loader: loader,
                            onStart: { Task { await model.startPlaying(game) } },
                            onNot: { Task { await model.notThisOne(game) } },
                            onNever: { Task { await model.never(game) } },
                            onInspect: { inspect?(game.id) },
                            openURL: openURL)
                    }
                }
                .padding(.vertical, 2)
            }
            if let footer {
                Text(footer)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .accessibilityIdentifier("\(identifier).footer")
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
