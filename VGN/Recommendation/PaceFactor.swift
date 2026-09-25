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
/// **Implausible samples are set aside** (PLAN §7b "Per-genre pace"): a ratio outside
/// ``plausibleRange`` (< 0.3× or > 5×) means the recorded time is not the whole play (finished
/// before tracking, a short retro session), so it enters no median — global or per genre — and is
/// only counted (``setAsideCount``, Settings: "12 set aside as incomplete").
///
/// **Per-genre factors**: each genre with ≥ ``minGenreSamples`` plausible samples gets
/// ``shrink(median:sampleCount:global:)`` = `(n·median + 5·global)/(n + 5)`, clamped to ``range``
/// and quantized (``PaceProfile/quantize(_:)``); a game plans with the mean of its qualifying
/// genres' factors, else the global factor (``PaceProfile/factor(genreNames:)``).
///
/// Stored nowhere: it is recomputed from the library on demand; only an optional manual
/// **override** lives in the preferences (``effective(override:)`` — it replaces everything,
/// genres included, with the one number). It multiplies the
/// personal length wherever time is used *for planning* (``PersonalLength/compute`` and its
/// SQL mirror ``LibraryQuery/lengthEstimateExpr``) and never changes a stored or displayed
/// advertised time. Pure (Foundation only).
struct PaceFactor: Hashable, Sendable {
    /// The measured factor (1.0 until ``isMeasured``), clamped to ``range``.
    var measured: Double
    /// How many plausible finished games the measurement rests on (Settings: "based on 104 games").
    var sampleCount: Int
    /// The raw (unclamped) median of the plausible ratios, or nil with none — for a "your
    /// median is 2.4×, capped at 2.0×" hint and for tests.
    var rawMedian: Double?
    /// Qualifying samples whose ratio fell outside ``plausibleRange`` ("set aside as incomplete").
    var setAsideCount: Int = 0
    /// The genres with ≥ ``minGenreSamples`` plausible samples, with their shrunk factors
    /// (ascending id). Empty until measured.
    var genres: [PaceProfile.Genre] = []

    /// Allowed factor range (the clamp, and the manual override's stepper range).
    static let range: ClosedRange<Double> = 0.8...2.0
    /// Below this many samples the factor is 1.0 (not enough to measure).
    static let minSamples = 5
    /// A sample ratio outside this range is set aside as incomplete tracking (inclusive bounds).
    static let plausibleRange: ClosedRange<Double> = 0.3...5.0
    /// A genre needs this many plausible samples for its own factor.
    static let minGenreSamples = 10
    /// The shrinkage prior strength (pseudo-samples at the global factor).
    static let genrePriorStrength = 5.0

    /// No measurement yet (an empty library, or before the first read).
    static let unmeasured = PaceFactor(measured: 1.0, sampleCount: 0, rawMedian: nil)

    /// True when enough samples exist for ``measured`` to be a real measurement.
    var isMeasured: Bool { sampleCount >= Self.minSamples }

    /// The profile to plan with: the owner's manual override (clamped) as one uniform factor
    /// when set — it replaces the genre factors too — else the measured global + genre factors.
    func effective(override: Double?) -> PaceProfile {
        if let override { return .uniform(Self.clamp(override)) }
        return PaceProfile(global: measured, genres: genres)
    }

    /// The per-genre shrinkage toward the global factor (unclamped):
    /// `(n·median + k·global)/(n + k)` with k = ``genrePriorStrength``.
    static func shrink(median: Double, sampleCount n: Int, global: Double) -> Double {
        (Double(n) * median + genrePriorStrength * global) / (Double(n) + genrePriorStrength)
    }

    static func isPlausible(_ ratio: Double) -> Bool { plausibleRange.contains(ratio) }

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
        /// The game's genres (`game_genres` ⋈ `genres`), for the per-genre factors.
        var genres: [GenreRef]

        init(playedSeconds: Int, rushedSeconds: Int? = nil, mainSeconds: Int?,
             completionistSeconds: Int? = nil, completed100: Bool = false,
             sourceIsHLTB: Bool = false, dismissed: Bool = false, genres: [GenreRef] = []) {
            self.genres = genres
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

    /// A genre a sample belongs to (`genres.id` + `genres.name`).
    struct GenreRef: Hashable, Sendable {
        var id: Int64
        var name: String
        init(id: Int64, name: String) {
            self.id = id
            self.name = name
        }
    }

    // MARK: Compute

    /// Measure the factor from the finished games (see the type doc).
    static func compute(samples: [Sample]) -> PaceFactor {
        var plausible: [(ratio: Double, genres: [GenreRef])] = []
        var setAside = 0
        for sample in samples {
            guard let ratio = sample.ratio else { continue }
            if isPlausible(ratio) { plausible.append((ratio, sample.genres)) } else { setAside += 1 }
        }
        guard let median = median(plausible.map(\.ratio)) else {
            var none = PaceFactor.unmeasured
            none.setAsideCount = setAside
            return none
        }
        let measured = plausible.count >= minSamples ? clamp(median) : 1.0
        var result = PaceFactor(measured: measured, sampleCount: plausible.count, rawMedian: median)
        result.setAsideCount = setAside
        guard plausible.count >= minSamples else { return result }

        // Per genre: the plausible ratios of every sample carrying it (a multi-genre game counts
        // once in each of its genres).
        var byGenre: [GenreRef: [Double]] = [:]
        for s in plausible {
            for g in Set(s.genres) { byGenre[g, default: []].append(s.ratio) }
        }
        result.genres = byGenre.compactMap { genre, ratios -> PaceProfile.Genre? in
            guard ratios.count >= minGenreSamples, let m = Self.median(ratios) else { return nil }
            let factor = PaceProfile.quantize(clamp(shrink(median: m, sampleCount: ratios.count,
                                                           global: measured)))
            return PaceProfile.Genre(id: genre.id, name: genre.name, factor: factor,
                                     sampleCount: ratios.count)
        }.sorted { $0.id < $1.id }
        return result
    }

    /// The median (mean of the middle pair when even), or nil when empty.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: Formatting

    /// "1.3×" — one decimal, trailing ".0" kept so the value reads as a factor ("1.0×").
    static func text(_ factor: Double) -> String {
        String(format: "%.1f×", factor)
    }

    /// A genre name as it reads mid-sentence: the acronym of an IGDB name with one
    /// ("Role-playing (RPG)" → "RPG"), else lowercased ("Point-and-click" → "point-and-click").
    static func genreLabel(_ name: String) -> String {
        if let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            let inner = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { return inner }
        }
        return name.lowercased()
    }

    /// Settings' per-genre list: "Point-and-click 2.8× (32) · Puzzle 2.4× (58) · … · everything
    /// else 1.8×" — highest factor first, each with its plausible sample count. nil with no
    /// qualifying genre.
    var genreSummary: String? {
        guard !genres.isEmpty else { return nil }
        let parts = genres
            .sorted { $0.factor != $1.factor ? $0.factor > $1.factor : $0.name < $1.name }
            .map { "\($0.name) \(Self.text($0.factor)) (\($0.sampleCount))" }
        return (parts + ["everything else \(Self.text(measured))"]).joined(separator: " · ")
    }
}
