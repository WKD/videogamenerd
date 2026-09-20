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
    /// The member games, in IGDB order, as compilation drafts (deduped against the
    /// library at commit time by ``LibraryStore/upsertCompilationMember``).
    var members: [CompilationMemberDraft]

    /// Whether this expansion actually yielded members (else fall back to a single).
    var hasMembers: Bool { !members.isEmpty }
}

/// Fetches the member games of an IGDB bundle, on the shared IGDB client / rate limiter
/// (PLAN §5.1). Abstracted behind a protocol so the sync coordinator's tests use a fake
/// and never touch the network — exactly like ``ImportMatcher``.
protocol ImportBundleExpanding: Sendable {
    /// Members of bundle `igdbID`, in IGDB order (add-on content dropped, nested bundles
    /// expanded). Returns `[]` on imperfect coverage — never fails the whole sync.
    func members(ofBundleIGDBID igdbID: Int64) async throws -> [IGDBSearchResult]
}

/// Production expander: reuses ``IGDBClient/bundleMembers(ofBundleID:)`` — the exact
/// §5.1 reverse-lookup path Quick Add and the photo scan already use.
struct IGDBImportBundleExpander: ImportBundleExpanding {
    let client: IGDBClient

    func members(ofBundleIGDBID igdbID: Int64) async throws -> [IGDBSearchResult] {
        try await client.bundleMembers(ofBundleID: igdbID)
    }
}

/// An expander that finds nothing — the safe default when IGDB is not configured, so a
/// bundle match simply commits as a single (today's behaviour) instead of failing.
struct NoBundleExpander: ImportBundleExpanding {
    func members(ofBundleIGDBID igdbID: Int64) async throws -> [IGDBSearchResult] { [] }
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
