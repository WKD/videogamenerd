import Foundation

/// The Batocera catalogue → library promotion importer (PLAN §15). Like Delicious it is a
/// **file/local** ``LibraryImporter`` (no network, no auth): `fetch` yields staging rows for
/// the promotion candidates (or an explicit list of catalogue ids for a hand "Add to
/// Library"), so promotion runs through the same coordinator → staging → review → commit
/// path as every other source. The ROM-specific commit shape (format `.rom`, played data,
/// duplicate handling) is built by ``BatoceraPromotionBuilder`` / ``BatoceraPromoter``.
struct BatoceraImporter: LibraryImporter, Sendable {
    let store: RomCatalogStore
    /// Explicit catalogue ids to promote by hand; nil ⇒ every pending promotion candidate.
    var catalogIDs: [Int64]?

    init(store: RomCatalogStore, catalogIDs: [Int64]? = nil) {
        self.store = store
        self.catalogIDs = catalogIDs
    }

    let source = ImportSourceID.batocera

    /// A local catalogue read costs no requests (no network).
    var dataSets: [ImportDataSet] {
        [ImportDataSet(id: "batocera.catalog", title: "Batocera", estimatedRequests: 0)]
    }

    func authenticate() async throws {}

    func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
        progress(ImportProgress(phase: .fetching, detail: "Reading the Batocera catalogue"))
        let entries: [RomCatalogEntry]
        if let ids = catalogIDs {
            entries = try await store.entries(ids: ids)
        } else {
            entries = try await store.promotionCandidates()
        }
        progress(ImportProgress(phase: .staging, detail: "Staging \(entries.count) ROMs"))
        let rows = entries.map(BatoceraPromotionBuilder.stagingRow(for:))
        return ImportFetchResult(rows: rows, fromFile: rows.count)
    }
}

/// Pure builders that turn a catalogue entry into the shared importer types (PLAN §15).
enum BatoceraPromotionBuilder {

    /// The staging row for one candidate: owned + played (when > 10 min), platform from the
    /// catalogue, `external_id` = `<system>/<relativePath>`, match title = the clean name,
    /// release year as the IGDB tie-breaker, and Batocera's play time / last-played date.
    static func stagingRow(for e: RomCatalogEntry) -> ImportStagingRow {
        let played = BatoceraPromotion.isPlayed(gameTimeSeconds: e.gameTimeSeconds)
        var signals: ImportSignals = [.owned]
        if played { signals.insert(.played) }
        return ImportStagingRow(
            source: ImportSourceID.batocera,
            externalID: e.externalID,
            name: e.name,
            platform: e.platformID,
            signals: signals,
            playDurationS: played ? e.gameTimeSeconds : nil,
            lastPlayedAt: e.lastPlayedAt,
            releaseYear: e.releaseYear)
    }

    /// The commit item for one promotion (PLAN §15). Owned ROM copy on the catalogue's
    /// platform; `markPlayed` + play time (stored **only if the game has none**, so a real
    /// PSN value is never clobbered) when > 10 min; last-played date; a favourite with no play
    /// time lands owned-not-played. When the matched game **already has a ROM copy on the same
    /// platform** (`alreadyHasROMCopy`), no second copy is created — the play data still lands
    /// on the existing game and the catalogue row is linked.
    static func commitItem(for e: RomCatalogEntry, target: ImportCommitItem.Target,
                           alreadyHasROMCopy: Bool) -> ImportCommitItem {
        let played = BatoceraPromotion.isPlayed(gameTimeSeconds: e.gameTimeSeconds)
        let psn = PSNCommit(
            createProduct: !alreadyHasROMCopy,
            markPlayed: played,
            playDurationS: played ? e.gameTimeSeconds : nil,
            lastPlayedAt: e.lastPlayedAt,
            playtimeOnlyIfEmpty: true)
        return ImportCommitItem(
            source: ImportSourceID.batocera,
            externalID: e.externalID,
            platformID: e.platformID ?? "",
            format: .rom,
            target: target,
            psn: psn)
    }

    /// A convenience `.newGame` target from a catalogue entry (no IGDB id yet — phase 2 fills
    /// it after matching).
    static func newGameTarget(for e: RomCatalogEntry) -> ImportCommitItem.Target {
        .newGame(ImportNewGameSpec(title: e.name, igdbID: nil, releaseYear: e.releaseYear))
    }

    /// The commit item for a **bundle** promotion (D2, PLAN §5.1): a `rom` compilation Product
    /// whose members are the individual games. No play data is attached here — the ROM's play
    /// time / last played is applied to the sole member only when the bundle resolved to exactly
    /// one member (``BatoceraPromoter/promote(_:)``); with two or more it is dropped from games
    /// and kept on the catalogue row (PLAN §13.3). Format is always `.rom` (PLAN §16, D3).
    static func compilationCommitItem(for e: RomCatalogEntry,
                                      bundle: BatoceraPromoter.BundlePromotion) -> ImportCommitItem {
        ImportCommitItem(
            source: ImportSourceID.batocera,
            externalID: e.externalID,
            platformID: e.platformID ?? "",
            format: .rom,
            target: .compilation(title: bundle.title, members: bundle.members))
    }
}
