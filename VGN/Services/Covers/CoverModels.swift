import Foundation
import CoreGraphics

/// Everything a `CoverProvider` needs to find box art for one game (PLAN §5.2).
struct CoverQuery: Sendable, Equatable {
    /// The game's primary title (as IGDB spells it).
    var title: String
    /// Alternative / localised names, to widen the libretro match (French box titles,
    /// Japanese names…).
    var alternativeNames: [String]
    /// VGN platform slugs the game is on. libretro is tried per slug that has a repo.
    var platformSlugs: [String]
    /// IGDB cover `image_id`, when known — the always-available fallback.
    var igdbCoverImageID: String?
    /// Region preference, best first (Europe/France → USA → Japan by default).
    var preferredRegions: [String]

    init(
        title: String,
        alternativeNames: [String] = [],
        platformSlugs: [String] = [],
        igdbCoverImageID: String? = nil,
        preferredRegions: [String] = LibretroIndex.defaultRegionPreference
    ) {
        self.title = title
        self.alternativeNames = alternativeNames
        self.platformSlugs = platformSlugs
        self.igdbCoverImageID = igdbCoverImageID
        self.preferredRegions = preferredRegions
    }
}

/// One candidate cover from some provider. The chain returns these ordered
/// best-first; the future "Choose Cover…" sheet browses all of them (PLAN §5.2).
struct CoverCandidate: Sendable, Equatable, Identifiable {
    /// Provider that produced it ("libretro", "igdb").
    var providerID: String
    /// Where to download it from.
    var remoteURL: URL
    /// Human label, e.g. "libretro · Europe" or "IGDB cover".
    var label: String
    /// Match confidence in [0, 1] (1 for the IGDB key-art fallback, which is exact).
    var score: Double
    /// Whether this candidate is a confident hit (≥ `FuzzyMatch.confidentThreshold`)
    /// or merely plausible — the chain stops on the first confident/exact hit but
    /// keeps plausible ones browsable.
    var isConfident: Bool
    /// Region / variant of this candidate when known (e.g. "Europe", "Japan"), for
    /// the "Choose Cover…" sheet's per-tile label. `nil` when the provider can't
    /// tell (e.g. the IGDB key-art fallback).
    var region: String? = nil
    /// Pixel dimensions of the source image when known ahead of download (the IGDB
    /// size tokens have fixed dimensions; libretro sizes are unknown until fetched).
    var pixelSize: CGSize? = nil

    var id: String { "\(providerID)|\(remoteURL.absoluteString)" }
}

/// A cover the `CoverStore` has downloaded and filed permanently (PLAN §5.2: covers
/// are library assets). `coverFile` is the relative file name the DB stores in
/// `games.cover_file`.
struct StoredCover: Sendable, Equatable {
    var coverFile: String
    var providerID: String
    /// All candidates the chain found (so the UI can offer alternatives without
    /// re-running providers).
    var candidates: [CoverCandidate]
}
