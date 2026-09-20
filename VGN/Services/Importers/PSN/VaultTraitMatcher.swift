import Foundation

/// The IGDB facts persisted on a matched PS Plus Vault entry (PLAN §16): the matched id, the
/// taste traits in the engine's ``GameTrait`` vocabulary (genres / themes / keywords /
/// franchise / developer / …), the crowd rating and the main / completionist time-to-beat.
struct VaultTraitInfo: Sendable, Equatable {
    var igdbID: Int64
    var traits: [GameTrait]
    var igdbRating: Double?
    var lengthMainSeconds: Int?
    var lengthCompleteSeconds: Int?
}

/// The IGDB metadata + time-to-beat lookup for confident PS Plus matches, behind a protocol so
/// the matcher's tests use a fake and never touch IGDB (PLAN §16). One call per batch, not per
/// entry, so a run costs ~one autocomplete per entry plus two batch requests.
protocol VaultMetadataFetching: Sendable {
    /// Full traits / rating / time-to-beat for a batch of matched IGDB ids. Ids with no IGDB
    /// metadata are simply absent from the result (the matcher then records them no-match, so
    /// they are never re-queried).
    func info(igdbIDs: [Int64]) async throws -> [Int64: VaultTraitInfo]
}

/// The live fetcher over ``IGDBClient`` (rate-limited by the same actor the matcher uses): one
/// `games(ids:)` plus one `timeToBeat(gameIDs:)` for the whole batch (PLAN §16 — reuse the
/// existing IGDB time-to-beat call; never HowLongToBeat here).
struct IGDBVaultMetadataFetcher: VaultMetadataFetching {
    let client: IGDBClient

    func info(igdbIDs: [Int64]) async throws -> [Int64: VaultTraitInfo] {
        guard !igdbIDs.isEmpty else { return [:] }
        let metas = try await client.games(ids: igdbIDs)
        var ttbByID: [Int64: IGDBTimeToBeat] = [:]
        for row in (try? await client.timeToBeat(gameIDs: igdbIDs)) ?? [] { ttbByID[row.gameID] = row }
        var out: [Int64: VaultTraitInfo] = [:]
        for meta in metas { out[meta.id] = VaultTraitMatcher.traitInfo(from: meta, ttb: ttbByID[meta.id]) }
        return out
    }
}

/// The **pure** rule that decides whether a PS Plus IGDB match is confident enough to persist
/// (PLAN §16): the top confidence bucket, plus a belt-and-braces platform check (the search is
/// already platform-constrained). No release-year check — a PS Plus Vault entry carries no year.
enum VaultTraitMatch {
    static func isConfident(outcome: ScanMatchOutcome, entryPlatform: String?) -> Bool {
        guard outcome.bucket == .confident, let best = outcome.best else { return false }
        if let platform = entryPlatform, !best.platformSlugs.isEmpty,
           !best.platformSlugs.contains(platform) {
            return false
        }
        return true
    }
}

/// What one trait-matching pass did (PLAN §16), for the Settings status line + tests.
struct VaultTraitMatchOutcome: Sendable, Equatable {
    /// Entries looked at this run (matched or not).
    var attempted = 0
    /// Confident matches persisted with traits / rating / time-to-beat.
    var matched = 0
    /// Ambiguous / unmatched / no-metadata entries marked `no_match` (never re-queried).
    var noMatch = 0
    /// The pass was cancelled before finishing.
    var cancelled = false
}

/// Fills PS Plus Vault entries with IGDB traits so they can be taste-scored in "From the vault"
/// (PLAN §16). Runs off the main actor (a plain `Sendable` value, `run` is nonisolated), is
/// cancellable, and never queries an entry twice: the store's ``RomCatalogStore/unmatchedPSN``
/// only returns rows with `match_state IS NULL`, and every row this pass looks at is left either
/// `matched` (``RomCatalogStore/setVaultMatch``) or `no_match`
/// (``RomCatalogStore/setVaultNoMatch``). Mirrors ``BatoceraFavouriteAutoAdd``'s shape.
struct VaultTraitMatcher: Sendable {
    let catalog: RomCatalogStore
    let matcher: any ImportMatcher
    let metadata: any VaultMetadataFetching
    /// Strips ™/®/©/℠ before matching (PLAN §16 — reuse the PSN cleaner). Injected so the pure
    /// tests need not depend on the PSN mapping.
    let cleanTitle: @Sendable (String) -> String

    /// One background pass caps at this many entries, so a first run over ~180–310 PS Plus
    /// claims does not hammer IGDB for minutes unattended — the rest continue on the next sync
    /// or when the owner taps "Match more now" (PLAN §16).
    static let batchCap = 60

    init(catalog: RomCatalogStore, matcher: any ImportMatcher, metadata: any VaultMetadataFetching,
         cleanTitle: @escaping @Sendable (String) -> String = { PSNMapping.cleanMatchTitle($0) }) {
        self.catalog = catalog
        self.matcher = matcher
        self.metadata = metadata
        self.cleanTitle = cleanTitle
    }

    /// Run one pass over up to `limit` unmatched entries. Never throws — a failed match / fetch
    /// leaves the entry for the next run (matched entries are never re-queried; no-match ones are
    /// marked so they are not either).
    func run(limit: Int = VaultTraitMatcher.batchCap) async -> VaultTraitMatchOutcome {
        var outcome = VaultTraitMatchOutcome()
        let entries = (try? await catalog.unmatchedPSN(limit: limit)) ?? []
        guard !entries.isEmpty else { return outcome }

        // Pass 1: match each entry through the existing IGDB matcher (one autocomplete each,
        // rate-limited). Non-confident entries are marked no-match inline so they never return.
        var confident: [(id: Int64, igdbID: Int64)] = []
        for entry in entries {
            if Task.isCancelled { outcome.cancelled = true; break }
            outcome.attempted += 1
            let request = ImportMatchRequest(
                title: cleanTitle(entry.name), platformSlug: entry.platformID, releaseYear: nil)
            guard let result = try? await matcher.match(request), let best = result.best,
                  VaultTraitMatch.isConfident(outcome: result, entryPlatform: entry.platformID)
            else {
                try? await catalog.setVaultNoMatch(id: entry.id)
                outcome.noMatch += 1
                continue
            }
            confident.append((entry.id, best.igdbID))
        }
        // A cancelled pass persists what it already decided and leaves the rest for next time.
        guard !outcome.cancelled, !confident.isEmpty else { return outcome }

        // Pass 2: one batch metadata + time-to-beat fetch for every confident id (two requests).
        let ids = Array(Set(confident.map(\.igdbID)))
        let infoByID = (try? await metadata.info(igdbIDs: ids)) ?? [:]
        for pair in confident {
            if let info = infoByID[pair.igdbID] {
                try? await catalog.setVaultMatch(
                    id: pair.id, igdbID: info.igdbID, traits: info.traits,
                    lengthMainSeconds: info.lengthMainSeconds,
                    lengthCompleteSeconds: info.lengthCompleteSeconds, igdbRating: info.igdbRating)
                outcome.matched += 1
            } else {
                // IGDB had a hit in search but no full metadata — treat as no match so it is
                // never re-queried (a manual "Find match…" can override later).
                try? await catalog.setVaultNoMatch(id: pair.id)
                outcome.noMatch += 1
            }
        }
        return outcome
    }

    /// Build the persisted trait info from IGDB metadata + its time-to-beat (PLAN §16). The
    /// persisted traits are the engine's `game_traits` vocabulary plus the synthesised `.genre`
    /// and `.decade` features, so a matched PS Plus entry scores exactly like a ranked game.
    static func traitInfo(from meta: IGDBGameMetadata, ttb: IGDBTimeToBeat?) -> VaultTraitInfo {
        var traits = meta.traits
        for genre in meta.genres { traits.append(GameTrait(kind: .genre, value: genre)) }
        if let year = meta.releaseYear {
            traits.append(GameTrait(kind: .decade, value: String((year / 10) * 10)))
        }
        return VaultTraitInfo(
            igdbID: meta.id, traits: traits, igdbRating: meta.igdbRating,
            lengthMainSeconds: ttb?.normally, lengthCompleteSeconds: ttb?.completely)
    }
}
