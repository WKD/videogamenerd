import SwiftUI

/// The HLTB candidate picker (PLAN §5.3, D2b) — shown for an ambiguous match, single-game
/// or one-by-one inside the bulk run. The header shows the library game (title, year, and
/// "In your library: …" — its effective platforms), and each candidate row shows its HLTB
/// platforms with the ones **on one of my platforms emphasised** plus a ✓ "on your
/// platform" hint, its year, its three times, an "Open page" link, and a "Use" button.
/// Pure presentation; every write happens in a Button action (never in `body`).
struct HLTBPickerSheet: View {
    let title: String
    let year: Int?
    let candidates: [HLTBCandidate]
    /// The library game's effective platform slugs (D2b) — emphasise the overlap.
    var librarySlugs: [String] = []
    var onPick: (HLTBCandidate) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose the HowLongToBeat match").font(.headline)
                Text(year.map { "\(title) · \($0)" } ?? title)
                    .font(.callout).foregroundStyle(.secondary)
                if !librarySlugs.isEmpty {
                    Text("In your library: \(libraryPlatformLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("hltb.picker.libraryPlatforms")
                }
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(candidates) { candidate in
                        HLTBCandidateRow(candidate: candidate, librarySlugs: Set(librarySlugs)) {
                            onPick(candidate)
                        }
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

    private var libraryPlatformLabel: String {
        librarySlugs.map { PlatformLabels.short($0) }.joined(separator: ", ")
    }
}

private struct HLTBCandidateRow: View {
    let candidate: HLTBCandidate
    let librarySlugs: Set<String>
    var onUse: () -> Void

    private var overlapping: Set<String> {
        Set(HLTBPlatformMap.overlapping(candidatePlatforms: candidate.platforms, librarySlugs: librarySlugs))
    }
    private var hasPlatformMatch: Bool { !overlapping.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.name).font(.callout.weight(.medium))
                    if hasPlatformMatch {
                        Label("on your platform", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                            .help("On one of your platforms")
                            .accessibilityIdentifier("hltb.picker.platformMatch.\(candidate.id)")
                    }
                }
                if let y = candidate.releaseYear {
                    Text(String(y)).font(.caption).foregroundStyle(.secondary)
                }
                if !candidate.platforms.isEmpty {
                    platformsLine
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

    /// The candidate's HLTB platforms, with the ones I own emphasised (bold + primary).
    private var platformsLine: some View {
        let shown = candidate.platforms.prefix(6)
        return HStack(spacing: 4) {
            ForEach(Array(shown), id: \.self) { name in
                let mine = overlapping.contains(name)
                Text(name)
                    .font(.caption2.weight(mine ? .semibold : .regular))
                    .foregroundStyle(mine ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(mine ? Color.green.opacity(0.16) : Color.clear))
            }
            if candidate.platforms.count > shown.count {
                Text("+\(candidate.platforms.count - shown.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var timesLine: String { candidate.timesLine }
}

extension HLTBCandidate {
    /// "Main 2 h · Extra 3 h · 100% 5 h" for a picker / Find row; a Main-Story-only entry
    /// says so ("Main Story only (2 reports) — used as main"), matching what a pick writes
    /// (``HLTBCandidate/mappedTimes``, wave 21 D1).
    var timesLine: String {
        var parts: [String] = []
        if let s = mainSeconds { parts.append("Main \(PlaytimeParser.formatApprox(seconds: s))") }
        if let s = mainExtraSeconds { parts.append("Extra \(PlaytimeParser.formatApprox(seconds: s))") }
        if let s = completionistSeconds { parts.append("100% \(PlaytimeParser.formatApprox(seconds: s))") }
        let mapped = mappedTimes
        if mapped.mainStoryUsedForMain {
            parts.append("Main Story only\(Self.reportsSuffix(mainCount)) — used as main")
        } else if mapped.allStylesUsedForMain, let s = mapped.normally {
            parts.append("All styles \(PlaytimeParser.formatApprox(seconds: s)) — used as main")
        }
        return parts.joined(separator: " · ")
    }

    /// " (2 reports)" / " (1 report)" / "" when HLTB gave no count.
    static func reportsSuffix(_ count: Int?) -> String {
        guard let count, count > 0 else { return "" }
        return " (\(count) report\(count == 1 ? "" : "s"))"
    }
}
