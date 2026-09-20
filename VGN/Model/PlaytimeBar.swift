import Foundation

/// The one-line "me vs. average" summary (owner 2026-09-20): my formatted time, the "N % of
/// <estimate>" comparison, and whether my time is beyond every estimate (the comparison is
/// emphasised when it is). Pure value, unit-tested without a view.
struct PlaytimeComparison: Sendable, Equatable {
    var mineText: String
    var comparison: String
    var beyond: Bool
}

/// Pure geometry for the inspector's "me vs. average" playtime bar (PLAN §6.4).
/// My playtime is a fill; the IGDB rushed / main / completionist averages are
/// markers along the same scale. Sensible when I exceed the completionist figure
/// (the scale extends to my time and the completionist marker sits below 1).
///
/// Foundation-only and deterministic, so the layout is unit-tested with no view.
struct PlaytimeBar: Sendable, Equatable {
    /// One average marker on the bar.
    struct Marker: Sendable, Equatable, Identifiable {
        var kind: Kind
        var seconds: Int
        /// Position along the bar, 0…1.
        var fraction: Double
        var id: Kind { kind }

        enum Kind: String, Sendable, CaseIterable { case rushed, main, completionist }
        var label: String {
            switch kind {
            case .rushed: return "Rushed"
            case .main: return "Main"
            case .completionist: return "Completionist"
            }
        }
    }

    /// My playtime in seconds, or nil when unknown.
    var mineSeconds: Int?
    /// My fill fraction, 0…1 (0 when unknown).
    var fillFraction: Double
    /// The average markers that have data, in ascending time order.
    var markers: [Marker]
    /// The scale's maximum in seconds (the far right of the bar).
    var scaleMaxSeconds: Int
    /// True when my time is at least the completionist estimate.
    var exceedsCompletionist: Bool

    /// True when nothing can be drawn (no mine, no averages).
    var isEmpty: Bool { mineSeconds == nil && markers.isEmpty }

    /// The one-line "me vs. average" summary under the bar (owner 2026-09-20): my time and how
    /// it compares to the nearest estimate at or above it ("62 % of main"), or, when my time
    /// exceeds every estimate, to the largest one with a "beyond 100 %" flag ("141 % of
    /// completionist"). Nil when there is nothing to compare (no time, or no averages).
    func comparisonSummary() -> PlaytimeComparison? {
        guard let mine = mineSeconds, mine > 0, !markers.isEmpty else { return nil }
        // markers are in ascending time order; the nearest estimate at/above my time, else the
        // largest (my time is beyond every estimate).
        let target = markers.first { $0.seconds >= mine } ?? markers[markers.count - 1]
        let beyond = markers.allSatisfy { $0.seconds < mine }
        let pct = Int((Double(mine) / Double(max(1, target.seconds)) * 100).rounded())
        return PlaytimeComparison(
            mineText: "You \(PlaytimeParser.format(seconds: mine))",
            comparison: "\(pct) % of \(target.label.lowercased())",
            beyond: beyond)
    }

    /// Build the bar from my time and the three IGDB averages (any may be nil).
    static func make(mineSeconds: Int?, rushed: Int?, main: Int?, completionist: Int?) -> PlaytimeBar {
        let candidates: [(Marker.Kind, Int)] = [
            (.rushed, rushed), (.main, main), (.completionist, completionist),
        ].compactMap { kind, value in value.map { (kind, $0) } }

        // Scale to the largest of everything present (min 1 to avoid /0). Adds a
        // little headroom (10%) so a marker or the fill never sits flush at the edge.
        let maxPresent = max(mineSeconds ?? 0, candidates.map(\.1).max() ?? 0, 1)
        let scaleMax = Int((Double(maxPresent) * 1.1).rounded(.up))

        let markers = candidates
            .sorted { $0.1 < $1.1 }
            .map { kind, value in
                Marker(kind: kind, seconds: value,
                       fraction: min(1, Double(value) / Double(scaleMax)))
            }
        let fill = mineSeconds.map { min(1, Double($0) / Double(scaleMax)) } ?? 0
        let exceeds = {
            guard let mine = mineSeconds, let comp = completionist else { return false }
            return mine >= comp
        }()
        return PlaytimeBar(
            mineSeconds: mineSeconds, fillFraction: fill, markers: markers,
            scaleMaxSeconds: scaleMax, exceedsCompletionist: exceeds)
    }
}
