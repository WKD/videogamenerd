import Foundation

/// How the owner plays a game — how far past the "main story" they go — which sets a
/// game's **personal length** (owner request 2026-09-19: "never use the rushed time,
/// aggregate main and completionist as I do a lot of side quests"). A blend position
/// `t` ∈ 0…1 between the *main* estimate (IGDB/HLTB `normally`) and the *completionist*
/// estimate (`completely`). The **rushed / main-only** time (`hastily`) is deliberately
/// never used for length — a game with only that estimate stays *Unmeasured*.
///
/// Pure value type (Foundation only); it lives next to ``PlayPace`` and is used
/// everywhere the app asks "how long is this game *for me*": the BY LENGTH shelves +
/// Unmeasured, the Length sort, the Playtime filter's unplayed fallback, and Play Next's
/// time fit. The SQL expression (``LibraryQuery``) and the Swift function
/// (``PersonalLength/compute(normallyS:completelyS:style:r:)``) must agree.
enum PlayStyle: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case storyFirst
    case someSideQuests
    case lotsOfSideQuests
    case completionist

    var id: String { rawValue }

    /// The owner's own style (they do a lot of side quests).
    static let `default` = PlayStyle.lotsOfSideQuests

    /// Typical `completely ÷ normally` ratio, used to fill a **missing** side (a game
    /// with only one of the two estimates). A named constant, not measured per-library
    /// yet (see `docs/LIMITATIONS.md`).
    static let sidesRatio: Double = 1.5

    /// The blend position between *main* (0) and *completionist* (1).
    var t: Double {
        switch self {
        case .storyFirst:       return 0
        case .someSideQuests:   return 0.25
        case .lotsOfSideQuests: return 0.5
        case .completionist:    return 1
        }
    }

    /// The owner-facing name (picker label + the pace header suffix).
    var name: String {
        switch self {
        case .storyFirst:       return "Story first"
        case .someSideQuests:   return "Some side quests"
        case .lotsOfSideQuests: return "Lots of side quests"
        case .completionist:    return "Completionist"
        }
    }

    /// A one-line explanation shown under the picker option.
    var explanation: String {
        switch self {
        case .storyFirst:       return "Just the main story — the shortest path."
        case .someSideQuests:   return "The main story plus a few detours."
        case .lotsOfSideQuests: return "Most of the side content, short of 100%."
        case .completionist:    return "Everything — 100% completion."
        }
    }

    /// A live example for the editor, computed from fixed sample numbers so the owner
    /// sees what the setting does: "A 30 h story / 90 h completionist game counts as
    /// 60 h for you".
    var editorExample: String {
        let sample = PersonalLength.compute(normallyS: 30 * 3600, completelyS: 90 * 3600, style: self)
        let hours = sample.map { Int((Double($0.seconds) / 3600).rounded()) } ?? 0
        return "A 30 h story / 90 h completionist game counts as \(hours) h for you."
    }
}

extension Notification.Name {
    /// Posted when the owner commits a new ``PlayStyle``. The BY LENGTH shelves re-run
    /// through their own wiring; other open windows (the Library Stats window) listen for
    /// this to re-read the style and re-query (owner request 2026-09-20).
    static let vgnPlayStyleDidChange = Notification.Name("vgn.playStyleDidChange")
}

/// A game's length *for the owner* — the personal length in seconds, plus whether it
/// was derived from only one side (so the UI may show "≈"). `nil` from the builder means
/// *Unmeasured* (no main and no completionist estimate — a rushed-only game qualifies).
struct PersonalLength: Hashable, Sendable {
    /// Seconds (rounded to the nearest whole second, so the SQL and Swift paths agree).
    var seconds: Int
    /// True when only one side (main **or** completionist) was known, so the other was
    /// inflated with ``PlayStyle/sidesRatio`` — an estimate the UI may flag with "≈".
    var isApproximate: Bool

    /// The owner's personal length from the two IGDB/HLTB estimates and a play style.
    /// The **rushed** estimate is intentionally not a parameter — it is never used.
    ///
    /// - both sides: `normally + t·(completely − normally)`, clamping a dirty
    ///   `completely < normally` up to `normally`.
    /// - only *main*: `normally · (1 + t·(R − 1))`.
    /// - only *completionist*: `completely · (1 + t·(R − 1)) / R`.
    /// - neither: `nil` (Unmeasured).
    ///
    /// Linear throughout, so the SQL mirror is plain arithmetic (no SQLite math funcs).
    static func compute(
        normallyS: Int?, completelyS: Int?,
        style: PlayStyle, r: Double = PlayStyle.sidesRatio
    ) -> PersonalLength? {
        let t = style.t
        if let n = normallyS, let c0 = completelyS {
            let c = max(c0, n)                          // clamp dirty data up to `normally`
            let secs = Double(n) + t * Double(c - n)
            return PersonalLength(seconds: Int(secs.rounded()), isApproximate: false)
        }
        if let n = normallyS {
            let secs = Double(n) * (1 + t * (r - 1))
            return PersonalLength(seconds: Int(secs.rounded()), isApproximate: true)
        }
        if let c = completelyS {
            let secs = Double(c) * (1 + t * (r - 1)) / r
            return PersonalLength(seconds: Int(secs.rounded()), isApproximate: true)
        }
        return nil                                       // rushed-only or nothing → Unmeasured
    }
}
