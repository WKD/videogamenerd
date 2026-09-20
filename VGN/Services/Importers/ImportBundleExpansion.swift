import Foundation

/// A bundle/pack match resolved during the import matching phase (PLAN §5.1). When an
/// imported title's best IGDB match is a bundle, its member games are fetched up front
/// (on the shared IGDB pipeline, never at commit time on the main actor) so the review
/// row can be committed as a **compilation** Product rather than one lonely single that
/// points at the bundle entry — the owner bug that turned "The Tomb Raider Trilogy" and
/// "God of War Collection" into single games (2026-09-20).
///
/// `members` empty ⇒ IGDB had no member list for this bundle: the caller falls back to
/// today's single-game behaviour and flags the row, never blocking the import.
struct ImportBundleExpansion: Sendable, Equatable, Codable {
    /// The bundle's own IGDB id (the game a single would otherwise link to).
    var bundleIGDBID: Int64
    /// The bundle's title — used as the compilation Product's title.
    var title: String
    /// The member games, in release order, as compilation drafts (deduped against the
    /// library at commit time by ``LibraryStore/upsertCompilationMember``). Non-standalone
    /// content is already dropped and ports folded onto their parent by the member policy.
    var members: [CompilationMemberDraft]
    /// What the member policy dropped or folded (PLAN §5.1), so the review sheet's bundle
    /// row can show "Left out: …". Defaults to empty and decodes tolerantly (older
    /// persisted `match_json` had no such key).
    var leftOut: [BundleLeftOut]

    init(bundleIGDBID: Int64, title: String, members: [CompilationMemberDraft],
         leftOut: [BundleLeftOut] = []) {
        self.bundleIGDBID = bundleIGDBID
        self.title = title
        self.members = members
        self.leftOut = leftOut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIGDBID = try c.decode(Int64.self, forKey: .bundleIGDBID)
        title = try c.decode(String.self, forKey: .title)
        members = try c.decode([CompilationMemberDraft].self, forKey: .members)
        leftOut = try c.decodeIfPresent([BundleLeftOut].self, forKey: .leftOut) ?? []
    }

    /// Whether this expansion actually yielded members (else fall back to a single).
    var hasMembers: Bool { !members.isEmpty }
    /// PLAN §5.1: two or more members is worth a compilation; fewer is not.
    var isWorthCompilation: Bool { members.count >= 2 }
}

/// Fetches the member games of an IGDB bundle, on the shared IGDB client / rate limiter
/// (PLAN §5.1). Abstracted behind a protocol so the sync coordinator's tests use a fake
/// and never touch the network — exactly like ``ImportMatcher``.
protocol ImportBundleExpanding: Sendable {
    /// Members of bundle `igdbID` after the one member policy (PLAN §5.1): non-standalone
    /// content dropped and ports folded onto their parent, with the ``BundleMemberResult/leftOut``
    /// notes. Returns an empty result on imperfect coverage — never fails the whole sync.
    func members(ofBundleIGDBID igdbID: Int64) async throws -> BundleMemberResult
}

/// Production expander: reuses ``IGDBClient/bundleMembers(ofBundleID:)`` — the exact
/// §5.1 reverse-lookup + member-policy path Quick Add and the photo scan already use.
struct IGDBImportBundleExpander: ImportBundleExpanding {
    let client: IGDBClient

    func members(ofBundleIGDBID igdbID: Int64) async throws -> BundleMemberResult {
        try await client.bundleMembers(ofBundleID: igdbID)
    }
}

/// An expander that finds nothing — the safe default when IGDB is not configured, so a
/// bundle match simply commits as a single (today's behaviour) instead of failing.
struct NoBundleExpander: ImportBundleExpanding {
    func members(ofBundleIGDBID igdbID: Int64) async throws -> BundleMemberResult { BundleMemberResult() }
}

enum ImportBundleMapping {
    /// Map fetched IGDB member results to ordered ``CompilationMemberDraft`` values
    /// (owned, not played — an imported copy never invents a played flag, PLAN §14.3).
    static func members(from results: [IGDBSearchResult]) -> [CompilationMemberDraft] {
        results.enumerated().map { index, m in
            CompilationMemberDraft(
                title: m.name, igdbID: m.id, year: m.releaseYear,
                altTitles: m.alternativeNames, played: false, position: index)
        }
    }
}
