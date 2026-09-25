import Foundation

/// Ties the frail HLTB search (``HLTBSearching``) to the pure ``HLTBMatcher`` and the pure
/// ``HLTBQueryLadder`` (PLAN §5.3): search a title, then decide confident / ambiguous /
/// not-found. The DB write is separate (``LibraryStore/applyHLTBTimes(gameID:candidate:)``)
/// so the ambiguous flow can pause for the user's pick. `Sendable`; the search actor does
/// all the I/O.
struct HLTBFillService: Sendable {
    let search: any HLTBSearching

    init(search: any HLTBSearching) { self.search = search }

    /// The exact outcome of a refresh-by-id (D4).
    enum LinkedOutcome: Sendable, Equatable {
        /// The stored id was found — exact, never ambiguous, never re-asks.
        case exact(HLTBCandidate)
        /// The id is gone from HLTB → fall back to normal matching for a re-pick.
        case lost(HLTBMatchOutcome)
    }

    /// Search + match for one game (PLAN §5.3). Walks the query ladder (≤ 3 queries),
    /// stopping at the **first confident match**; platform overlap (`librarySlugs`) breaks
    /// title ties. Each rung's candidates are scored against the library title *and* the
    /// rung's query (``HLTBMatcher/textScore(title:query:names:)``).
    ///
    /// Wave 21:
    ///  - **cache pass first** (D3): with `.cacheFirst`, every rung already cached is
    ///    evaluated before any request, so a Refresh whose answer is in the cache — even on
    ///    a later rung — costs **zero** requests. Only then are the uncached rungs asked.
    ///  - **never `notFound` while any rung returned plausible rows** (D2c): the candidates
    ///    of every rung are pooled, and the final verdict is taken on the pool — `ambiguous`
    ///    (the picker) as soon as one candidate is plausible; `notFound` only when nothing
    ///    plausible came back from any rung.
    ///
    /// Throws ``ImportError`` on the first unexpected response.
    ///
    /// `cached` (wave 21 E) is an earlier ``resolveFromCache`` pass for this game: its rungs
    /// are reused as-is and the cache pass is skipped, so nothing is re-read or re-tallied.
    func resolve(title: String, year: Int?, librarySlugs: Set<String> = [],
                 policy: HLTBFreshnessPolicy = .cacheFirst,
                 cached: CachePass? = nil) async throws -> HLTBMatchOutcome {
        let queries = HLTBQueryLadder.queries(for: title)
        var answers: [String: [HLTBCandidate]] = cached?.answers ?? [:]

        func confident(_ query: String, _ candidates: [HLTBCandidate]) -> HLTBMatchOutcome? {
            let outcome = HLTBMatcher.match(title: title, year: year, candidates: candidates,
                                            librarySlugs: librarySlugs, query: query)
            if case .confident = outcome { return outcome }
            return nil
        }

        // Pass 1 — whatever the cache already knows (zero requests).
        if policy == .cacheFirst, cached == nil {
            for query in queries {
                guard let cached = await search.cachedCandidates(title: query) else { continue }
                answers[query] = cached
                if let hit = confident(query, cached) { return hit }
            }
        }
        // Pass 2 — the rungs the cache did not answer, in ladder order.
        for query in queries where answers[query] == nil {
            let candidates = try await search.search(title: query, policy: policy)
            answers[query] = candidates
            if let hit = confident(query, candidates) { return hit }
        }
        return Self.pooledVerdict(title: title, year: year, librarySlugs: librarySlugs,
                                  queries: queries, answers: answers)
    }

    /// What the cache alone knows about one game (wave 21 E): the decided `outcome` (nil
    /// when the network must still be asked) plus every cached rung's candidates, which
    /// the later network pass reuses so nothing is looked up — or tallied — twice.
    struct CachePass: Sendable {
        var outcome: HLTBMatchOutcome?
        var answers: [String: [HLTBCandidate]]
    }

    /// The linked-game counterpart of ``CachePass``.
    struct LinkedCachePass: Sendable {
        var outcome: LinkedOutcome?
        var answers: [String: [HLTBCandidate]]
    }

    /// The **cache-only** verdict for one game (wave 21 E) — zero requests, never throws.
    /// Decided when the cache alone settles it: a confident hit on any cached rung, or —
    /// when *every* rung is cached — the pooled verdict. Undecided (nil outcome) when some
    /// rung is uncached and nothing cached was confident. A bulk run resolves every game it
    /// can this way **before** any request, so a sign-in / discovery / search reject never
    /// blocks what the cache already knows.
    func resolveFromCache(title: String, year: Int?, librarySlugs: Set<String> = []) async -> CachePass {
        let queries = HLTBQueryLadder.queries(for: title)
        var answers: [String: [HLTBCandidate]] = [:]
        for query in queries {
            guard let cached = await search.cachedCandidates(title: query) else { continue }
            answers[query] = cached
            let outcome = HLTBMatcher.match(title: title, year: year, candidates: cached,
                                            librarySlugs: librarySlugs, query: query)
            if case .confident = outcome { return CachePass(outcome: outcome, answers: answers) }
        }
        guard answers.count == queries.count else { return CachePass(outcome: nil, answers: answers) }
        return CachePass(outcome: Self.pooledVerdict(title: title, year: year, librarySlugs: librarySlugs,
                                                     queries: queries, answers: answers),
                         answers: answers)
    }

    /// The **cache-only** exact refresh of a linked game (wave 21 E) — zero requests. `.exact`
    /// when a cached reply of any of its queries carries the stored id; `.lost` when every
    /// query is cached and none does; undecided when the cache cannot tell.
    func resolveLinkedFromCache(title: String, year: Int?, hltbID: Int64,
                                librarySlugs: Set<String> = []) async -> LinkedCachePass {
        let queries = await linkedQueries(title: title, hltbID: hltbID)
        var answers: [String: [HLTBCandidate]] = [:]
        for query in queries {
            guard let cached = await search.cachedCandidates(title: query) else { continue }
            if let exact = cached.first(where: { $0.id == hltbID }) {
                return LinkedCachePass(outcome: .exact(exact), answers: answers)
            }
            answers[query] = cached
        }
        guard answers.count == queries.count else { return LinkedCachePass(outcome: nil, answers: answers) }
        return LinkedCachePass(
            outcome: .lost(Self.pooledVerdict(title: title, year: year, librarySlugs: librarySlugs,
                                              queries: queries, answers: answers)),
            answers: answers)
    }

    /// The queries of an exact refresh: the remembered canonical HLTB name, else the ladder.
    private func linkedQueries(title: String, hltbID: Int64) async -> [String] {
        let seededName = await search.linkedCandidate(hltbID: hltbID)?.name
        return seededName.map { [$0] } ?? HLTBQueryLadder.queries(for: title)
    }

    /// The verdict over every rung's candidates at once (D2c): each candidate keeps its best
    /// score across the rung queries; plausible anywhere ⇒ offered (best first).
    static func pooledVerdict(title: String, year: Int?, librarySlugs: Set<String>,
                              queries: [String], answers: [String: [HLTBCandidate]]) -> HLTBMatchOutcome {
        var best: [Int64: HLTBMatcher.Scored] = [:]
        for query in queries {
            for s in HLTBMatcher.scored(title: title, year: year, candidates: answers[query] ?? [],
                                        librarySlugs: librarySlugs, query: query) {
                if let prev = best[s.candidate.id], prev.adjusted >= s.adjusted { continue }
                best[s.candidate.id] = s
            }
        }
        let viable = best.values
            .filter { $0.base >= HLTBMatcher.plausibleThreshold }
            .sorted { a, b in
                if a.adjusted != b.adjusted { return a.adjusted > b.adjusted }
                if a.platformMatch != b.platformMatch { return a.platformMatch }
                return a.candidate.id < b.candidate.id
            }
        guard !viable.isEmpty else { return .notFound }
        return .ambiguous(Array(viable.prefix(HLTBMatcher.maxAmbiguous).map(\.candidate)))
    }

    /// Refresh a game that already carries an `hltb_id` (D4) — **exact**: search by the
    /// remembered canonical HLTB name (from the `id:<hltbID>` cache; the query ladder is the
    /// fallback), then pick the candidate whose id equals the stored id. Never ambiguous,
    /// never re-asks the owner. When the id is absent from the reply, returns `.lost` with a
    /// normal-matching outcome so the caller can offer "pick again".
    ///
    /// `cached` (wave 21 E): an earlier ``resolveLinkedFromCache`` pass — its cached queries
    /// (already known not to carry the id) are not asked again.
    func resolveLinked(title: String, year: Int?, hltbID: Int64, librarySlugs: Set<String> = [],
                       policy: HLTBFreshnessPolicy = .cacheFirst,
                       cached: LinkedCachePass? = nil) async throws -> LinkedOutcome {
        let queries = await linkedQueries(title: title, hltbID: hltbID)
        var answers: [String: [HLTBCandidate]] = cached?.answers ?? [:]
        for query in queries where answers[query] == nil {
            let candidates = try await search.search(title: query, policy: policy)
            if let exact = candidates.first(where: { $0.id == hltbID }) {
                return .exact(exact)
            }
            answers[query] = candidates
        }
        // The id is gone: pool what the queries returned (D2c — plausible ⇒ a re-pick).
        return .lost(Self.pooledVerdict(title: title, year: year, librarySlugs: librarySlugs,
                                        queries: queries, answers: answers))
    }
}
