import Foundation

/// Maps IGDB metadata into a ``MetadataPatch`` as a set of composable **field
/// groups** (PLAN §9). Structuring it this way is deliberate: §7b will add
/// `game_traits` (franchise/series/developer/theme/mode/perspective/similar) and
/// the IGDB aggregated rating once those columns/tables exist — each becomes one
/// more `apply…` group here, with no reshaping of the metadata job.
///
/// Pure (Foundation only), so it is unit-tested directly.
enum EnrichmentMetadataMapping {

    /// The full patch IGDB metadata would write for a game, before the
    /// "don't clobber user edits" guard is applied by the coordinator.
    static func fullPatch(from meta: IGDBGameMetadata) -> MetadataPatch {
        var patch = MetadataPatch()
        applyCore(meta, into: &patch)
        applyClassification(meta, into: &patch)
        applyCoverImage(meta, into: &patch)
        applyTraits(meta, into: &patch)
        applyRating(meta, into: &patch)
        return patch
    }

    // MARK: - Field groups

    /// Title, summary and release date/year.
    static func applyCore(_ meta: IGDBGameMetadata, into patch: inout MetadataPatch) {
        patch.title = meta.name.isEmpty ? nil : meta.name
        patch.summary = meta.summary
        patch.releaseDate = meta.releaseDate
        patch.year = meta.releaseYear
    }

    /// Genres and alternative / localised titles (the latter feed FTS so a French
    /// box title finds the game, PLAN §5.2/§8).
    static func applyClassification(_ meta: IGDBGameMetadata, into patch: inout MetadataPatch) {
        patch.genres = meta.genres.isEmpty ? nil : meta.genres
        patch.altTitles = meta.alternativeNames.isEmpty ? nil : meta.alternativeNames
    }

    /// IGDB cover `image_id` — the seed the cover job turns into a download URL.
    static func applyCoverImage(_ meta: IGDBGameMetadata, into patch: inout MetadataPatch) {
        patch.igdbCoverImageID = meta.coverImageID
    }

    /// The §7b taste features: franchise / series / developer / theme / mode /
    /// perspective / keyword / similar. `nil` (never an empty array) when IGDB
    /// returned nothing, so the guard treats "no traits" as "leave the field
    /// untouched" rather than wiping the table.
    static func applyTraits(_ meta: IGDBGameMetadata, into patch: inout MetadataPatch) {
        let traits = meta.traits
        patch.traits = traits.isEmpty ? nil : traits
    }

    /// The §7b crowd prior: IGDB aggregated rating + its sample count.
    static func applyRating(_ meta: IGDBGameMetadata, into patch: inout MetadataPatch) {
        patch.igdbRating = meta.igdbRating
        patch.igdbRatingCount = meta.igdbRatingCount
    }
}
