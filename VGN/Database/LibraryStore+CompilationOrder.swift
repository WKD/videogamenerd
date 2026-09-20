import Foundation

// MARK: - Compilation member ordering (PLAN §5.1, owner request 2026-09-20)

extension LibraryStore {

    /// Order the members of a compilation created from an IGDB bundle by **first release
    /// date, ascending** — the one shared rule for every path that produces members
    /// (Quick Add, photo scan, import review, bundle expansion, reconcile expand). Members
    /// with an unknown date sort last; ties keep IGDB's own order (owner request: "keep
    /// IGDB's order, not release date" was the bug — members were coming out in release
    /// order only by accident; the fix pins a deterministic *release-date* order).
    ///
    /// The **array order is preserved** — only each draft's ``CompilationMemberDraft/position``
    /// is reassigned to the sorted rank — so callers that index into the array (e.g. bundle
    /// expansion's play-data target) are unaffected; the member order shown in the product
    /// is driven purely by `product_games.position`.
    ///
    /// Pure and deterministic. A member's release instant is its `releaseDate` when known,
    /// else 1 January of its `year` (so IGDB search results, which carry only a year, still
    /// order correctly), else unknown.
    static func orderedByReleaseDate(_ members: [CompilationMemberDraft]) -> [CompilationMemberDraft] {
        guard members.count > 1 else { return members }
        // Rank the original indices by (release instant asc, unknown last, IGDB order).
        let ranking = members.indices.sorted { i, j in
            switch (releaseInstant(members[i]), releaseInstant(members[j])) {
            case let (a?, b?): return a != b ? a < b : i < j
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return i < j
            }
        }
        var positionForIndex = [Int](repeating: 0, count: members.count)
        for (rank, originalIndex) in ranking.enumerated() { positionForIndex[originalIndex] = rank }
        var out = members
        for i in out.indices { out[i].position = positionForIndex[i] }
        return out
    }

    /// The comparable release instant of a member draft, or `nil` when unknown.
    private static func releaseInstant(_ member: CompilationMemberDraft) -> Date? {
        if let date = member.releaseDate { return date }
        if let year = member.year {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
            return cal.date(from: DateComponents(year: year, month: 1, day: 1))
        }
        return nil
    }
}
