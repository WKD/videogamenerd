import Foundation

/// The **pure** rule that decides whether an IGDB match is confident enough to auto-add a
/// Batocera favourite to the library (PLAN §15). No I/O — the same top-bucket definition the
/// review sheets pre-tick with, tightened by a platform check and a release-year check so an
/// unattended promotion is conservative.
enum BatoceraFavouriteMatch {

    /// A match is confident enough for a silent auto-add when:
    ///  - it is in the **top confidence bucket** (`.confident`), and
    ///  - it is **platform-consistent**: when the entry's platform and the match's platforms
    ///    are both known, the match must be on that platform (the search is already
    ///    platform-constrained; this is the belt-and-braces check), and
    ///  - the **release years are consistent** when both are known — a mismatch of more than
    ///    one year downgrades it to "needs review" (a different game with the same title).
    static func isConfident(outcome: ScanMatchOutcome, entryPlatform: String?, entryYear: Int?) -> Bool {
        guard outcome.bucket == .confident, let best = outcome.best else { return false }
        if let platform = entryPlatform, !best.platformSlugs.isEmpty,
           !best.platformSlugs.contains(platform) {
            return false
        }
        if let entryYear, let matchYear = best.releaseYear, abs(entryYear - matchYear) > 1 {
            return false
        }
        return true
    }
}

/// What one auto-add pass did (PLAN §15), for the banner + the Undo step.
struct BatoceraAutoAddResult: Sendable, Equatable {
    /// Favourites promoted into the library this run.
    var addedCount = 0
    /// The catalogue entries that were promoted (the exact set the Undo step reverses).
    var promotedEntries: [RomCatalogEntry] = []
    /// Favourites processed this run (staged + matched), whether or not they were confident.
    var processedCount = 0
    /// Favourites still awaiting a first match after this run — non-zero on the first run over
    /// the batch cap ("187 still to match").
    var stillToMatchCount = 0
    /// The pass was cancelled before finishing.
    var cancelled = false

    var didAdd: Bool { addedCount > 0 }
}

/// Auto-adds Batocera favourites on a confident IGDB match after a sync (PLAN §15). Runs off
/// the main actor (a plain `Sendable` value, `run` is nonisolated), is cancellable, and never
/// queries a favourite twice: every favourite it looks at is first staged in `import_titles`
/// (so ``RomCatalogStore/favouritesNeedingMatch(limit:)`` excludes it next time). Confident
/// matches (``BatoceraFavouriteMatch``) are promoted through ``BatoceraPromoter`` in one batch;
/// everything else stays for the review sheet exactly as before.
struct BatoceraFavouriteAutoAdd: Sendable {
    let catalog: RomCatalogStore
    let staging: ImportStagingStore
    let matcher: any ImportMatcher
    let promoter: BatoceraPromoter

    /// One background pass caps at this many favourites, so a first sync (the owner's box has
    /// ~247 favourites) does not hammer IGDB for minutes unattended — the rest continue on the
    /// next sync or when the owner opens Review… (PLAN §15).
    static let batchCap = 60

    init(catalog: RomCatalogStore, staging: ImportStagingStore,
         matcher: any ImportMatcher, promoter: BatoceraPromoter) {
        self.catalog = catalog
        self.staging = staging
        self.matcher = matcher
        self.promoter = promoter
    }

    /// Run one pass, promoting up to `limit` confident favourites. Never throws — a failed
    /// match / promotion is simply skipped and left for review.
    func run(limit: Int = BatoceraFavouriteAutoAdd.batchCap) async -> BatoceraAutoAddResult {
        var result = BatoceraAutoAddResult()
        let total = (try? await catalog.favouritesNeedingMatchCount()) ?? 0
        let favourites = (try? await catalog.favouritesNeedingMatch(limit: limit)) ?? []
        guard !favourites.isEmpty else {
            result.stillToMatchCount = total
            return result
        }

        var plans: [BatoceraPromoter.Plan] = []
        var candidates: [RomCatalogEntry] = []
        var processed = 0

        for entry in favourites {
            if Task.isCancelled { result.cancelled = true; break }
            // Stage first, so a favourite is never matched twice — even if the app quits before
            // the promotion commits, next run skips it.
            try? await staging.upsert([BatoceraPromotionBuilder.stagingRow(for: entry)])
            processed += 1

            let request = ImportMatchRequest(title: entry.name, platformSlug: entry.platformID,
                                             releaseYear: entry.releaseYear)
            guard let outcome = try? await matcher.match(request), let best = outcome.best,
                  BatoceraFavouriteMatch.isConfident(outcome: outcome, entryPlatform: entry.platformID,
                                                     entryYear: entry.releaseYear)
            else { continue }   // ambiguous / unmatched / year-mismatched → stays for review

            let target: ImportCommitItem.Target
            var alreadyHasCopy = false
            if let gameID = try? await promoter.existingGameID(igdbID: best.igdbID) {
                alreadyHasCopy = (try? await promoter.gameHasROMCopy(
                    gameID: gameID, platformID: entry.platformID ?? "")) ?? false
                target = .existingGame(gameID: gameID)
            } else {
                target = .newGame(ImportNewGameSpec(title: entry.name, igdbID: best.igdbID,
                                                    releaseYear: entry.releaseYear))
            }
            plans.append(.init(entry: entry, target: target, alreadyHasROMCopy: alreadyHasCopy))
            candidates.append(entry)
        }

        if !plans.isEmpty, let promoteResult = try? await promoter.promote(plans) {
            let promotedIDs = Set(promoteResult.promotedCatalogIDs)
            result.promotedEntries = candidates.filter { promotedIDs.contains($0.id) }
            result.addedCount = result.promotedEntries.count
        }
        result.processedCount = processed
        result.stillToMatchCount = max(0, total - processed)
        return result
    }
}
