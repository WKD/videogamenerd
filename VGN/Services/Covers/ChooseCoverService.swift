import Foundation
import CoreGraphics
import GRDB

/// The app's `CoverLoading` in live / sample mode: it forwards grid-thumbnail
/// loading straight to the ``CoverStore`` and adds the "Choose Cover…" operations
/// (PLAN §5.2 step 4) by also holding the ``LibraryStore``. Injecting one object as
/// `vm.coverLoader` lets the inspector reach the whole feature with
/// `coverLoader as? any ChooseCoverProviding` — no new view-tree wiring.
///
/// A chosen candidate / file takes the **same** write path a dragged image does:
/// the `CoverStore` files the original, then ``LibraryStore/setUserCover(gameID:coverFile:)``
/// records it and marks the `cover` field user-edited, so background enrichment
/// (even an explicit refresh) never clobbers it.
///
/// `allowsNetwork` is false outside live mode: sample mode must never touch the
/// network (CLAUDE.md), so candidate listing returns `[]` there — the sheet still
/// offers the local "Choose File…" path.
final class ChooseCoverService: CoverLoading, ChooseCoverProviding {
    private let coverStore: CoverStore
    private let library: LibraryStore
    private let allowsNetwork: Bool
    /// IGDB client for the on-demand artwork fetch (PLAN §5.2 step 4, D1). `nil` offline /
    /// sample mode → the sheet offers the game's cover + libretro only, never the network.
    private let igdbClient: IGDBClient?

    init(coverStore: CoverStore, library: LibraryStore, allowsNetwork: Bool,
         igdbClient: IGDBClient? = nil) {
        self.coverStore = coverStore
        self.library = library
        self.allowsNetwork = allowsNetwork
        self.igdbClient = igdbClient
    }

    // MARK: CoverLoading (grid / inspector thumbnails)

    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> sending CGImage? {
        await coverStore.thumbnail(for: coverFile, pixelSize: pixelSize)
    }

    // MARK: ChooseCoverProviding

    func coverCandidates(forGameID id: Int64) async -> [CoverCandidate] {
        guard allowsNetwork else { return [] }
        guard let resolved = try? await coverQuery(forGameID: id) else { return [] }
        // The chain: libretro (per platform) + the IGDB key-art cover.
        var candidates = await coverStore.candidates(for: resolved.query)
        // D1: IGDB also contributes the game's artworks as candidates — fetched on demand
        // through the shared client + rate limiter, grouped with the IGDB cover.
        if let igdbID = resolved.igdbID, let client = igdbClient {
            let artworks = (try? await client.artworks(forGameID: igdbID)) ?? []
            candidates += artworks.compactMap(Self.artworkCandidate)
        }
        return candidates
    }

    /// Map one IGDB artwork to a browsable cover candidate (PLAN §5.2 step 4). Grouped
    /// with the IGDB cover (same `providerID`), labelled a plausible alternative, not the
    /// exact key art.
    private static func artworkCandidate(_ art: IGDBArtwork) -> CoverCandidate? {
        guard let url = IGDBImageURL.artwork(imageID: art.imageID) else { return nil }
        let size: CGSize? = {
            guard let w = art.width, let h = art.height, w > 0, h > 0 else { return nil }
            return CGSize(width: w, height: h)
        }()
        return CoverCandidate(
            providerID: "igdb", remoteURL: url, label: "IGDB artwork",
            score: 0.5, isConfident: false, region: nil, kind: "artwork", pixelSize: size)
    }

    func candidateThumbnail(for candidate: CoverCandidate, maxPixel: Int) async -> sending CGImage? {
        await coverStore.candidatePreview(from: candidate.remoteURL, maxPixel: maxPixel)
    }

    func chooseCandidate(_ candidate: CoverCandidate, forGameID id: Int64) async throws {
        let stored = try await coverStore.chooseRemoteCover(from: candidate.remoteURL, gameID: id)
        try await library.setUserCover(gameID: id, coverFile: stored.coverFile)
    }

    func importCoverFile(_ url: URL, forGameID id: Int64) async throws {
        let stored = try await coverStore.importCover(from: url, gameID: id)
        try await library.setUserCover(gameID: id, coverFile: stored.coverFile)
    }

    // MARK: Query

    /// Build the same `CoverQuery` the enrichment cover job uses (title, alternative
    /// names, every platform slug from the game and its products, IGDB cover id), plus the
    /// game's IGDB id for the on-demand artwork fetch. Returns `nil` if the game no longer
    /// exists.
    private func coverQuery(forGameID id: Int64) async throws -> (query: CoverQuery, igdbID: Int64?)? {
        try await library.dbReader.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT title, alt_titles, igdb_cover_image_id, igdb_id FROM games WHERE id = ?",
                arguments: [id])
            else { return nil }
            let slugs = try String.fetchAll(db, sql: """
                SELECT DISTINCT pid FROM (
                  SELECT platform_id AS pid FROM game_platforms WHERE game_id = ?1
                  UNION
                  SELECT p.platform_id FROM products p JOIN product_games pg ON pg.product_id = p.id
                  WHERE pg.game_id = ?1
                )
                """, arguments: [id])
            let altRaw: String = row["alt_titles"] ?? ""
            let query = CoverQuery(
                title: row["title"],
                alternativeNames: altRaw.split(separator: "\n").map(String.init),
                platformSlugs: slugs,
                igdbCoverImageID: row["igdb_cover_image_id"]
            )
            return (query, row["igdb_id"])
        }
    }
}
