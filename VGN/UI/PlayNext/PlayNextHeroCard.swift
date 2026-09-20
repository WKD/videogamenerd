import SwiftUI

// MARK: - Match strength pill

/// The strong / fair / weak evidence badge (PLAN §7b "match strength").
struct MatchStrengthPill: View {
    let strength: MatchStrength

    private var color: Color {
        switch strength {
        case .strong: return .green
        case .fair: return .orange
        case .weak: return .secondary
        }
    }

    var body: some View {
        Text(strength.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .accessibilityLabel("Match strength: \(strength.label)")
    }
}

// MARK: - Platform / format line

/// "PS4 · Physical" with a ROM badge (PLAN §7b "the platform/format I own it on").
struct PlatformFormatLine: View {
    let platformIDs: [String]
    let formats: [ProductFormat]
    var status: PlayStatus?

    var body: some View {
        HStack(spacing: 6) {
            if let slug = platformIDs.first {
                Text(PlatformLabels.short(slug)).fontWeight(.medium)
            }
            if let format = formats.first(where: { $0 != .rom }) ?? formats.first, format != .rom {
                Text("·").foregroundStyle(.tertiary)
                Text(format.label)
            }
            if formats.contains(.rom) {
                Text("ROM")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            }
            if let status {
                Text("·").foregroundStyle(.tertiary)
                Text(status.label).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Reasons

/// The 2–3 plain-words reasons under a suggestion (Markdown bold rendered).
struct ReasonsList: View {
    let sentences: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                Label {
                    reasonText(sentence)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint.opacity(0.7))
                        .font(.caption2)
                }
                .font(.callout)
            }
        }
    }
}

/// Render a reason string's Markdown bold spans as a `Text`.
func reasonText(_ sentence: String) -> Text {
    if let attributed = try? AttributedString(markdown: sentence) {
        return Text(attributed)
    }
    return Text(sentence)
}

// MARK: - Estimate vs bracket bar

/// The estimate-vs-bracket bar (PLAN §7b): the bracket shown as a band, the estimate
/// as a marker, and — for a game in progress — the remaining time versus the full
/// estimate.
struct EstimateBracketBar: View {
    let estimateSeconds: Int?
    let fullEstimateSeconds: Int?
    let bracket: TimeBracket
    var status: PlayStatus?

    private var axisMax: Double {
        let candidates = [estimateSeconds, fullEstimateSeconds, bracket.upperSeconds, bracket.lowerSeconds]
            .compactMap { $0 }
        return max(Double(candidates.max() ?? 3600) * 1.25, 3600)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let bandStart = Double(bracket.lowerSeconds ?? 0) / axisMax
                let bandEnd = Double(bracket.upperSeconds ?? Int(axisMax)) / axisMax
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    // Bracket band.
                    Capsule().fill(.tint.opacity(0.28))
                        .frame(width: max(2, w * (bandEnd - bandStart)), height: 8)
                        .offset(x: w * bandStart)
                    // Full-estimate ghost (playing games).
                    if let full = fullEstimateSeconds, status == .playing, full != estimateSeconds {
                        marker(at: Double(full) / axisMax, in: w, color: .secondary.opacity(0.5), height: 12)
                    }
                    // The estimate / remaining marker.
                    if let est = estimateSeconds {
                        marker(at: Double(est) / axisMax, in: w, color: .primary, height: 16)
                    }
                }
            }
            .frame(height: 16)

            HStack(spacing: 6) {
                if let est = estimateSeconds {
                    Text(status == .playing ? "\(PlaytimeParser.formatApprox(seconds: est)) left"
                                            : PlaytimeParser.formatApprox(seconds: est))
                        .fontWeight(.medium)
                } else {
                    Text("Unknown length")
                }
                Text("·").foregroundStyle(.tertiary)
                Text(bracket.label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func marker(at fraction: Double, in width: CGFloat, color: Color, height: CGFloat) -> some View {
        let x = width * min(max(fraction, 0), 1)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(color)
            .frame(width: 3, height: height)
            .offset(x: x - 1.5)
    }
}

// MARK: - Hero card

/// The big hero pick (PLAN §7b): cover, title/year, platform/format, the
/// estimate-vs-bracket bar, match strength, reasons, and the actions.
struct PlayNextHeroCard: View {
    let suggestion: PlayNextSuggestion
    let sentences: [String]
    let bracket: TimeBracket
    let loader: any CoverLoading
    var isSelected: Bool = false
    var onStart: () -> Void
    var onNot: () -> Void
    var onNever: () -> Void
    var onInspect: () -> Void
    /// Opens a URL in the browser; the "Open on IGDB" button shows only when this and the
    /// game's IGDB page URL are both available.
    var openURL: (@MainActor (URL) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            RankingCoverView(title: suggestion.title, coverFile: suggestion.coverFile,
                             platformID: suggestion.platformIDs.first, loader: loader)
                .frame(width: 150, height: 200)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(suggestion.title).font(.title2.weight(.bold))
                    if let year = suggestion.year {
                        Text(String(year)).font(.title3).foregroundStyle(.secondary)
                    }
                    MatchStrengthPill(strength: suggestion.matchStrength)
                }
                PlatformFormatLine(platformIDs: suggestion.platformIDs,
                                   formats: suggestion.formats, status: suggestion.status)

                EstimateBracketBar(estimateSeconds: suggestion.estimateSeconds,
                                   fullEstimateSeconds: suggestion.fullEstimateSeconds,
                                   bracket: bracket, status: suggestion.status)
                    .frame(maxWidth: 340)

                if !sentences.isEmpty { ReasonsList(sentences: sentences).padding(.top, 2) }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button(action: onStart) {
                        Label("Start playing", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])

                    Button("Not this one", action: onNot)
                    Button("Never", role: .destructive, action: onNever)
                    Button {
                        onInspect()
                    } label: {
                        Label("Inspect", systemImage: "sidebar.right")
                    }
                    .labelStyle(.iconOnly)
                    .help("Open in inspector (⌘I)")

                    if let url = IGDBWebLink.pageURL(igdbID: suggestion.igdbID, title: suggestion.title),
                       let openURL {
                        Button { openURL(url) } label: {
                            Label("Open on IGDB", systemImage: "arrow.up.right.square")
                        }
                        .labelStyle(.iconOnly)
                        .help("Open on IGDB")
                        .accessibilityLabel("Open \(suggestion.title) on IGDB")
                        .accessibilityIdentifier("playnext.openIGDB.\(suggestion.id)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

// MARK: - Alternative card

/// A compact alternative (PLAN §7b "up to 4 alternatives") with the same actions.
struct PlayNextAlternativeCard: View {
    let suggestion: PlayNextSuggestion
    let sentences: [String]
    let bracket: TimeBracket
    let loader: any CoverLoading
    var isSelected: Bool = false
    var claudeBadge: String?
    var onStart: () -> Void
    var onNot: () -> Void
    var onNever: () -> Void
    var onInspect: () -> Void
    var openURL: (@MainActor (URL) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RankingCoverView(title: suggestion.title, coverFile: suggestion.coverFile,
                             platformID: suggestion.platformIDs.first, loader: loader)
                .frame(height: 150)

            HStack(spacing: 6) {
                Text(suggestion.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                MatchStrengthPill(strength: suggestion.matchStrength)
            }
            PlatformFormatLine(platformIDs: suggestion.platformIDs,
                               formats: suggestion.formats, status: suggestion.status)
            if let estimate = suggestion.estimateSeconds {
                Text(suggestion.status == .playing
                     ? "\(PlaytimeParser.formatApprox(seconds: estimate)) left"
                     : PlaytimeParser.formatApprox(seconds: estimate))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let first = sentences.first {
                reasonText(first).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            HStack(spacing: 6) {
                Button(action: onStart) { Image(systemName: "play.fill") }
                    .help("Start playing")
                Button(action: onNot) { Image(systemName: "clock.arrow.circlepath") }
                    .help("Not this one")
                Button(action: onInspect) { Image(systemName: "sidebar.right") }
                    .help("Inspect (⌘I)")
                if let url = IGDBWebLink.pageURL(igdbID: suggestion.igdbID, title: suggestion.title),
                   let openURL {
                    Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .help("Open on IGDB")
                        .accessibilityLabel("Open \(suggestion.title) on IGDB")
                        .accessibilityIdentifier("playnext.openIGDB.\(suggestion.id)")
                }
                Menu {
                    Button("Never", role: .destructive, action: onNever)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(10)
        .frame(width: 190)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(alignment: .topLeading) {
            if let badge = claudeBadge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
    }
}
