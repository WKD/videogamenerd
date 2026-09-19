import Foundation

/// Persistence for the owner's weekly ``PlayPace`` and whether they have ever set it
/// (PLAN §8 "By Length"). Behind a protocol so tests and sample mode use an in-memory
/// impl and never the owner's real defaults / `UserDefaults.standard`.
protocol PlayPacePreferenceStoring: Sendable {
    func playPace() -> PlayPace
    func setPlayPace(_ pace: PlayPace)
    /// True once the owner has chosen a pace at least once (drives the first-use CTA;
    /// no launch-time prompt, no modal).
    func hasChosenPace() -> Bool
    /// The owner's play style, which sets each game's personal length (owner request
    /// 2026-09-19). Persisted next to the pace and edited in the same editor.
    func playStyle() -> PlayStyle
    func setPlayStyle(_ style: PlayStyle)
}

/// `UserDefaults`-backed persistence over ``AppPreferences/defaults`` (a throw-away
/// suite under the test host — never the real domain).
struct UserDefaultsPlayPacePreferences: PlayPacePreferenceStoring {
    /// `UserDefaults` is internally synchronised but not `Sendable`-annotated.
    nonisolated(unsafe) let defaults: UserDefaults
    private let hoursKey = "VGNPlayPaceHours"
    private let chosenKey = "VGNPlayPaceChosen"
    private let styleKey = "VGNPlayStyle"

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

    func playPace() -> PlayPace {
        guard defaults.object(forKey: hoursKey) != nil else { return .default }
        return PlayPace(hoursPerWeek: defaults.double(forKey: hoursKey))
    }

    func setPlayPace(_ pace: PlayPace) {
        defaults.set(pace.hoursPerWeek, forKey: hoursKey)
        defaults.set(true, forKey: chosenKey)
    }

    func hasChosenPace() -> Bool { defaults.bool(forKey: chosenKey) }

    func playStyle() -> PlayStyle {
        defaults.string(forKey: styleKey).flatMap(PlayStyle.init(rawValue:)) ?? .default
    }

    func setPlayStyle(_ style: PlayStyle) { defaults.set(style.rawValue, forKey: styleKey) }
}

/// In-memory persistence (tests / sample mode; also a safe default with no defaults).
final class InMemoryPlayPacePreferences: PlayPacePreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pace: PlayPace
    private var chosen: Bool
    private var style: PlayStyle
    init(pace: PlayPace = .default, chosen: Bool = false, style: PlayStyle = .default) {
        self.pace = pace; self.chosen = chosen; self.style = style
    }
    func playPace() -> PlayPace { lock.withLock { pace } }
    func setPlayPace(_ new: PlayPace) { lock.withLock { pace = new; chosen = true } }
    func hasChosenPace() -> Bool { lock.withLock { chosen } }
    func playStyle() -> PlayStyle { lock.withLock { style } }
    func setPlayStyle(_ new: PlayStyle) { lock.withLock { style = new } }
}
