import Observation
import SwiftUI

/// A transient toast after a Play Next action (start playing / snooze / never).
struct PlayNextToast: Equatable, Identifiable {
    let id = UUID()
    var text: String
}

/// The "Ask Claude" state machine (PLAN §7b): idle → asking (cancellable, elapsed
/// time) → result / failed. Invalidated when the shortlist changes.
enum SecondOpinionState: Equatable {
    case idle
    case asking
    case result(SecondOpinion)
    case failed(SecondOpinionError)
}

/// All Play Next logic (PLAN §7b): bracket selection (persisted), options,
/// latest-wins recompute on input change, re-roll, the store actions, reason
/// sentences, small-library awareness, the taste backtest, and the on-demand
/// second opinion. The view is a thin shell over this; every transition is
/// unit-tested against a fake ``PlayNextBackend`` + stub provider, no database.
@MainActor
@Observable
final class PlayNextModel {

    // MARK: - Bracket (persisted)

    private(set) var bracketPreset: TimeBracket.Preset
    private(set) var usesCustom: Bool
    private(set) var customHoursPerWeek: Double
    private(set) var customWeeks: Double
    private(set) var completionist: Bool

    // MARK: - Options (persisted)

    private(set) var includeAbandoned: Bool
    private(set) var includePlayedWithoutStatus: Bool

    // MARK: - Presented state

    /// The current result — kept while a recompute runs so the view never flashes
    /// empty (PLAN §7b "keep the previous result until the new one is ready").
    private(set) var result: PlayNextResult?
    /// Titles + tiers for every exemplar the current result's reasons cite.
    private(set) var exemplars: [Int64: ExemplarInfo] = [:]
    /// True while a recompute is in flight (a subtle indicator, not a full reload).
    private(set) var isRecomputing = false
    /// True once the first result (or empty verdict) has resolved.
    private(set) var hasLoaded = false
    /// The taste-model self-check (PLAN §7b), loaded lazily.
    private(set) var backtest: TasteBacktestResult?
    /// How many games are ranked — drives the small-library banner (< 15).
    private(set) var rankedCount = 0
    private(set) var toast: PlayNextToast?

    // MARK: - Second opinion

    private(set) var secondOpinionState: SecondOpinionState = .idle
    private(set) var secondOpinionElapsed = 0
    /// Whether the one-time "what is sent" disclosure has been shown (persisted).
    private(set) var hasShownAskDisclosure: Bool

    // MARK: - Seams

    private let backend: any PlayNextBackend
    private let secondOpinion: any SecondOpinionProviding
    private let defaults: UserDefaults
    private let recomputeDebounce: Duration

    private var seed: UInt64 = 0
    private var recomputeTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var secondOpinionCache: [SecondOpinionCacheKey: SecondOpinion] = [:]
    private var activeSecondOpinionKey: SecondOpinionCacheKey?

    init(
        backend: any PlayNextBackend,
        secondOpinion: any SecondOpinionProviding,
        defaults: UserDefaults = .standard,
        recomputeDebounce: Duration = .milliseconds(250)
    ) {
        self.backend = backend
        self.secondOpinion = secondOpinion
        self.defaults = defaults
        self.recomputeDebounce = recomputeDebounce

        let store = Prefs(defaults: defaults)
        self.bracketPreset = store.preset
        self.usesCustom = store.usesCustom
        self.customHoursPerWeek = store.customHoursPerWeek
        self.customWeeks = store.customWeeks
        self.completionist = store.completionist
        self.includeAbandoned = store.includeAbandoned
        self.includePlayedWithoutStatus = store.includePlayedWithoutStatus
        self.hasShownAskDisclosure = store.hasShownAskDisclosure
    }

    // MARK: - Derived inputs

    var bracket: TimeBracket {
        if usesCustom {
            let seconds = Int((customHoursPerWeek * customWeeks * 3600).rounded())
            return TimeBracket(budgetSeconds: max(3600, seconds), completionist: completionist)
        }
        return TimeBracket(preset: bracketPreset, completionist: completionist)
    }

    var options: RecommendationOptions {
        RecommendationOptions(
            includeAbandoned: includeAbandoned,
            includePlayedWithoutStatus: includePlayedWithoutStatus,
            seed: seed,
            maxAlternatives: 4)
    }

    /// PLAN §7b: under ~15 ranked games, the view says so and leans on the crowd prior.
    var isSmallLibrary: Bool { rankedCount < TasteBacktest.minSamples }

    // MARK: - Lifecycle

    func start() async {
        if let sig = try? await backend.inputsSignatureOnce() { rankedCount = sig.ranked }
        recompute(debounce: false)
        await loadBacktest()
        subscribeLive()
    }

    func stop() {
        recomputeTask?.cancel()
        liveTask?.cancel()
        askTask?.cancel()
        elapsedTask?.cancel()
        toastTask?.cancel()
    }

    private func subscribeLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [backend] in
            for await sig in backend.inputsChangedStream() {
                let rankedChanged = sig.ranked != self.rankedCount
                self.rankedCount = sig.ranked
                self.recompute(debounce: true)
                if rankedChanged { await self.loadBacktest() }
            }
        }
    }

    private func loadBacktest() async {
        backtest = try? await backend.backtest()
    }

    // MARK: - Bracket / option changes

    func selectPreset(_ preset: TimeBracket.Preset) {
        usesCustom = false
        bracketPreset = preset
        persist()
        recompute(debounce: false)
    }

    /// `1`…`4` keyboard shortcut → the nth preset.
    func selectPreset(index: Int) {
        let presets = TimeBracket.Preset.allCases
        guard presets.indices.contains(index) else { return }
        selectPreset(presets[index])
    }

    func useCustom(hoursPerWeek: Double, weeks: Double) {
        usesCustom = true
        customHoursPerWeek = max(0.5, hoursPerWeek)
        customWeeks = max(0.5, weeks)
        persist()
        recompute(debounce: true)
    }

    func setCustomHoursPerWeek(_ value: Double) { useCustom(hoursPerWeek: value, weeks: customWeeks) }
    func setCustomWeeks(_ value: Double) { useCustom(hoursPerWeek: customHoursPerWeek, weeks: value) }

    func setCompletionist(_ on: Bool) {
        completionist = on
        persist()
        recompute(debounce: false)
    }

    func setIncludeAbandoned(_ on: Bool) {
        includeAbandoned = on
        persist()
        recompute(debounce: false)
    }

    func setIncludePlayedWithoutStatus(_ on: Bool) {
        includePlayedWithoutStatus = on
        persist()
        recompute(debounce: false)
    }

    /// `R` — re-roll among near-ties with a fresh seed (PLAN §7b).
    func reroll() {
        seed = UInt64.random(in: .min ... .max)
        recompute(debounce: false)
    }

    // MARK: - Recompute (latest-wins, debounced, non-flashing)

    private func recompute(debounce: Bool) {
        recomputeTask?.cancel()
        let bracket = self.bracket
        let options = self.options
        let debounceFor = self.recomputeDebounce
        recomputeTask = Task { [backend] in
            if debounce { try? await Task.sleep(for: debounceFor) }
            guard !Task.isCancelled else { return }
            self.isRecomputing = true
            if let newResult = try? await backend.recommend(bracket: bracket, options: options),
               !Task.isCancelled {
                let ids = Self.exemplarIDs(in: newResult)
                let info = (try? await backend.exemplarInfo(ids: ids)) ?? [:]
                if !Task.isCancelled {
                    self.exemplars = info
                    self.result = newResult
                    self.invalidateStaleSecondOpinion(for: newResult)
                }
            }
            if !Task.isCancelled {
                self.isRecomputing = false
                self.hasLoaded = true
            }
        }
    }

    /// Exemplar ids cited by any suggestion's reasons, for the sentence lookups.
    static func exemplarIDs(in result: PlayNextResult) -> [Int64] {
        var ids = Set<Int64>()
        for suggestion in result.shortlist + result.unknownLength {
            for reason in suggestion.reasons {
                switch reason {
                case let .sharedFranchise(_, with): ids.insert(with)
                case let .sharedSeries(_, with): ids.insert(with)
                case let .sameDeveloper(_, exemplar): ids.insert(exemplar)
                case let .similarTo(e): ids.insert(e)
                default: break
                }
            }
        }
        return Array(ids)
    }

    // MARK: - Reason sentences

    func reasonSentences(for suggestion: PlayNextSuggestion) -> [String] {
        PlayNextReasonFormatter.sentences(for: suggestion, exemplars: exemplars, bracket: bracket)
    }

    // MARK: - Actions

    func startPlaying(_ suggestion: PlayNextSuggestion) async {
        do {
            try await backend.startPlaying(gameID: suggestion.id)
            setToast("Started playing \(suggestion.title)")
        } catch {
            setToast("Couldn't start \(suggestion.title)")
        }
        recompute(debounce: false)
    }

    func notThisOne(_ suggestion: PlayNextSuggestion) async {
        try? await backend.snooze(gameID: suggestion.id)
        setToast("Snoozed \(suggestion.title)")
        recompute(debounce: false)
    }

    func never(_ suggestion: PlayNextSuggestion) async {
        try? await backend.never(gameID: suggestion.id)
        setToast("Removed \(suggestion.title) from Play Next")
        recompute(debounce: false)
    }

    // MARK: - Second opinion

    /// The suggestion behind a Claude pick, for the "Claude" column.
    func suggestion(for gameID: Int64) -> PlayNextSuggestion? {
        result?.shortlist.first { $0.id == gameID }
    }

    /// True when the engine and Claude agree on the same #1 pick.
    var secondOpinionAgreesOnHero: Bool {
        guard case let .result(opinion) = secondOpinionState,
              let heroID = result?.hero?.id,
              let claudeTop = opinion.picks.first?.gameID else { return false }
        return heroID == claudeTop
    }

    func askClaude() {
        guard let result, !result.shortlist.isEmpty else { return }
        if !hasShownAskDisclosure { hasShownAskDisclosure = true; persist() }

        let key = SecondOpinionCacheKey(result: result)
        if let cached = secondOpinionCache[key] {
            activeSecondOpinionKey = key
            secondOpinionState = .result(cached)
            return
        }

        askTask?.cancel()
        activeSecondOpinionKey = key
        secondOpinionState = .asking
        startElapsedTimer()

        askTask = Task { [backend, secondOpinion] in
            do {
                let request = try await backend.secondOpinionRequest(for: result)
                let opinion = try await secondOpinion.secondOpinion(for: request)
                guard !Task.isCancelled else { return }
                self.secondOpinionCache[key] = opinion
                self.secondOpinionState = .result(opinion)
            } catch {
                guard !Task.isCancelled else { return }
                let failure = SecondOpinionError.wrap(error)
                if failure == .cancelled {
                    self.secondOpinionState = .idle
                } else {
                    self.secondOpinionState = .failed(failure)
                }
            }
            self.stopElapsedTimer()
        }
    }

    func cancelSecondOpinion() {
        askTask?.cancel()
        stopElapsedTimer()
        secondOpinionState = .idle
        activeSecondOpinionKey = nil
    }

    /// Close the Claude column without re-running.
    func dismissSecondOpinion() {
        secondOpinionState = .idle
    }

    private func invalidateStaleSecondOpinion(for newResult: PlayNextResult) {
        guard let active = activeSecondOpinionKey else { return }
        if active != SecondOpinionCacheKey(result: newResult) {
            askTask?.cancel()
            stopElapsedTimer()
            secondOpinionState = .idle
            activeSecondOpinionKey = nil
        }
    }

    private func startElapsedTimer() {
        secondOpinionElapsed = 0
        elapsedTask?.cancel()
        elapsedTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                self.secondOpinionElapsed += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    // MARK: - Toast

    private func setToast(_ text: String) {
        toast = PlayNextToast(text: text)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    func clearToast() { toastTask?.cancel(); toast = nil }

    // MARK: - Persistence

    private func persist() {
        var store = Prefs(defaults: defaults)
        store.preset = bracketPreset
        store.usesCustom = usesCustom
        store.customHoursPerWeek = customHoursPerWeek
        store.customWeeks = customWeeks
        store.completionist = completionist
        store.includeAbandoned = includeAbandoned
        store.includePlayedWithoutStatus = includePlayedWithoutStatus
        store.hasShownAskDisclosure = hasShownAskDisclosure
    }
}

// MARK: - Second-opinion cache key

/// The session-cache key (PLAN §7b: "cached per (shortlist, bracket) for the
/// session"). Completionist is part of the bracket's identity here.
struct SecondOpinionCacheKey: Hashable {
    var shortlist: [Int64]
    var bracketLabel: String
    var completionist: Bool

    init(result: PlayNextResult) {
        self.shortlist = result.shortlist.map(\.id)
        self.bracketLabel = result.bracket.label
        self.completionist = result.bracket.completionist
    }
}

// MARK: - Preferences

/// A tiny typed façade over `UserDefaults` for the persisted bracket / options.
private struct Prefs {
    let defaults: UserDefaults
    private enum Key {
        static let preset = "playNext.preset"
        static let usesCustom = "playNext.usesCustom"
        static let customHoursPerWeek = "playNext.customHoursPerWeek"
        static let customWeeks = "playNext.customWeeks"
        static let completionist = "playNext.completionist"
        static let includeAbandoned = "playNext.includeAbandoned"
        static let includePlayedWithoutStatus = "playNext.includePlayedWithoutStatus"
        static let hasShownAskDisclosure = "playNext.hasShownAskDisclosure"
    }

    var preset: TimeBracket.Preset {
        get { (defaults.string(forKey: Key.preset)).flatMap(TimeBracket.Preset.init) ?? .weekOrTwo }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.preset) }
    }
    var usesCustom: Bool {
        get { defaults.bool(forKey: Key.usesCustom) }
        nonmutating set { defaults.set(newValue, forKey: Key.usesCustom) }
    }
    var customHoursPerWeek: Double {
        get { defaults.object(forKey: Key.customHoursPerWeek) as? Double ?? 8 }
        nonmutating set { defaults.set(newValue, forKey: Key.customHoursPerWeek) }
    }
    var customWeeks: Double {
        get { defaults.object(forKey: Key.customWeeks) as? Double ?? 4 }
        nonmutating set { defaults.set(newValue, forKey: Key.customWeeks) }
    }
    var completionist: Bool {
        get { defaults.bool(forKey: Key.completionist) }
        nonmutating set { defaults.set(newValue, forKey: Key.completionist) }
    }
    var includeAbandoned: Bool {
        get { defaults.bool(forKey: Key.includeAbandoned) }
        nonmutating set { defaults.set(newValue, forKey: Key.includeAbandoned) }
    }
    var includePlayedWithoutStatus: Bool {
        get { defaults.bool(forKey: Key.includePlayedWithoutStatus) }
        nonmutating set { defaults.set(newValue, forKey: Key.includePlayedWithoutStatus) }
    }
    var hasShownAskDisclosure: Bool {
        get { defaults.bool(forKey: Key.hasShownAskDisclosure) }
        nonmutating set { defaults.set(newValue, forKey: Key.hasShownAskDisclosure) }
    }
}
