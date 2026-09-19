import Foundation

/// How much the owner can play in a typical week (owner request 2026-09-19). Drives
/// the "By Length" sidebar shelves' hour ranges: someone who can only play 2 h/week
/// reaches "a few weeks" at 10 h, someone who plays 40 h/week only at 200 h.
///
/// Pure value; persisted through a `PlayPacePreferenceStoring` in the UI layer.
struct PlayPace: Hashable, Sendable, Codable {
    /// Hours the owner can play in a typical week — always clamped to a sane 1…60.
    var hoursPerWeek: Double

    static let minHours: Double = 1
    static let maxHours: Double = 60
    /// The pace assumed until the owner sets one (a middling casual week). At this
    /// pace the shelf edges are today's constants 4 / 10 / 40 / 80.
    static let `default` = PlayPace(hoursPerWeek: 8)

    init(hoursPerWeek: Double) {
        // NaN-safe clamp.
        let v = hoursPerWeek.isFinite ? hoursPerWeek : Self.default.hoursPerWeek
        self.hoursPerWeek = min(max(v, Self.minHours), Self.maxHours)
    }
}

/// The four ascending *upper* hour edges of the first four "By Length" shelves;
/// Epics is open above the fourth. Always strictly increasing and snapped to the
/// "nice hours" ladder (see ``LengthShelf/bounds(for:)``).
struct LengthBounds: Hashable, Sendable {
    /// Exactly four strictly-increasing hour values.
    let edgesHours: [Double]
}

/// A literary "By Length" shelf: games grouped by how long the game **is** — its
/// time-to-beat *estimate only* (`COALESCE(ttb_normally_s, ttb_hastily_s,
/// ttb_completely_s)`), never the owner's own playtime, so a 100-hour RPG dropped
/// after 2 h is still an epic (PLAN §8). This is deliberately different from the
/// Playtime *filter* (``PlaytimeBucket``), which buckets *effective playtime first*.
///
/// The five shelves tile the length axis; their edges are derived from the owner's
/// weekly ``PlayPace`` (not fixed constants). Every owner-facing string (name,
/// subtitle, tooltip, section header) comes from this one table; the stable case id
/// is never derived from the name, which is the owner's taste and will be tweaked.
enum LengthShelf: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case evening
    case weekend
    case fewWeeks
    case season
    case epic

    var id: String { rawValue }

    /// The header above the five shelf rows in the sidebar.
    static let sectionHeader = "BY LENGTH"

    // MARK: - Vocabulary (owner's taste — every string from here)

    /// The owner-facing literary name (window title + row title).
    var name: String {
        switch self {
        case .evening:  return "One Evening"
        case .weekend:  return "A Weekend"
        case .fewWeeks: return "A Few Weeks"
        case .season:   return "A Season"
        case .epic:     return "Epics"
        }
    }

    /// SF Symbol for the row (existence checked by a test so a typo fails loudly).
    var symbol: String {
        switch self {
        case .evening:  return "moon.stars"
        case .weekend:  return "sun.max"
        case .fewWeeks: return "calendar"
        case .season:   return "leaf"
        case .epic:     return "scroll"
        }
    }

    /// The verb phrase used in the tooltip ("in one evening", "over a weekend"…).
    private var phrase: String {
        switch self {
        case .evening:  return "in one evening"
        case .weekend:  return "over a weekend"
        case .fewWeeks: return "in a few weeks"
        case .season:   return "over a season"
        case .epic:     return "the long ones"   // tooltip is special-cased for Epics
        }
    }

    // MARK: - The "Unmeasured" catch-all (not a shelf; its own sidebar row)

    static let unmeasuredName = "Unmeasured"
    static let unmeasuredSymbol = "questionmark.circle"
    static let unmeasuredTooltip =
        "Games with no time-to-beat estimate yet — nothing to place them on a shelf. Select to fetch missing time estimates."

    // MARK: - Pace-derived bounds

    /// The "nice hours" ladder every shelf edge snaps to.
    static let niceHours: [Double] =
        [1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100, 120, 150, 200, 250, 300, 400, 500]

    /// The five shelves' hour edges for a given weekly play pace. Raw upper edges are
    /// `min(4, hpw)` · `hpw × 1.25` · `hpw × 5` · `hpw × 10`; each is snapped to the
    /// ladder (ties round up) and the sequence is forced strictly increasing.
    static func bounds(for pace: PlayPace) -> LengthBounds {
        let hpw = pace.hoursPerWeek
        let raw = [min(4, hpw), hpw * 1.25, hpw * 5, hpw * 10]
        var edges: [Double] = []
        for value in raw {
            var snapped = snapToLadder(value)
            if let prev = edges.last, snapped <= prev {
                snapped = nextLadderValue(above: prev)
            }
            edges.append(snapped)
        }
        return LengthBounds(edgesHours: edges)
    }

    /// Nearest ladder value; a tie rounds **up** (so 2.5 → 3, 1.25 → 1½).
    static func snapToLadder(_ value: Double) -> Double {
        var best = niceHours[0]
        var bestDist = abs(value - best)
        for candidate in niceHours.dropFirst() {
            let dist = abs(value - candidate)
            if dist <= bestDist { best = candidate; bestDist = dist }   // `<=` → later (larger) wins a tie
        }
        return best
    }

    private static func nextLadderValue(above value: Double) -> Double {
        niceHours.first { $0 > value } ?? niceHours.last!
    }

    /// `(lowerInclusive, upperExclusive)` hours for this shelf under `bounds`
    /// (nil = unbounded on that side).
    func hourRange(in bounds: LengthBounds) -> (lower: Double?, upper: Double?) {
        let e = bounds.edgesHours
        switch self {
        case .evening:  return (nil, e[0])
        case .weekend:  return (e[0], e[1])
        case .fewWeeks: return (e[1], e[2])
        case .season:   return (e[2], e[3])
        case .epic:     return (e[3], nil)
        }
    }

    /// `(lowerInclusive, upperExclusive)` in **seconds** — what the SQL scope and the
    /// counts query take as arguments (never literals).
    func secondsRange(in bounds: LengthBounds) -> (lower: Int?, upper: Int?) {
        let r = hourRange(in: bounds)
        return (r.lower.map(Self.hoursToSeconds), r.upper.map(Self.hoursToSeconds))
    }

    static func hoursToSeconds(_ hours: Double) -> Int { Int((hours * 3600).rounded()) }

    // MARK: - Generated row strings

    /// Row subtitle, e.g. "under 4 h", "4–10 h", "80 h and more" (1.5 → "1½").
    func subtitle(bounds: LengthBounds) -> String {
        let r = hourRange(in: bounds)
        switch (r.lower, r.upper) {
        case let (nil, upper?):    return "under \(Self.formatHours(upper)) h"
        case let (lower?, nil):    return "\(Self.formatHours(lower)) h and more"
        case let (lower?, upper?): return "\(Self.formatHours(lower))–\(Self.formatHours(upper)) h"
        case (nil, nil):           return ""
        }
    }

    /// Hover tooltip, e.g. "Games you can finish in a few weeks at 2 h a week — 3 to
    /// 10 hours (time-to-beat estimate)".
    func tooltip(pace: PlayPace, bounds: LengthBounds) -> String {
        let paceText = Self.formatHours(pace.hoursPerWeek)
        let r = hourRange(in: bounds)
        let suffix = "(time-to-beat estimate)"
        if self == .epic {
            return "The long ones — \(Self.formatHours(r.lower ?? 0)) hours and more \(suffix)"
        }
        let rangeText: String
        switch (r.lower, r.upper) {
        case let (nil, upper?):    rangeText = "under \(Self.formatHours(upper)) hours"
        case let (lower?, upper?): rangeText = "\(Self.formatHours(lower)) to \(Self.formatHours(upper)) hours"
        default:                   rangeText = ""
        }
        return "Games you can finish \(phrase) at \(paceText) h a week — \(rangeText) \(suffix)"
    }

    /// Render a "nice hours" value: 1.5 → "1½", whole numbers plain.
    static func formatHours(_ value: Double) -> String {
        let whole = value.rounded(.down)
        if abs(value - whole - 0.5) < 0.001 {
            return whole == 0 ? "½" : "\(Int(whole))½"
        }
        return "\(Int(value.rounded()))"
    }
}
