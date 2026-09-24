import Observation
import SwiftUI

/// A transient toast after a Play Next action (start playing / snooze / never).
/// When `undoable`, the view shows an inline "Undo" affordance backed by
/// ``PlayNextModel/pendingStartUndo``.
struct PlayNextToast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var undoable = false
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

    /// The chosen length shelf (one of the five "By Length" shelves). Its hour bounds
    /// come from ``LengthShelf/bounds(for:)`` at the current ``pace``.
    private(set) var bracketShelf: LengthShelf
    private(set) var usesCustom: Bool
    private(set) var customHoursPerWeek: Double
    private(set) var customWeeks: Double
    private(set) var completionist: Bool

    /// Whether the owner has ever explicitly set the custom hours/week (vs. it being
    /// pre-filled from the pace). Governs whether a pace change re-seeds the pre-fill.
    private var customHoursSet: Bool

    /// The owner's weekly play pace — the *same* value the sidebar "By Length" shelves
    /// use, so a Play Next bracket and its sidebar shelf cover the same hour range.
    /// Fed in by the view from the shared ``PlayPaceModel``; a change recomputes once.
    private(set) var pace: PlayPace

    /// The owner's play style — the *same* value the sidebar uses — which sets each
    /// candidate's personal length for the time fit. The "plan for 100%" toggle
    /// (``completionist``) overrides it per session. A change recomputes once.
    private(set) var playStyle: PlayStyle

    /// A one-shot hint (consumed at ``start()``): the "By Length" shelf last selected
    /// in the sidebar, so opening Play Next preselects the matching bracket.
    private let bracketHint: (@MainActor () -> LengthShelf?)?

    // MARK: - Options (persisted)

    private(set) var includeAbandoned: Bool
    private(set) var includePlayedWithoutStatus: Bool
    /// Prefer games owned only via PS Plus (PLAN §13.3), a small backtest-neutral nudge.
    private(set) var preferExpiringSubscription: Bool
    /// Include games marked **Too Archaic** ("Holds up today?", PLAN §7b). Off by default.
    private(set) var includeArchaic: Bool
    /// The backtest's optional cutoff (PLAN §7b "Helping me judge"): also run it without the
    /// games first played before this year. nil = off. Persisted.
    private(set) var backtestCutoffYear: Int?

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

    /// The window's undo manager (set by the view). Reversible "Start playing"
    /// registers its inverse here so Edit ▸ Undo "Start Playing" / ⌘Z work.
    var undoManager: UndoManager?
    /// The token to undo the most recent "Start playing", or nil. Drives the toast's
    /// inline "Undo" and is single-shot (cleared once used or superseded).
    private(set) var pendingStartUndo: StartPlayingUndo?

    // MARK: - Second opinion

    private(set) var secondOpinionState: SecondOpinionState = .idle
    private(set) var secondOpinionElapsed = 0
    /// Whether the one-time "what is sent" disclosure has been shown (persisted).
    private(set) var hasShownAskDisclosure: Bool

    // MARK: - Seams

    private let backend: any PlayNextBackend
    private let secondOpinion: any SecondOpinionProviding
    private let defaults: UserDefaults
    /// Months until the owner plans to leave PS Plus (nil ⇒ no date), read fresh each recompute
    /// so a change in Settings ▸ PlayStation reaches the picks (PLAN §16). Injected for tests.
    private let deadlineMonthsLeft: @MainActor () -> Double?
    private let recomputeDebounce: Duration
    /// How long a plain toast lingers, and (longer) an undoable "Started …" toast.
    /// Injected so tests never assert on wall-clock time.
    private let toastDuration: Duration
    private let undoToastDuration: Duration

    private var seed: UInt64 = 0
    private var recomputeTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var deadlineObserver: NSObjectProtocol?
    private var secondOpinionCache: [SecondOpinionCacheKey: SecondOpinion] = [:]
    private var activeSecondOpinionKey: SecondOpinionCacheKey?

    init(
        backend: any PlayNextBackend,
        secondOpinion: any SecondOpinionProviding,
        defaults: UserDefaults = AppPreferences.defaults,
        pace: PlayPace = .default,
        playStyle: PlayStyle = .default,
        bracketHint: (@MainActor () -> LengthShelf?)? = nil,
        deadlineMonthsLeft: @escaping @MainActor () -> Double? = { PSPlusDeadlinePreferences().monthsLeft() },
        recomputeDebounce: Duration = .milliseconds(250),
        toastDuration: Duration = .seconds(4),
        undoToastDuration: Duration = .seconds(10)
    ) {
        self.backend = backend
        self.secondOpinion = secondOpinion
        self.defaults = defaults
        self.deadlineMonthsLeft = deadlineMonthsLeft
        self.pace = pace
        self.playStyle = playStyle
        self.bracketHint = bracketHint
        self.recomputeDebounce = recomputeDebounce
        self.toastDuration = toastDuration
        self.undoToastDuration = undoToastDuration

        let store = Prefs(defaults: defaults)
        self.bracketShelf = store.shelf
        self.usesCustom = store.usesCustom
        self.customHoursSet = store.customHoursSet
        // The custom "hours per week" is pre-filled from the pace unless the owner has
        // explicitly chosen one (the old stored value is ignored — owner request).
        self.customHoursPerWeek = store.customHoursSet ? store.customHoursPerWeek : pace.hoursPerWeek
        self.customWeeks = store.customWeeks
        self.completionist = store.completionist
        self.includeAbandoned = store.includeAbandoned
        self.includePlayedWithoutStatus = store.includePlayedWithoutStatus
        self.preferExpiringSubscription = store.preferExpiringSubscription
        self.includeArchaic = store.includeArchaic
        self.backtestCutoffYear = store.backtestCutoffYear
        self.hasShownAskDisclosure = store.hasShownAskDisclosure
    }

    // MARK: - Derived inputs

    var bracket: TimeBracket {
        if usesCustom {
            let seconds = Int((customHoursPerWeek * customWeeks * 3600).rounded())
            return TimeBracket(budgetSeconds: max(3600, seconds),
                               playStyle: playStyle, completionist: completionist)
        }
        return TimeBracket(shelf: bracketShelf, pace: pace,
                           playStyle: playStyle, completionist: completionist)
    }

    /// The "plan for 100%" toggle is forced on and disabled when the owner already
    /// plays as a completionist (there is nothing further to override).
    var completionistForced: Bool { playStyle == .completionist }
    /// What the toggle shows (on when forced by the style, else the session override).
    var completionistOn: Bool { completionist || completionistForced }

    var options: RecommendationOptions {
        RecommendationOptions(
            includeAbandoned: includeAbandoned,
            includePlayedWithoutStatus: includePlayedWithoutStatus,
            includeArchaic: includeArchaic,
            seed: seed,
            maxAlternatives: 4,
            preferExpiringSubscription: preferExpiringSubscription,
            psPlusMonthsLeft: deadlineMonthsLeft(),
            psPlusPace: pace)
    }

    /// PLAN §7b: under ~15 ranked games, the view says so and leans on the crowd prior.
    var isSmallLibrary: Bool { rankedCount < TasteBacktest.minSamples }

    // MARK: - Lifecycle

    func start() async {
        // One-shot sidebar → Play Next preselect: if a "By Length" shelf was the last
        // sidebar selection, open on the matching bracket (consumed once).
        if let hint = bracketHint?() {
            usesCustom = false
            bracketShelf = hint
            persist()
        }
        if let sig = try? await backend.inputsSignatureOnce() { rankedCount = sig.ranked }
        recompute(debounce: false)
        await loadBacktest()
        subscribeLive()
        observeDeadlineChanges()
    }

    /// Recompute once when the PS Plus cancellation date changes in Settings (PLAN §16).
    private func observeDeadlineChanges() {
        guard deadlineObserver == nil else { return }
        deadlineObserver = NotificationCenter.default.addObserver(
            forName: PSPlusDeadlinePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute(debounce: false) }
        }
    }

    func stop() {
        recomputeTask?.cancel()
        liveTask?.cancel()
        askTask?.cancel()
        elapsedTask?.cancel()
        toastTask?.cancel()
        if let deadlineObserver {
            NotificationCenter.default.removeObserver(deadlineObserver)
            self.deadlineObserver = nil
        }
        // Navigating away drops the "Start playing" undo affordance (PLAN §7b:
        // "until the next action/navigation").
        clearPendingStartUndo()
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
        backtest = try? await backend.backtest(firstPlayedCutoff: backtestCutoffYear)
    }

    /// The default year the cutoff control starts at when first switched on.
    static let defaultBacktestCutoffYear = 1995

    /// Set (or clear, with nil) the backtest cutoff year and re-run the backtest (PLAN §7b).
    func setBacktestCutoffYear(_ year: Int?) async {
        guard year != backtestCutoffYear else { return }
        backtestCutoffYear = year
        persist()
        await loadBacktest()
    }

    // MARK: - Bracket / option changes

    func selectShelf(_ shelf: LengthShelf) {
        usesCustom = false
        bracketShelf = shelf
        persist()
        recompute(debounce: false)
    }

    /// `1`…`5` keyboard shortcut → the nth "By Length" shelf.
    func selectShelf(index: Int) {
        let shelves = LengthShelf.allCases
        guard shelves.indices.contains(index) else { return }
        selectShelf(shelves[index])
    }

    /// Adopt a new weekly pace (from the shared ``PlayPaceModel``). Recomputes once —
    /// a shelf bracket's hour bounds move with the pace, like the sidebar shelves.
    func setPace(_ newPace: PlayPace) {
        guard newPace != pace else { return }
        pace = newPace
        // Keep the custom pre-fill in step with the pace until the owner overrides it.
        if !customHoursSet { customHoursPerWeek = newPace.hoursPerWeek }
        recompute(debounce: false)
    }

    /// Adopt a new play style (from the shared ``PlayPaceModel``). Recomputes once —
    /// each candidate's personal length changes with the style.
    func setPlayStyle(_ newStyle: PlayStyle) {
        guard newStyle != playStyle else { return }
        playStyle = newStyle
        recompute(debounce: false)
    }

    func useCustom(hoursPerWeek: Double, weeks: Double) {
        usesCustom = true
        customHoursSet = true
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

    /// "Include too archaic" (PLAN §7b): bring back the games marked Too Archaic.
    func setIncludeArchaic(_ on: Bool) {
        includeArchaic = on
        persist()
        recompute(debounce: false)
    }

    func setPreferExpiringSubscription(_ on: Bool) {
        preferExpiringSubscription = on
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
        clearPendingStartUndo()
        do {
            let token = try await backend.startPlaying(gameID: suggestion.id)
            pendingStartUndo = token
            registerStartUndo()
            setToast("Started \(suggestion.title)", undoable: true)
        } catch {
            setToast("Couldn't start \(suggestion.title)")
        }
        recompute(debounce: false)
    }

    func notThisOne(_ suggestion: PlayNextSuggestion) async {
        clearPendingStartUndo()
        try? await backend.snooze(gameID: suggestion.id)
        setToast("Snoozed \(suggestion.title)")
        recompute(debounce: false)
    }

    func never(_ suggestion: PlayNextSuggestion) async {
        clearPendingStartUndo()
        try? await backend.never(gameID: suggestion.id)
        setToast("Removed \(suggestion.title) from Play Next")
        recompute(debounce: false)
    }

    // MARK: - Undo "Start playing" (PLAN §7b)

    /// The inline toast affordance calls this. Undoes the most recent start.
    func undoLastStartPlaying() async {
        guard let token = pendingStartUndo else { return }
        await performUndoStartPlaying(token)
    }

    /// Reverse a "Start playing". Single-shot: a stale token (already undone, or a
    /// later action) is ignored, so the toast button and ⌘Z can't double-apply.
    /// `internal` so a test drives the inverse directly (UndoManager.undo() hangs
    /// headless).
    func performUndoStartPlaying(_ token: StartPlayingUndo) async {
        guard pendingStartUndo == token else { return }
        pendingStartUndo = nil
        do {
            switch try await backend.undoStartPlaying(token) {
            case .restored:          setToast("Put it back in Play Next")
            case .refusedRanked:     setToast("Kept — you've ranked it since starting")
            case .refusedWouldOrphan: setToast("Can't undo — it's no longer owned")
            case .gameGone:          break
            }
        } catch {
            setToast("Couldn't undo")
        }
        recompute(debounce: false)
    }

    private func registerStartUndo() {
        guard let undo = undoManager, let token = pendingStartUndo else { return }
        undo.registerUndo(withTarget: self) { model in
            Task { await model.performUndoStartPlaying(token) }
        }
        undo.setActionName("Start Playing")
    }

    /// Drop a pending "Start playing" undo (a newer action supersedes it). Clears the
    /// registered UndoManager action too, so ⌘Z after another action doesn't pop a
    /// stale start. Not called from inside an undo (that would mutate the stack
    /// mid-undo).
    private func clearPendingStartUndo() {
        guard pendingStartUndo != nil else { return }
        pendingStartUndo = nil
        undoManager?.removeAllActions(withTarget: self)
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

    private func setToast(_ text: String, undoable: Bool = false) {
        toast = PlayNextToast(text: text, undoable: undoable)
        toastTask?.cancel()
        let duration = undoable ? undoToastDuration : toastDuration
        toastTask = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    func clearToast() { toastTask?.cancel(); toast = nil }

    // MARK: - Persistence

    private func persist() {
        let store = Prefs(defaults: defaults)
        store.shelf = bracketShelf
        store.usesCustom = usesCustom
        store.customHoursSet = customHoursSet
        store.customHoursPerWeek = customHoursPerWeek
        store.customWeeks = customWeeks
        store.completionist = completionist
        store.includeAbandoned = includeAbandoned
        store.includePlayedWithoutStatus = includePlayedWithoutStatus
        store.preferExpiringSubscription = preferExpiringSubscription
        store.includeArchaic = includeArchaic
        store.backtestCutoffYear = backtestCutoffYear
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
    /// The play style shapes the personal lengths sent to Claude, so it is part of the
    /// bracket's identity here (two equal shortlists at different styles differ).
    var style: PlayStyle

    init(result: PlayNextResult) {
        self.shortlist = result.shortlist.map(\.id)
        self.bracketLabel = result.bracket.label
        self.completionist = result.bracket.completionist
        self.style = result.bracket.resolvedStyle
    }
}

// MARK: - Preferences

/// A tiny typed façade over `UserDefaults` for the persisted bracket / options.
private struct Prefs {
    let defaults: UserDefaults
    private enum Key {
        static let preset = "playNext.preset"       // now holds a LengthShelf raw value
        static let usesCustom = "playNext.usesCustom"
        static let customHoursSet = "playNext.customHoursSet"
        static let customHoursPerWeek = "playNext.customHoursPerWeek"
        static let customWeeks = "playNext.customWeeks"
        static let completionist = "playNext.completionist"
        static let includeAbandoned = "playNext.includeAbandoned"
        static let includePlayedWithoutStatus = "playNext.includePlayedWithoutStatus"
        static let preferExpiringSubscription = "playNext.preferExpiringSubscription"
        static let hasShownAskDisclosure = "playNext.hasShownAskDisclosure"
        static let includeArchaic = "playNext.includeArchaic"
        static let backtestCutoffYear = "playNext.backtestCutoffYear"
    }

    /// The remembered bracket, as a ``LengthShelf``. Old four-preset raw values are
    /// migrated to the nearest shelf so no one lands on an invalid selection; an
    /// unknown value → "A Few Weeks".
    var shelf: LengthShelf {
        get {
            guard let raw = defaults.string(forKey: Key.preset) else { return .fewWeeks }
            if let shelf = LengthShelf(rawValue: raw) { return shelf }
            return Self.migrateLegacyPreset(raw)
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.preset) }
    }

    /// Map an old `TimeBracket.Preset` raw value to the nearest new shelf.
    static func migrateLegacyPreset(_ raw: String) -> LengthShelf {
        switch raw {
        case "evening":   return .evening      // (also a valid new value; handled above)
        case "weekOrTwo": return .weekend
        case "month":     return .fewWeeks
        case "longHaul":  return .season
        default:          return .fewWeeks
        }
    }

    var usesCustom: Bool {
        get { defaults.bool(forKey: Key.usesCustom) }
        nonmutating set { defaults.set(newValue, forKey: Key.usesCustom) }
    }
    var customHoursSet: Bool {
        get { defaults.bool(forKey: Key.customHoursSet) }
        nonmutating set { defaults.set(newValue, forKey: Key.customHoursSet) }
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
    /// "Prioritise PS Plus games" — on by default in the UI (the engine's own default stays
    /// off for backtest neutrality; the model passes the persisted value on). PLAN §16.
    var preferExpiringSubscription: Bool {
        get { defaults.object(forKey: Key.preferExpiringSubscription) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.preferExpiringSubscription) }
    }
    var includeArchaic: Bool {
        get { defaults.bool(forKey: Key.includeArchaic) }
        nonmutating set { defaults.set(newValue, forKey: Key.includeArchaic) }
    }
    /// nil (absent) = no cutoff.
    var backtestCutoffYear: Int? {
        get { defaults.object(forKey: Key.backtestCutoffYear) as? Int }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: Key.backtestCutoffYear) }
            else { defaults.removeObject(forKey: Key.backtestCutoffYear) }
        }
    }
    var hasShownAskDisclosure: Bool {
        get { defaults.bool(forKey: Key.hasShownAskDisclosure) }
        nonmutating set { defaults.set(newValue, forKey: Key.hasShownAskDisclosure) }
    }
}
