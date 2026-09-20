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

    /// Search + match for one game (PLAN §5.3, D2/D3). Walks the query ladder (edition /
    /// packaging noise, at most 3 queries), stopping at the **first confident match**;
    /// platform overlap (`librarySlugs`) breaks title ties. Falls back to the richest
    /// ambiguous set seen, else not-found. `policy` lets an explicit Refresh honour the
    /// 24 h cache floor. Throws ``ImportError`` on the first unexpected response.
    func resolve(title: String, year: Int?, librarySlugs: Set<String> = [],
                 policy: HLTBFreshnessPolicy = .cacheFirst) async throws -> HLTBMatchOutcome {
        var lastAmbiguous: [HLTBCandidate] = []
        for query in HLTBQueryLadder.queries(for: title) {
            let candidates = try await search.search(title: query, policy: policy)
            let outcome = HLTBMatcher.match(title: query, year: year,
                                            candidates: candidates, librarySlugs: librarySlugs)
            switch outcome {
            case .confident:
                return outcome
            case .ambiguous(let list):
                lastAmbiguous = list   // keep the richest ambiguous set the ladder produced
            case .notFound:
                break
            }
        }
        return lastAmbiguous.isEmpty ? .notFound : .ambiguous(lastAmbiguous)
    }

    /// Refresh a game that already carries an `hltb_id` (D4) — **exact**: search by the
    /// remembered canonical HLTB name (from the `id:<hltbID>` cache; the query ladder is the
    /// fallback), then pick the candidate whose id equals the stored id. Never ambiguous,
    /// never re-asks the owner. When the id is absent from the reply, returns `.lost` with a
    /// normal-matching outcome so the caller can offer "pick again".
    func resolveLinked(title: String, year: Int?, hltbID: Int64, librarySlugs: Set<String> = [],
                       policy: HLTBFreshnessPolicy = .cacheFirst) async throws -> LinkedOutcome {
        let seededName = await search.linkedCandidate(hltbID: hltbID)?.name
        let queries = seededName.map { [$0] } ?? HLTBQueryLadder.queries(for: title)
        var lastSeen: [HLTBCandidate] = []
        for query in queries {
            let candidates = try await search.search(title: query, policy: policy)
            if let exact = candidates.first(where: { $0.id == hltbID }) {
                return .exact(exact)
            }
            if !candidates.isEmpty { lastSeen = candidates }
        }
        return .lost(HLTBMatcher.match(title: title, year: year,
                                       candidates: lastSeen, librarySlugs: librarySlugs))
    }
}
