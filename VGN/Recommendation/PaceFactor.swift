import Foundation

/// The owner's **personal pace factor** (PLAN §7b "Scheduled 2026-09-25" — the filed
/// idea "inflate the advertised times", built as specified): how much longer (or shorter)
/// the owner takes than the advertised estimates, *measured* from his own finished games.
///
/// `ratio = median over the samples of (my effective play time ÷ the matching estimate)`,
/// where the matching estimate is the **main** story for a game marked *Finished* and the
/// **completionist** time for one marked *100 %* (falling back to main when it has no
/// completionist). A sample needs a play time > 0 and a main estimate; a game whose stored
/// estimate is flagged *suspicious* (``EstimateSanity/isFlagged``, PLAN §5.3) is left out —
/// everything else counts. The median is clamped to ``range`` (0.8–2.0) and stays **1.0
/// until there are ≥ ``minSamples``** samples.
///
/// Stored nowhere: it is recomputed from the library on demand; only an optional manual
/// **override** lives in the preferences (``effective(override:)``). It multiplies the
/// personal length wherever time is used *for planning* (``PersonalLength/compute`` and its
/// SQL mirror ``LibraryQuery/lengthEstimateExpr``) and never changes a stored or displayed
/// advertised time. Pure (Foundation only).
struct PaceFactor: Hashable, Sendable {
    /// The measured factor (1.0 until ``isMeasured``), clamped to ``range``.
    var measured: Double
    /// How many finished games the measurement rests on (Settings: "based on 109 games").
    var sampleCount: Int
    /// The raw (unclamped) median, or nil with no samples — for a "your median is 2.4×,
    /// capped at 2.0×" hint and for tests.
    var rawMedian: Double?

    /// Allowed factor range (the clamp, and the manual override's stepper range).
    static let range: ClosedRange<Double> = 0.8...2.0
    /// Below this many samples the factor is 1.0 (not enough to measure).
    static let minSamples = 5

    /// No measurement yet (an empty library, or before the first read).
    static let unmeasured = PaceFactor(measured: 1.0, sampleCount: 0, rawMedian: nil)

    /// True when enough samples exist for ``measured`` to be a real measurement.
    var isMeasured: Bool { sampleCount >= Self.minSamples }

    /// The factor to plan with: the owner's manual override (clamped) when set, else the
    /// measured one.
    func effective(override: Double?) -> Double {
        override.map(Self.clamp) ?? measured
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Samples

    /// One finished game, reduced to what the measurement needs. All times in seconds; the
    /// estimate columns keep their stored meaning (see ``EstimateSanity``).
    struct Sample: Hashable, Sendable {
        /// Effective play time (manual, else max(PSN, Batocera) — ``EffectivePlaytime``).
        var playedSeconds: Int
        var rushedSeconds: Int?
        var mainSeconds: Int?
        var completionistSeconds: Int?
        /// Marked *100 %* (`status = 'completed'`) rather than *Finished*.
        var completed100: Bool
        /// The times come from HowLongToBeat (never flagged; enables its Main-Story read rule).
        var sourceIsHLTB: Bool
        /// The owner dismissed the suspicious flag ("Estimate Looks Right").
        var dismissed: Bool

        init(playedSeconds: Int, rushedSeconds: Int? = nil, mainSeconds: Int?,
             completionistSeconds: Int? = nil, completed100: Bool = false,
             sourceIsHLTB: Bool = false, dismissed: Bool = false) {
            self.playedSeconds = playedSeconds
            self.rushedSeconds = rushedSeconds
            self.mainSeconds = mainSeconds
            self.completionistSeconds = completionistSeconds
            self.completed100 = completed100
            self.sourceIsHLTB = sourceIsHLTB
            self.dismissed = dismissed
        }

        /// This sample's ratio (my time ÷ the matching estimate), or nil when it does not
        /// qualify (no play time, no main estimate, or a suspicious estimate).
        var ratio: Double? {
            guard playedSeconds > 0 else { return nil }
            let main = EstimateSanity.effectiveMain(rushed: rushedSeconds, main: mainSeconds,
                                                    sourceIsHLTB: sourceIsHLTB)
            guard let main, main > 0 else { return nil }
            if EstimateSanity.isFlagged(rushed: rushedSeconds, main: mainSeconds,
                                        completionist: completionistSeconds,
                                        sourceIsHLTB: sourceIsHLTB, dismissed: dismissed) {
                return nil
            }
            let matching: Int
            if completed100, let c = completionistSeconds, c > 0 {
                matching = c
            } else {
                matching = main
            }
            return Double(playedSeconds) / Double(matching)
        }
    }

    // MARK: Compute

    /// Measure the factor from the finished games (see the type doc).
    static func compute(samples: [Sample]) -> PaceFactor {
        let ratios = samples.compactMap(\.ratio).sorted()
        guard !ratios.isEmpty else { return .unmeasured }
        let mid = ratios.count / 2
        let median = ratios.count.isMultiple(of: 2)
            ? (ratios[mid - 1] + ratios[mid]) / 2
            : ratios[mid]
        let measured = ratios.count >= minSamples ? clamp(median) : 1.0
        return PaceFactor(measured: measured, sampleCount: ratios.count, rawMedian: median)
    }

    // MARK: Formatting

    /// "1.3×" — one decimal, trailing ".0" kept so the value reads as a factor ("1.0×").
    static func text(_ factor: Double) -> String {
        String(format: "%.1f×", factor)
    }
}
