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
         openURL: @escaping (URL) -> Void = { _ in }) {
        self.backend = backend
        self.thumbnails = thumbnails
        self.cardCount = cardCount
        self.poolLimit = poolLimit
        self.playStyle = playStyle
        self.pace = pace
        self.prioritisePSPlus = prioritisePSPlus
        self.deadlineMonthsLeft = deadlineMonthsLeft
        self.openURL = openURL
    }

    // MARK: - Open on IGDB (D7)

    /// The IGDB web URL for an entry that carries an `igdb_id`, or nil (no button then).
    // TODO(merge): replace with the shared `IGDBWebLink` helper (wave-17-B) once it lands — that
    // one builds a canonical `/games/<id>` URL from the id; this reuses the reconcile sheet's
    // search-by-name scheme, which is what this lane's base has.
    nonisolated static func igdbURL(for entry: RomCatalogEntry) -> URL? {
        guard entry.igdbID != nil else { return nil }
        var comps = URLComponents(string: "https://www.igdb.com/search")
        comps?.queryItems = [URLQueryItem(name: "type", value: "1"),
                             URLQueryItem(name: "q", value: entry.name)]
        return comps?.url
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

    /// "Shuffle" — re-roll the rotation within the current week (PLAN §15).
    func shuffle() { shuffleCount += 1; recompute() }

    /// Retire an entry from Discover for good ("Not Interested"), then drop it from the row.
    func notInterested(_ entry: RomCatalogEntry) {
        items.removeAll { $0.entry.id == entry.id }
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
                    playStyle: playStyle, pace: pace,
                    psPlusMonthsLeft: monthsLeft, prioritisePSPlus: prioritisePSPlus)
                // Score off the main actor (pure, ~11 000 entries — PLAN §15 perf).
                let top = await Task.detached(priority: .userInitiated) {
                    Array(DiscoverScorer.score(entries: pool, ranked: ranked, options: options)
                        .prefix(cardCount))
                }.value

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
                self.hasLoaded = true
                self.isLoading = false
            } catch {
                guard let self else { return }
                self.hasLoaded = true
                self.isLoading = false
            }
        }
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
