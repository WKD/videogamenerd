import SwiftUI

/// The HLTB candidate picker (PLAN §5.3) — shown for an ambiguous match, single-game
/// or one-by-one inside the bulk run. Each row: name, year, platforms, the three
/// times, an "Open page" link, and a "Use" button. Pure presentation; every write
/// happens in a Button action (never in `body`).
struct HLTBPickerSheet: View {
    let title: String
    let year: Int?
    let candidates: [HLTBCandidate]
    var onPick: (HLTBCandidate) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose the HowLongToBeat match").font(.headline)
                Text(year.map { "\(title) · \($0)" } ?? title)
                    .font(.callout).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(candidates) { candidate in
                        HLTBCandidateRow(candidate: candidate) { onPick(candidate) }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("hltb.picker.cancel")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityIdentifier("hltb.picker")
    }
}

private struct HLTBCandidateRow: View {
    let candidate: HLTBCandidate
    var onUse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name).font(.callout.weight(.medium))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                if !timesLine.isEmpty {
                    Text(timesLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let url = HowLongToBeatLink.gameURL(id: candidate.id) {
                    Link("Open page", destination: url).font(.caption2)
                }
            }
            Spacer(minLength: 8)
            Button("Use") { onUse() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("hltb.picker.use.\(candidate.id)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let y = candidate.releaseYear { parts.append(String(y)) }
        if !candidate.platforms.isEmpty { parts.append(candidate.platforms.prefix(4).joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var timesLine: String {
        var parts: [String] = []
        if let s = candidate.mainSeconds { parts.append("Main \(PlaytimeParser.formatApprox(seconds: s))") }
        if let s = candidate.mainExtraSeconds { parts.append("Extra \(PlaytimeParser.formatApprox(seconds: s))") }
        if let s = candidate.completionistSeconds { parts.append("100% \(PlaytimeParser.formatApprox(seconds: s))") }
        return parts.joined(separator: " · ")
    }
}
