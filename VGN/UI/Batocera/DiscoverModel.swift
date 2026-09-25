import Foundation

/// One Discover card: a scored, never-played catalogue entry with its taste-reason sentences
/// and match-strength badge (PLAN §15). `id` is the catalogue row id.
struct DiscoverItem: Identifiable, Sendable, Equatable {
    var entry: RomCatalogEntry
    var sentences: [String]
    var strength: MatchStrength
    var id: Int64 { entry.id }
}

/// Drives the "Discover on your Batocera" row in Play Next (PLAN §15). Loads the taste profile
/// + the never-played catalogue pool, scores the pool by the owner's taste with
/// ``DiscoverScorer`` **off the main actor**, and rotates the top with a deterministic weekly
/// seed (a "Shuffle" re-rolls within the week). Hidden when the catalogue is empty or Play
/// Next has "not enough data" (no ranked games).
///
/// `@MainActor @Observable`; built with a fake ``DiscoverBackend`` in tests (no database).
@MainActor
@Observable
final class DiscoverModel {
    private let backend: any DiscoverBackend
    let thumbnails: BatoceraThumbnailLoader?
    /// How many cards to surface (PLAN §15 "5–8 cards").
    let cardCount: Int
    /// How large a pool to score (all present never-played rows on the owner's box).
    let poolLimit: Int
    /// Injectable clock for the ISO-week rotation seed (deterministic in tests).
    var now: () -> Date = { Date() }
    /// Opens a URL (the "Open on IGDB" card button, D7). Injected so tests capture it and NOTHING
    /// is opened during a test run; the app passes ``BatoceraEnvironment/openURL``.
    @ObservationIgnored var openURL: (URL) -> Void

    /// The owner's play style / weekly pace, for the PS Plus deadline finishability (PLAN §16).
    private let playStyle: PlayStyle
    private let pace: PlayPace
    /// Prioritise PS Plus games with the constant boost when no cancellation date is set
    /// (PLAN §16 — the "Prioritise PS Plus games" fallback, on by default). Mirrors Play Next.
    private let prioritisePSPlus: Bool
    /// Months until the owner plans to leave PS Plus (nil ⇒ no date), read fresh each recompute.
    private let deadlineMonthsLeft: @MainActor () -> Double?
    @ObservationIgnored nonisolated(unsafe) private var deadlineObserver: NSObjectProtocol?

    private(set) var items: [DiscoverItem] = []
    /// The vault shortlist behind "Ask Claude" (PLAN §7b): the scorer's top ~10 for the chosen
    /// bracket, best first. The first ``cardCount`` of them are the visible cards.
    private(set) var shortlist: [RomCatalogEntry] = []
    /// The Play Next bracket the vault is fitted to (nil ⇒ no time-fit term, as before).
    private(set) var bracket: TimeBracket?

    // MARK: Ask Claude (PLAN §7b "Ask Claude for From the vault")

    /// The on-demand second opinion over ``shortlist`` — the same state machine as Play Next's.
    private(set) var secondOpinionState: SecondOpinionState = .idle
    /// Seconds since the current ask started (the "Thinking… N s" spinner).
    private(set) var secondOpinionElapsed = 0
    @ObservationIgnored private let secondOpinion: (any SecondOpinionProviding)?
    @ObservationIgnored private var secondOpinionCache: [DiscoverSecondOpinion.CacheKey: SecondOpinion] = [:]
    @ObservationIgnored private var activeSecondOpinionKey: DiscoverSecondOpinion.CacheKey?
    @ObservationIgnored private var askTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    private(set) var rankedCount = 0
    private(set) var poolCount = 0
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var shuffleCount = 0

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(backend: any DiscoverBackend, thumbnails: BatoceraThumbnailLoader? = nil,
         cardCount: Int = 8, poolLimit: Int = 12_000,
         playStyle: PlayStyle = UserDefaultsPlayPacePreferences().playStyle(),
         pace: PlayPace = UserDefaultsPlayPacePreferences().playPace(),
         prioritisePSPlus: Bool = DiscoverModel.prioritisePSPlusDefault(),
         deadlineMonthsLeft: @escaping @MainActor () -> Double? = { PSPlusDeadlinePreferences().monthsLeft() },
         openURL: @escaping (URL) -> Void = { _ in },
         bracket: TimeBracket? = nil,
         secondOpinion: (any SecondOpinionProviding)? = nil) {
        self.backend = backend
        self.thumbnails = thumbnails
        self.cardCount = cardCount
        self.poolLimit = poolLimit
        self.playStyle = playStyle
        self.pace = pace
        self.prioritisePSPlus = prioritisePSPlus
        self.deadlineMonthsLeft = deadlineMonthsLeft
        self.openURL = openURL
        self.bracket = bracket
        self.secondOpinion = secondOpinion
    }

    // MARK: - Open on IGDB (D7)

    /// The IGDB web URL for an entry that carries an `igdb_id`, or nil (no button then).
    /// Delegates to the shared ``IGDBWebLink`` helper — the same canonical link Play Next's
    /// hero card uses (owner 2026-09-20) — so every "Open on IGDB" affordance is one scheme.
    nonisolated static func igdbURL(for entry: RomCatalogEntry) -> URL? {
        IGDBWebLink.pageURL(igdbID: entry.igdbID, title: entry.name)
    }

    /// Open a vault card's IGDB page through the injected opener (D7). No-op when unmatched.
    func openIGDB(_ entry: RomCatalogEntry) {
        guard let url = Self.igdbURL(for: entry) else { return }
        openURL(url)
    }

    deinit {
        if let deadlineObserver { NotificationCenter.default.removeObserver(deadlineObserver) }
    }

    /// The "Prioritise PS Plus games" default (shared with Play Next's persisted toggle, on by
    /// default). Read here so the vault scorer's constant fallback matches the picks.
    static func prioritisePSPlusDefault() -> Bool {
        AppPreferences.defaults.object(forKey: "playNext.preferExpiringSubscription") as? Bool ?? true
    }

    /// Whether the row should be shown at all (PLAN §15 visibility rule).
    var isVisible: Bool { hasLoaded && rankedCount > 0 && !items.isEmpty }

    /// Load + score once. Idempotent per call site (a reload cancels the prior run).
    func load() {
        observeDeadlineChanges()
        recompute()
    }

    /// Recompute once when the PS Plus cancellation date changes in Settings (PLAN §16).
    private func observeDeadlineChanges() {
        guard deadlineObserver == nil else { return }
        deadlineObserver = NotificationCenter.default.addObserver(
            forName: PSPlusDeadlinePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
    }

    /// Follow the Play Next bracket: the vault scorer fits it (time fit when a length is known)
    /// and the "Ask Claude" cache is keyed by it. A no-op when unchanged.
    func setBracket(_ newBracket: TimeBracket?) {
        guard newBracket != bracket else { return }
        bracket = newBracket
        if hasLoaded || isLoading { recompute() }
    }

    /// "Shuffle" — re-roll the rotation within the current week (PLAN §15).
    func shuffle() { shuffleCount += 1; recompute() }

    /// Retire an entry from Discover for good ("Not Interested"), then drop it from the row.
    func notInterested(_ entry: RomCatalogEntry) {
        items.removeAll { $0.entry.id == entry.id }
        shortlist.removeAll { $0.id == entry.id }
        let backend = self.backend
        Task { try? await backend.setNotInterested(catalogID: entry.id) }
    }

    private func recompute() {
        loadTask?.cancel()
        isLoading = true
        let backend = self.backend
        let poolLimit = self.poolLimit
        let cardCount = self.cardCount
        let seed = Self.rotationSeed(date: now(), shuffle: shuffleCount)
        let playStyle = self.playStyle
        let pace = self.pace
        let prioritisePSPlus = self.prioritisePSPlus
        let monthsLeft = deadlineMonthsLeft()
        let bracket = self.bracket
        let shortlistSize = max(cardCount, DiscoverSecondOpinion.shortlistSize)
        loadTask = Task { [weak self] in
            do {
                let ranked = try await backend.rankedGames()
                let pool = try await backend.pool(limit: poolLimit)
                let played = try await backend.playedSystems()
                if Task.isCancelled { return }

                // At most half the visible cards may be pinned favourites, so the row still
                // discovers (PLAN §15).
                let options = DiscoverScorer.Options(
                    seed: seed, playedSystems: played,
                    maxPinnedFavourites: max(1, cardCount / 2),
                    bracket: bracket, playStyle: playStyle, pace: pace,
                    psPlusMonthsLeft: monthsLeft, prioritisePSPlus: prioritisePSPlus,
                    // The personal pace factor rides on the Play Next bracket (wave 22).
                    paceFactor: bracket?.paceFactor ?? 1.0)
                // Score off the main actor (pure, ~11 000 entries — PLAN §15 perf).
                let scored = await Task.detached(priority: .userInitiated) {
                    Array(DiscoverScorer.score(entries: pool, ranked: ranked, options: options)
                        .prefix(shortlistSize))
                }.value
                let top = Array(scored.prefix(cardCount))

                // Resolve the cited exemplars for the reason sentences.
                let exemplarIDs = top.flatMap { Self.exemplarIDs(in: $0.reasons) }
                let exemplars = (try? await backend.exemplarInfo(ids: exemplarIDs)) ?? [:]
                if Task.isCancelled { return }

                let items = top.map { scored in
                    DiscoverItem(
                        entry: scored.entry,
                        sentences: PlayNextReasonFormatter.sentences(
                            for: scored.reasons, exemplars: exemplars, limit: 2),
                        strength: scored.strength)
                }
                guard let self, !Task.isCancelled else { return }
                self.rankedCount = ranked.count
                self.poolCount = pool.count
                self.items = items
                self.shortlist = scored.map(\.entry)
                self.invalidateStaleSecondOpinion()
                self.hasLoaded = true
                self.isLoading = false
            } catch {
                guard let self else { return }
                self.hasLoaded = true
                self.isLoading = false
            }
        }
    }

    // MARK: - Ask Claude (PLAN §7b "Ask Claude for From the vault")

    /// Whether the "Ask Claude" button can run (a provider is wired and there is a shortlist).
    var canAskClaude: Bool { secondOpinion != nil && !shortlist.isEmpty }

    /// Whether the Claude column is showing (asking, answered or failed).
    var secondOpinionActive: Bool { secondOpinionState != .idle }

    /// The cache key for the current shortlist + bracket.
    var currentSecondOpinionKey: DiscoverSecondOpinion.CacheKey {
        DiscoverSecondOpinion.CacheKey(shortlist: shortlist.map(\.id), bracket: bracket)
    }

    /// A shortlist entry by catalogue id (Claude's picks are always shortlist ids).
    func shortlistEntry(for id: Int64) -> RomCatalogEntry? {
        shortlist.first { $0.id == id }
    }

    /// True when the scorer and Claude agree on the same #1.
    var secondOpinionAgreesOnTop: Bool {
        guard case let .result(opinion) = secondOpinionState,
              let engineTop = shortlist.first?.id,
              let claudeTop = opinion.picks.first?.gameID else { return false }
        return engineTop == claudeTop
    }

    /// Ask Claude to re-order the vault shortlist. On demand only; cached per
    /// (shortlist, bracket) for the session; cancellable; a failure explains itself and the
    /// scorer's order stands. Nothing is stored — no rating, no DB write.
    func askClaude() {
        guard let provider = secondOpinion, !shortlist.isEmpty else { return }
        let key = currentSecondOpinionKey
        if let cached = secondOpinionCache[key] {
            activeSecondOpinionKey = key
            secondOpinionState = .result(cached)
            return
        }

        askTask?.cancel()
        activeSecondOpinionKey = key
        secondOpinionState = .asking
        startElapsedTimer()

        let backend = self.backend
        let entries = self.shortlist
        let bracket = self.bracket
        let playStyle = self.playStyle
        let monthsLeft = deadlineMonthsLeft()
        askTask = Task { [weak self] in
            do {
                let taste = try await backend.secondOpinionTaste()
                let request = DiscoverSecondOpinion.request(
                    shortlist: entries, taste: taste, bracket: bracket,
                    playStyle: playStyle, psPlusMonthsLeft: monthsLeft)
                let opinion = try await provider.secondOpinion(for: request)
                // Belt and braces: Claude may re-order, never add (the live provider already
                // discards foreign ids; a stub or a future provider might not).
                let allowed = Set(entries.map(\.id))
                let picks = opinion.picks.filter { allowed.contains($0.gameID) }
                guard let self, !Task.isCancelled else { return }
                if picks.isEmpty {
                    self.secondOpinionState = .failed(.empty)
                } else {
                    let kept = SecondOpinion(picks: picks, model: opinion.model, metrics: opinion.metrics)
                    self.secondOpinionCache[key] = kept
                    if self.activeSecondOpinionKey == key { self.secondOpinionState = .result(kept) }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                let failure = SecondOpinionError.wrap(error)
                self.secondOpinionState = failure == .cancelled ? .idle : .failed(failure)
            }
            self?.stopElapsedTimer()
        }
    }

    /// Cancel an ask in flight; the scorer's order stands.
    func cancelSecondOpinion() {
        askTask?.cancel()
        stopElapsedTimer()
        secondOpinionState = .idle
        activeSecondOpinionKey = nil
    }

    /// Close the Claude column without re-running (the cached answer stays for the session).
    func dismissSecondOpinion() {
        secondOpinionState = .idle
    }

    /// A new shortlist or bracket makes a showing / pending answer stale.
    private func invalidateStaleSecondOpinion() {
        guard let active = activeSecondOpinionKey, active != currentSecondOpinionKey else { return }
        askTask?.cancel()
        stopElapsedTimer()
        secondOpinionState = .idle
        activeSecondOpinionKey = nil
    }

    private func startElapsedTimer() {
        secondOpinionElapsed = 0
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                self.secondOpinionElapsed += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private static func exemplarIDs(in reasons: [PlayNextReason]) -> [Int64] {
        reasons.compactMap { reason in
            switch reason {
            case let .sharedFranchise(_, with): return with
            case let .sharedSeries(_, with): return with
            case let .sameDeveloper(_, exemplar): return exemplar
            case let .similarTo(exemplar): return exemplar
            default: return nil
            }
        }
    }

    /// The deterministic rotation seed: the ISO week (stable within a week, changes across
    /// weeks) perturbed by the "Shuffle" counter. Pure — safe off the main actor.
    nonisolated static func rotationSeed(date: Date, shuffle: Int) -> UInt64 {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone.current
        let comps = calendar.dateComponents([.weekOfYear, .yearForWeekOfYear], from: date)
        let year = UInt64(comps.yearForWeekOfYear ?? 2026)
        let week = UInt64(comps.weekOfYear ?? 1)
        let base = year &* 54 &+ week
        return base &+ UInt64(bitPattern: Int64(shuffle)) &* 0x9E37_79B9_7F4A_7C15
    }
}
