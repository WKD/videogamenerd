import Foundation

/// Which IGDB query "shape" (field set) a cached `catalog_cache` payload satisfies
/// (PLAN §4/§9, W19 read cache). The cache is keyed by igdb id, but a game's JSON
/// blob may have been written by a query with FEWER fields than a later caller needs
/// — search results are slimmer than the metadata query; artworks and bundle-member
/// lists are separate queries. So we record, INSIDE the blob (`_vgn_fields`, an
/// `OptionSet` bitmask — no schema change), which field sets it holds and only serve
/// a hit when the cached blob's shapes ⊇ the caller's need. A blob whose marker is
/// absent or unknown is treated as satisfying nothing (a miss), so it is refetched
/// and re-tagged.
///
/// This is a cache for *speed* only — a hit avoids a request we would otherwise make
/// for data we already hold. It never lets a caller issue more, faster or parallel
/// requests: a miss still goes through the client's one `RateLimiter`, unchanged.
struct CatalogFieldShape: OptionSet, Sendable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// The slim search field set (`IGDBFields.search`): name, cover, platforms, genres,
    /// alt names, game_type, slug, parent/version — enough for a search result.
    static let search = CatalogFieldShape(rawValue: 1 << 0)
    /// The full metadata field set (`IGDBFields.full`): everything `search` has plus
    /// summary, the §7b traits, crowd rating and the bundle relation. A `full` fetch
    /// satisfies both `.search` and `.metadata`.
    static let metadata = CatalogFieldShape(rawValue: 1 << 1)
    /// The Choose Cover artworks field set (`IGDBFields.artworks`).
    static let artworks = CatalogFieldShape(rawValue: 1 << 2)
    /// The bundle's expanded member-id list is cached in the bundle's own blob.
    static let bundleMembers = CatalogFieldShape(rawValue: 1 << 3)

    /// The shapes a `/v4/games` query with `fields` yields. `full` implies `search`.
    static func shapes(forFields fields: [String]) -> CatalogFieldShape {
        if fields == IGDBFields.full { return [.search, .metadata] }
        if fields == IGDBFields.artworks { return .artworks }
        return .search
    }
}

/// Reads/writes the `_vgn_fields` shape marker, the **per-shape fetched-at stamps**
/// (`_vgn_fetched`, keyed by the shape's bit value) and the `_vgn_bundle_members`
/// list carried inside a cached IGDB game blob. Pure JSON surgery — no network, no DB.
///
/// Per-shape freshness (W19 part 2A): a blob's fields may have been written by several
/// queries at different times — a search sighting today must NOT make months-old full
/// metadata look fresh. So each shape carries its own timestamp and a read is a hit
/// only when the needed shape is present *and* its own stamp is within `staleAfter`.
/// Blobs written before this (a mask but no stamps) fall back to the row's
/// `fetched_at` for every shape they carry — safe, since those rows are at most hours old.
enum CatalogCacheShapeJSON {
    static let fieldsKey = "_vgn_fields"
    static let fetchedKey = "_vgn_fetched"
    static let bundleMembersKey = "_vgn_bundle_members"

    /// The individual shape bits VGN defines (search / metadata / artworks / bundleMembers).
    static let allShapes: [CatalogFieldShape] = [.search, .metadata, .artworks, .bundleMembers]

    /// The shapes a cached blob satisfies (empty when the marker is absent/unknown).
    static func shapes(in json: Data) -> CatalogFieldShape {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let raw = (object[fieldsKey] as? NSNumber)?.intValue
        else { return [] }
        return CatalogFieldShape(rawValue: raw)
    }

    /// Per-shape fetched-at stamps, keyed by the shape's bit value.
    static func fetchedStamps(in json: Data) -> [Int: Date] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let raw = object[fetchedKey] as? [String: Any]
        else { return [:] }
        var out: [Int: Date] = [:]
        for (key, value) in raw {
            if let bit = Int(key), let secs = (value as? NSNumber)?.doubleValue {
                out[bit] = Date(timeIntervalSince1970: secs)
            }
        }
        return out
    }

    /// Is `json` a hit for `shape` — present in the mask AND each of the shape's bits
    /// stamped within `staleAfter` of `now` (falling back to `rowFetchedAt` for a bit
    /// with no stamp, i.e. a pre-part-2 blob)?
    static func isFresh(
        _ json: Data, satisfying shape: CatalogFieldShape,
        rowFetchedAt: Date, now: Date, staleAfter: TimeInterval
    ) -> Bool {
        guard shapes(in: json).isSuperset(of: shape) else { return false }
        let stamps = fetchedStamps(in: json)
        for bit in allShapes where shape.contains(bit) {
            let stamp = stamps[bit.rawValue] ?? rowFetchedAt
            if now.timeIntervalSince(stamp) >= staleAfter { return false }
        }
        return true
    }

    /// The cached expanded member-id list of a bundle blob, or `nil` when absent.
    static func bundleMemberIDs(in json: Data) -> [Int64]? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let raw = object[bundleMembersKey] as? [Any]
        else { return nil }
        return raw.compactMap { ($0 as? NSNumber)?.int64Value }
    }

    /// Tag a JSON game object with `shapes` (unioned onto any marker already present),
    /// without touching the per-shape stamps.
    static func tag(_ object: inout [String: Any], shapes: CatalogFieldShape) {
        let existing = (object[fieldsKey] as? NSNumber)?.intValue ?? 0
        object[fieldsKey] = existing | shapes.rawValue
    }

    /// Tag `shapes` AND stamp each of its bits at `date` (a real write does both).
    static func tag(_ object: inout [String: Any], shapes: CatalogFieldShape, stampedAt date: Date) {
        tag(&object, shapes: shapes)
        var stamps = (object[fetchedKey] as? [String: Any]) ?? [:]
        let ts = date.timeIntervalSince1970
        for bit in allShapes where shapes.contains(bit) { stamps[String(bit.rawValue)] = ts }
        object[fetchedKey] = stamps
    }

    /// Serialise a game object tagged with `shapes`, **no stamps** (mimics a pre-part-2
    /// blob; the read then falls back to the row `fetched_at`). Test/helper convenience.
    static func tagged(_ object: [String: Any], shapes: CatalogFieldShape) -> Data {
        var copy = object
        tag(&copy, shapes: shapes)
        return (try? JSONSerialization.data(withJSONObject: copy)) ?? Data("{}".utf8)
    }

    /// Serialise a game object tagged AND per-shape-stamped at `date`. Test/helper convenience.
    static func stamped(_ object: [String: Any], shapes: CatalogFieldShape, at date: Date) -> Data {
        var copy = object
        tag(&copy, shapes: shapes, stampedAt: date)
        return (try? JSONSerialization.data(withJSONObject: copy)) ?? Data("{}".utf8)
    }

    /// The raw (JSON-friendly) per-shape stamp dict, for merging.
    static func rawStamps(in json: Data) -> [String: Double] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let raw = object[fetchedKey] as? [String: Any]
        else { return [:] }
        var out: [String: Double] = [:]
        for (key, value) in raw where Int(key) != nil {
            if let secs = (value as? NSNumber)?.doubleValue { out[key] = secs }
        }
        return out
    }
}

/// Merges a freshly-fetched cache payload onto whatever is already stored for the
/// same id, so a *slimmer* write never drops the richer fields we already hold and
/// orthogonal shapes accumulate (a metadata blob keeps its `artworks`, a bundle keeps
/// its member list). The incoming payload's own keys win for the fields it carries,
/// the `_vgn_fields` shapes are unioned, and the **per-shape `_vgn_fetched` stamps are
/// merged per bit** (incoming wins for the bits it just wrote, existing stamps for the
/// others stand — so a search write never renews the metadata stamp). The (newer)
/// incoming row `fetchedAt` stands.
enum CatalogCacheMerge {
    static func merged(existing: CatalogCacheEntry?, incoming: CatalogCacheEntry) -> CatalogCacheEntry {
        guard let existing,
              var base = try? JSONSerialization.jsonObject(with: existing.json) as? [String: Any],
              let new = try? JSONSerialization.jsonObject(with: incoming.json) as? [String: Any]
        else { return incoming }

        let unioned = CatalogCacheShapeJSON.shapes(in: existing.json)
            .union(CatalogCacheShapeJSON.shapes(in: incoming.json))
        var stamps = CatalogCacheShapeJSON.rawStamps(in: existing.json)
        for (bit, ts) in CatalogCacheShapeJSON.rawStamps(in: incoming.json) { stamps[bit] = ts }

        for (key, value) in new
        where key != CatalogCacheShapeJSON.fieldsKey && key != CatalogCacheShapeJSON.fetchedKey {
            base[key] = value
        }
        base[CatalogCacheShapeJSON.fieldsKey] = unioned.rawValue
        if !stamps.isEmpty { base[CatalogCacheShapeJSON.fetchedKey] = stamps }
        guard let mergedJSON = try? JSONSerialization.data(withJSONObject: base) else { return incoming }
        return CatalogCacheEntry(igdbID: incoming.igdbID, json: mergedJSON, fetchedAt: incoming.fetchedAt)
    }
}
