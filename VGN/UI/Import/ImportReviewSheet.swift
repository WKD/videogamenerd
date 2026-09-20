import SwiftUI

/// One row of the import review sheet (PLAN §14.3): the persisted staging decision
/// (`matchedGameID` / `ignored` / `platform`) merged with the transient mapping hints
/// (release year, Mac availability, Linux-only note, noise reason) and the IGDB match
/// proposal. Source-agnostic (GOG now, PSN later).
struct ImportReviewRow: Identifiable, Equatable, Sendable {
    let externalID: String
    let sourceTitle: String
    var platform: String?
    var include: Bool
    var ignored: Bool
    var matchedGameID: Int64?
    var proposedMatch: ScanMatch?
    var alternatives: [ScanMatch]
    var confidence: ScanConfidenceBucket
    var ignoreReason: ImportIgnoreReason?
    var releaseYear: Int?
    var macAvailable: Bool
    var linuxOnly: Bool
    /// The matched game already has an owned copy of this format on this platform, or
    /// another row in the same import already claims it (PLAN §5.5). Shown under
    /// *Already matched*, unticked, and never committed — never a second copy.
    var shelfDuplicate: Bool = false
    /// A one-line duplicate note (e.g. "Already on your shelf", "You already own a
    /// digital copy") shown on the row.
    var duplicateNote: String? = nil
    /// Edition / acquired date carried from the source onto the committed copy (Delicious).
    var edition: String? = nil
    var acquiredAt: Date? = nil
    /// **(PSN)** A played-only row the owner chose to *also* own, as this format — the
    /// "Own the ticked rows as ▸ Physical / Digital" group action (PLAN §13.3). nil ⇒ keep
    /// it played-only. Forces a copy at commit.
    var ownAsFormat: ProductFormat? = nil

    var id: String { externalID }

    var bucket: ImportReviewBucket {
        if ignored { return .ignored }
        if shelfDuplicate { return .alreadyMatched }
        return matchedGameID == nil ? .new : .alreadyMatched
    }
    var isCommittable: Bool { include && !ignored && !shelfDuplicate }
    var matchedTitle: String? { proposedMatch?.name }
    var showsSourceTitle: Bool {
        guard let matched = proposedMatch?.name else { return true }
        return matched.caseInsensitiveCompare(sourceTitle) != .orderedSame
    }
}

/// A committable review row projected for a source-specific committer (Batocera, PLAN §15):
/// the resolved match (an existing library game, or an IGDB id for a new game) plus the
/// chosen platform. The committer turns these into its own commit shape.
struct ImportReviewCommitRow: Sendable, Equatable {
    var externalID: String
    var platformID: String?
    var matchedGameID: Int64?
    var igdbID: Int64?
    var title: String
    var releaseYear: Int?
}

/// The PSN-specific review groups (PLAN §13.3). Used only when the sheet's source is PSN;
/// GOG/Delicious keep the generic *New / Already matched / Ignored* buckets. A row lands in
/// the first matching group (see ``ImportReviewModel/psnGroup(for:)``).
enum PSNReviewGroup: String, CaseIterable, Sendable, Hashable {
    /// Owned (a purchase) **and** played.
    case played
    /// A trophy title at 0 % — merely launched, never played. Unticked by default.
    case launched
    /// Played, no purchase found — offered a one-click "own as ▸ Physical / Digital".
    case playedNoPurchase
    /// A bought digital copy.
    case purchased
    /// A PS Plus claim — expires with the subscription.
    case psPlus
    /// Already in your library — the import only adds played / play time / dates.
    case alreadyInLibrary
    /// Moved to the Vault by the 10-minute rule (PLAN §16) — browsable there, never imported here.
    case inTheVault
    /// Filtered noise (with a reason).
    case ignored

    var label: String {
        switch self {
        case .played: return "Played"
        case .launched: return "Launched, 0 %"
        case .playedNoPurchase: return "Played — no purchase found"
        case .purchased: return "Purchased"
        case .psPlus: return "PS Plus"
        case .alreadyInLibrary: return "Already in your library"
        case .inTheVault: return "In the Vault"
        case .ignored: return "Ignored"
        }
    }
    /// A group footnote shown under the header, or nil.
    var footnote: String? {
        switch self {
        case .psPlus: return "expires with the subscription"
        case .launched: return "a game you merely launched — tick any you actually played"
        case .playedNoPurchase: return "imported as played, not owned"
        case .inTheVault: return "barely played (under 10 min) — browse them in the Vault"
        default: return nil
        }
    }
}

/// State behind the shared import review sheet (PLAN §14.3). Merges the sync result with
/// the persisted staging decisions, re-maps platforms on the policy switch, persists
/// ignore/restore, and commits through ``ImportStagingStore/commit(_:)`` in one
/// transaction. `@MainActor @Observable`; built with fakes in tests (no network).
@MainActor
@Observable
final class ImportReviewModel {
    let source: String
    let sourceLabel: String
    private let staging: ImportStagingStore
    private let onLibraryChanged: () -> Void

    let summary: ImportSyncSummary
    /// The copy format an imported title commits as: `.digital` for GOG, `.physical` for
    /// Delicious. Used at commit and for the duplicate rule (PLAN §5.5).
    let productFormat: ProductFormat
    /// The platform slugs the per-row platform popup offers. GOG offers pc/mac; Delicious
    /// offers every VGN platform (its games span consoles + hybrid discs).
    let platformChoices: [String]
    /// Whether to detect "already on your shelf" duplicates (Delicious only, PLAN §5.5).
    let detectShelfDuplicates: Bool
    /// **(Batocera, PLAN §15)** ROM-promotion mode: a matched game that already owns a ROM
    /// copy on that platform is annotated "Already in your library — adds play time only" and
    /// stays committable (the play data still lands; no second copy). Off for GOG/PSN/Delicious.
    let romPromotion: Bool
    /// A source-supplied per-row caption shown under the title (Batocera play line
    /// "4 h 12 · last played Apr 2025 · ★"). Generic; empty for other sources.
    let rowDetailByID: [String: String]
    /// **(Batocera, PLAN §15)** When set, replaces the default `store.commit(commitItems())`:
    /// the ticked, resolved rows are handed to a source-specific committer (Batocera promotes
    /// ROM copies with the box's play data and links the catalogue rows through
    /// ``BatoceraPromoter``). Returns the commit result for the success banner.
    @ObservationIgnored private let customCommit: (@Sendable ([ImportReviewCommitRow]) async throws -> ImportCommitResult)?
    /// A file source shows a header toggle to use its own cover art where a game has none.
    let showsSourceCoverToggle: Bool
    var useSourceCovers: Bool
    /// Whether the header shows the **Mac when available / Always PC** platform switch — only for
    /// importers whose rows can actually be re-mapped between pc and mac (GOG; Delicious for its
    /// hybrid discs). Off for PSN / Batocera, where it is meaningless (coordinator, 2026-09-20).
    let showsPlatformPolicy: Bool
    /// Select the PS Plus Vault sidebar row and close the sheet ("Show in the Vault", PLAN §16).
    @ObservationIgnored var onShowInVault: () -> Void = {}
    /// Ran after a successful commit (Delicious live: apply the source's covers). The Bool
    /// is `useSourceCovers`.
    @ObservationIgnored private let afterCommit: (@Sendable (ImportCommitResult, Bool) async -> Void)?

    private(set) var rows: [ImportReviewRow] = []
    var platformPolicy: ImportPlatformPolicy {
        didSet { if platformPolicy != oldValue { remapPlatforms() } }
    }

    private(set) var isCommitting = false
    private(set) var committed = false
    private(set) var successMessage: String?
    private(set) var commitError: String?

    // MARK: PSN-only review state (PLAN §13.3) — additive, ignored for GOG/Delicious.

    /// Whether this sheet renders the richer PSN groups.
    var isPSN: Bool { source == ImportSourceID.psn }
    /// PS Plus claims a previous sync committed that the latest fetch no longer lists —
    /// proposed for removal, never applied silently. Unticked by default.
    private(set) var proposedRemovals: [ImportSubscriptionRemovalProposal] = []
    var removalTicks: Set<Int64> = []
    var removalConfirming = false
    private(set) var removalsApplied = 0

    @ObservationIgnored private let transientByID: [String: ImportStagingRow]
    @ObservationIgnored private let matchByID: [String: ScanMatchOutcome]
    /// "igdbID|platform" → existing game id for an owned copy of `productFormat` (shelf
    /// duplicate); a different format on the same platform lands in `otherFormatKeys`.
    @ObservationIgnored private var sameFormatKeys: [String: Int64] = [:]
    @ObservationIgnored private var otherFormatKeys: Set<String> = []
    /// **(Batocera)** "gameID|platform" for an existing ROM copy — the duplicate check for a
    /// row matched to a game already in the library (adds play time only, no second copy).
    @ObservationIgnored private var romCopyGameKeys: Set<String> = []

    /// Header line: file source → "N games read from …"; network source → cache/network.
    var summaryLine: String { summary.summaryLine(sourceLabel: sourceLabel) }

    init(source: String,
         sourceLabel: String,
         staging: ImportStagingStore,
         result: ImportSyncResult,
         platformPolicy: ImportPlatformPolicy = .macWhenAvailable,
         productFormat: ProductFormat = .digital,
         platformChoices: [String] = ["pc", "mac"],
         detectShelfDuplicates: Bool = false,
         showsSourceCoverToggle: Bool = false,
         showsPlatformPolicy: Bool = false,
         romPromotion: Bool = false,
         rowDetailByID: [String: String] = [:],
         customCommit: (@Sendable ([ImportReviewCommitRow]) async throws -> ImportCommitResult)? = nil,
         afterCommit: (@Sendable (ImportCommitResult, Bool) async -> Void)? = nil,
         onLibraryChanged: @escaping () -> Void = {}) {
        self.source = source
        self.sourceLabel = sourceLabel
        self.staging = staging
        self.summary = result.summary
        self.platformPolicy = platformPolicy
        self.productFormat = productFormat
        self.platformChoices = platformChoices
        self.detectShelfDuplicates = detectShelfDuplicates
        self.showsSourceCoverToggle = showsSourceCoverToggle
        self.showsPlatformPolicy = showsPlatformPolicy
        self.romPromotion = romPromotion
        self.rowDetailByID = rowDetailByID
        self.customCommit = customCommit
        self.useSourceCovers = showsSourceCoverToggle
        self.afterCommit = afterCommit
        self.onLibraryChanged = onLibraryChanged
        self.transientByID = Dictionary(result.rows.map { ($0.externalID, $0) }, uniquingKeysWith: { a, _ in a })
        self.matchByID = Dictionary(
            result.matches.map { ($0.externalID, $0.outcome) }, uniquingKeysWith: { a, _ in a })
    }

    /// Read the staged titles and build the review rows. Call once when the sheet opens.
    func load() async {
        if detectShelfDuplicates {
            for copy in (try? await staging.ownedCopies()) ?? [] {
                let key = "\(copy.igdbID)|\(copy.platform)"
                if copy.format == productFormat { sameFormatKeys[key] = copy.gameID }
                else { otherFormatKeys.insert(key) }
            }
        }
        if romPromotion {
            for copy in (try? await staging.ownedCopies()) ?? [] where copy.format == .rom {
                sameFormatKeys["\(copy.igdbID)|\(copy.platform)"] = copy.gameID
                romCopyGameKeys.insert("\(copy.gameID)|\(copy.platform)")
            }
        }
        let titles = (try? await staging.titles(source: source)) ?? []
        rows = titles.map { makeRow(from: $0) }
        if detectShelfDuplicates { markIntraImportDuplicates() }
        if isPSN {
            let currentIDs = Set(transientByID.keys)
            proposedRemovals = (try? await staging.proposedSubscriptionRemovals(
                source: source, currentExternalIDs: currentIDs)) ?? []
        }
    }

    private func makeRow(from title: ImportStagedTitle) -> ImportReviewRow {
        let transient = transientByID[title.externalID]
        let outcome = matchByID[title.externalID]
        let bucket = title.ignored ? ImportReviewBucket.ignored
            : (title.matchedGameID == nil ? .new : .alreadyMatched)
        let confidence = outcome?.bucket ?? .none
        // Confident, still-New matches are pre-ticked; the rest wait (PLAN §14.3). PSN uses
        // its own pre-tick per group (Played/Purchased/PS Plus/already-in-library ticked;
        // Launched 0 % unticked) below.
        let include = bucket == .new && confidence == .confident
        var row = ImportReviewRow(
            externalID: title.externalID,
            sourceTitle: title.name,
            platform: title.platform,
            include: include,
            ignored: title.ignored,
            matchedGameID: title.matchedGameID,
            proposedMatch: outcome?.best,
            alternatives: outcome?.alternatives ?? [],
            confidence: confidence,
            ignoreReason: transient?.ignoreReason,
            releaseYear: transient?.releaseYear ?? outcome?.best?.releaseYear,
            macAvailable: transient?.macAvailable ?? false,
            linuxOnly: transient?.linuxOnly ?? false)
        row.edition = transient?.edition
        row.acquiredAt = transient?.acquiredAt

        // Shelf-duplicate rule: a New row whose match already has an owned copy of this
        // format on this platform is dropped to Already matched, unticked (PLAN §5.5).
        if detectShelfDuplicates, bucket == .new, let igdbID = row.proposedMatch?.igdbID,
           let platform = row.platform {
            let key = "\(igdbID)|\(platform)"
            if sameFormatKeys[key] != nil {
                row.shelfDuplicate = true
                row.include = false
                row.duplicateNote = "Already on your shelf"
            } else if otherFormatKeys.contains(key) {
                row.duplicateNote = "You already own a different copy — this adds your \(productFormat.label.lowercased()) one"
            }
        }

        // Batocera ROM promotion (PLAN §15): a row whose match already owns a ROM copy on
        // this platform is annotated "adds play time only" but stays committable — the box's
        // play data still lands, no second copy is made.
        if romPromotion, !row.ignored, let platform = row.platform {
            let hasCopy: Bool
            if let gameID = row.matchedGameID {
                hasCopy = romCopyGameKeys.contains("\(gameID)|\(platform)")
            } else if let igdbID = row.proposedMatch?.igdbID {
                hasCopy = sameFormatKeys["\(igdbID)|\(platform)"] != nil
            } else {
                hasCopy = false
            }
            if hasCopy { row.duplicateNote = "Already in your library — adds play time only" }
        }

        // PSN pre-tick: everything ticked except Launched-0 % and Ignored (PLAN §13.3).
        if isPSN, !row.ignored {
            row.include = psnGroup(for: row) != .launched
        }
        return row
    }

    /// Two source rows that resolve to the same game + platform: import one, list the
    /// rest as duplicates (PLAN §5.5).
    private func markIntraImportDuplicates() {
        var seen = Set<String>()
        for i in rows.indices {
            guard !rows[i].ignored, !rows[i].shelfDuplicate, rows[i].bucket == .new,
                  let key = intraImportKey(rows[i]) else { continue }
            if seen.contains(key) {
                rows[i].shelfDuplicate = true
                rows[i].include = false
                rows[i].duplicateNote = "Another copy of this game is in this import"
            } else {
                seen.insert(key)
            }
        }
    }

    private func intraImportKey(_ row: ImportReviewRow) -> String? {
        guard let platform = row.platform else { return nil }
        if let igdbID = row.proposedMatch?.igdbID { return "i:\(igdbID)|\(platform)" }
        return "n:\(row.sourceTitle.lowercased())|\(platform)"
    }

    // MARK: Buckets

    func rows(in bucket: ImportReviewBucket) -> [ImportReviewRow] { rows.filter { $0.bucket == bucket } }
    var presentBuckets: [ImportReviewBucket] {
        [.new, .alreadyMatched, .ignored].filter { b in rows.contains { $0.bucket == b } }
    }

    // MARK: PSN groups (PLAN §13.3)

    /// Classify a row into its PSN group (priority order): ignored → already-in-library →
    /// PS Plus (a subscription claim) → owned+played → purchased → launched-0 % →
    /// played-only → (fallback) purchased.
    func psnGroup(for row: ImportReviewRow) -> PSNReviewGroup {
        // A claim the 10-minute rule sent to the Vault shows in its own collapsed group, not as
        // an ordinary Ignored row (PLAN §16).
        if transientByID[row.externalID]?.ignoreReason == .vaultedSubscription { return .inTheVault }
        if row.ignored { return .ignored }
        if row.matchedGameID != nil { return .alreadyInLibrary }
        let t = transientByID[row.externalID]
        let signals = t?.signals ?? []
        if t?.subscription != nil { return .psPlus }
        if signals.contains(.owned) { return signals.contains(.played) ? .played : .purchased }
        if t?.launchedNotPlayed == true { return .launched }
        if signals.contains(.played) { return .playedNoPurchase }
        return .purchased
    }

    /// Ticked (will-import) count in a PSN group, for the "ticked / total" header.
    func psnTickedCount(in group: PSNReviewGroup) -> Int {
        rows.filter { psnGroup(for: $0) == group && $0.isCommittable }.count
    }

    func psnRows(in group: PSNReviewGroup) -> [ImportReviewRow] {
        rows.filter { psnGroup(for: $0) == group }
    }
    /// PSN groups present in this import, in display order.
    var presentPSNGroups: [PSNReviewGroup] {
        PSNReviewGroup.allCases.filter { g in rows.contains { psnGroup(for: $0) == g } }
    }

    /// PS Plus claims imported as owned-via-subscription copies (played > 10 min).
    var psPlusPlayedCount: Int { psnRows(in: .psPlus).count }
    /// PS Plus claims sent to the Vault (played ≤ 10 min) — staged ignored (PLAN §16).
    var psPlusVaultedCount: Int {
        rows.filter { transientByID[$0.externalID]?.ignoreReason == .vaultedSubscription }.count
    }
    /// The review-header line "PS Plus: N played · M in the Vault" (PLAN §16), or nil.
    var psPlusHeaderSummary: String? {
        guard isPSN, psPlusPlayedCount > 0 || psPlusVaultedCount > 0 else { return nil }
        return "PS Plus: \(psPlusPlayedCount) played · \(psPlusVaultedCount) in the Vault"
    }

    /// A one-line "what will change" for an **Already in your library** row (PLAN §13.3 —
    /// "+ played", "+ 42 h", "+ last played 2021"). Describes what the import contributes
    /// (the commit is idempotent/monotonic), not a diff against the stored game.
    func psnChangeDescription(for row: ImportReviewRow) -> String {
        guard let t = transientByID[row.externalID] else { return "no change" }
        var parts: [String] = []
        if t.signals.contains(.played), !t.launchedNotPlayed { parts.append("+ played") }
        if let seconds = t.playDurationS, seconds >= 3_600 {
            parts.append("+ \(seconds / 3_600) h")
        }
        if let last = t.lastPlayedAt, last > Date.distantPast {
            parts.append("+ last played \(Calendar.current.component(.year, from: last))")
        }
        if t.signals.contains(.owned) {
            parts.append(t.subscription != nil ? "+ PS Plus copy" : "+ digital copy")
        }
        return parts.isEmpty ? "no change" : parts.joined(separator: " · ")
    }

    /// The "Own the ticked rows as ▸ Physical / Digital" group action for the
    /// *Played — no purchase found* group (PLAN §13.3): the ticked played-only rows commit
    /// an owned copy of `format` in addition to being marked played.
    func ownTickedAs(_ format: ProductFormat) {
        for i in rows.indices where psnGroup(for: rows[i]) == .playedNoPurchase && rows[i].include {
            rows[i].ownAsFormat = format
        }
    }
    /// Whether the group action can do anything (a ticked played-no-purchase row exists).
    var canOwnPlayedRows: Bool {
        rows.contains { psnGroup(for: $0) == .playedNoPurchase && $0.include }
    }

    // MARK: PSN proposed removals (PLAN §13.3)

    func toggleRemoval(_ productID: Int64, _ on: Bool) {
        if on { removalTicks.insert(productID) } else { removalTicks.remove(productID) }
    }
    var tickedRemovalCount: Int { removalTicks.count }
    func requestApplyRemovals() { guard !removalTicks.isEmpty else { return }; removalConfirming = true }
    func confirmApplyRemovals() {
        removalConfirming = false
        let ids = Array(removalTicks)
        let store = staging
        let changed = onLibraryChanged
        Task {
            let n = (try? await store.applySubscriptionRemovals(ids)) ?? 0
            removalsApplied += n
            proposedRemovals.removeAll { removalTicks.contains($0.productID) }
            removalTicks.removeAll()
            if n > 0 { changed() }
        }
    }
    var committableCount: Int { rows.filter(\.isCommittable).count }
    var canCommit: Bool { !committed && !isCommitting && committableCount > 0 }
    var commitButtonTitle: String { "Import \(committableCount) Game\(committableCount == 1 ? "" : "s")" }

    // MARK: Edits

    private func mutate(_ externalID: String, _ transform: (inout ImportReviewRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.externalID == externalID }) else { return }
        transform(&rows[index])
    }

    func setInclude(_ include: Bool, externalID: String) {
        mutate(externalID) { if !$0.ignored { $0.include = include } }
    }

    func setPlatform(_ slug: String, externalID: String) {
        mutate(externalID) { $0.platform = slug }
    }

    func ignore(_ externalID: String) {
        mutate(externalID) { $0.ignored = true; $0.include = false }
        persist(externalID, .ignore)
    }

    func restore(_ externalID: String) {
        mutate(externalID) { $0.ignored = false }
        persist(externalID, .restore)
    }

    func chooseAlternative(_ match: ScanMatch, externalID: String) {
        mutate(externalID) { row in
            row.proposedMatch = match
            var bucket = ScanMatching.bucket(for: match.score)
            if bucket == .none { bucket = .plausible }   // an explicit pick is at least plausible
            row.confidence = bucket
            if !row.ignored { row.include = true }
        }
    }

    /// Re-map the PC/Mac rows' platform under the current policy (PLAN §14.3). Only rows
    /// currently on `pc`/`mac` follow the switch — a Delicious console game (ps3, wii…)
    /// keeps its slug, and a row still needing a platform pick is left untouched.
    private func remapPlatforms() {
        for i in rows.indices {
            guard let current = rows[i].platform, current == "pc" || current == "mac" else { continue }
            rows[i].platform = platformPolicy == .alwaysPC ? "pc" : (rows[i].macAvailable ? "mac" : "pc")
        }
    }

    func selectAll(in bucket: ImportReviewBucket) { setInclude(true, bucket: bucket) }
    func selectNone(in bucket: ImportReviewBucket) { setInclude(false, bucket: bucket) }
    private func setInclude(_ include: Bool, bucket: ImportReviewBucket) {
        for i in rows.indices where rows[i].bucket == bucket && !rows[i].ignored {
            rows[i].include = include
        }
    }

    func selectAllPSN(in group: PSNReviewGroup) { setIncludePSN(true, group: group) }
    func selectNonePSN(in group: PSNReviewGroup) { setIncludePSN(false, group: group) }
    private func setIncludePSN(_ include: Bool, group: PSNReviewGroup) {
        for i in rows.indices where !rows[i].ignored && psnGroup(for: rows[i]) == group {
            rows[i].include = include
        }
    }

    private func persist(_ externalID: String, _ decision: ImportDecision) {
        let store = staging, src = source
        Task { try? await store.setDecision(source: src, externalID: externalID, decision) }
    }

    // MARK: Commit

    /// The commit payload for the ticked rows (pure — asserted directly in tests). A row
    /// tied to an existing library game commits as `.existingGame`; otherwise a new game
    /// is created (`LibraryStore` dedupes by IGDB id, so a game already present is not
    /// duplicated). Games land owned, not played (PLAN §14.3).
    func commitItems() -> [ImportCommitItem] {
        rows.filter(\.isCommittable).map { row in
            let platformID = row.platform ?? "pc"
            let target: ImportCommitItem.Target
            if let gameID = row.matchedGameID {
                target = .existingGame(gameID: gameID)
            } else {
                let title = row.proposedMatch?.name ?? row.sourceTitle
                let alts = (row.proposedMatch != nil && row.showsSourceTitle) ? [row.sourceTitle] : []
                target = .newGame(ImportNewGameSpec(
                    title: title, igdbID: row.proposedMatch?.igdbID,
                    releaseYear: row.releaseYear, altTitles: alts))
            }
            // A played-only PSN row the owner chose to own commits a copy of the chosen
            // format (PLAN §13.3 "own these as ▸ Physical / Digital"); everything else keeps
            // the sheet's default format.
            return ImportCommitItem(
                source: source, externalID: row.externalID, platformID: platformID,
                format: row.ownAsFormat ?? productFormat, target: target,
                edition: row.edition, acquiredAt: row.acquiredAt,
                psn: psnCommit(for: row))
        }
    }

    /// The PSN-specific outcomes a row commits (PLAN §13.3), or nil for GOG/Delicious.
    /// Built from the transient staging row: a purchase creates an owned digital copy
    /// (with any PS Plus flag), a trophy/game-list title marks the game played (unless it
    /// was merely *launched* at 0 %) and records its play time, dates and a 100 % status.
    private func psnCommit(for row: ImportReviewRow) -> PSNCommit? {
        guard source == ImportSourceID.psn, let t = transientByID[row.externalID] else { return nil }
        // The owner's "own as ▸ …" choice forces an owned copy on a played-only row.
        return PSNCommit(
            createProduct: t.signals.contains(.owned) || row.ownAsFormat != nil,
            subscription: t.subscription?.rawValue,
            markPlayed: t.signals.contains(.played) && !t.launchedNotPlayed,
            playDurationS: t.playDurationS,
            statusPrefill: t.statusPrefill,
            firstPlayedAt: t.firstPlayedAt,
            lastPlayedAt: t.lastPlayedAt)
    }

    /// The committable rows projected for a source-specific committer (Batocera, PLAN §15).
    /// Carries the resolved match so the committer can build its own commit shape.
    func commitRows() -> [ImportReviewCommitRow] {
        rows.filter(\.isCommittable).map { row in
            ImportReviewCommitRow(
                externalID: row.externalID,
                platformID: row.platform,
                matchedGameID: row.matchedGameID,
                igdbID: row.proposedMatch?.igdbID,
                title: row.proposedMatch?.name ?? row.sourceTitle,
                releaseYear: row.releaseYear)
        }
    }

    func commit() {
        guard canCommit else { return }
        isCommitting = true
        commitError = nil
        let items = commitItems()
        let custom = customCommit
        let customRows = commitRows()
        // Snapshot the imported/updated split before commit (the PSN banner reads it).
        let psnBanner = isPSN ? psnSuccessMessage() : nil
        let store = staging
        let after = afterCommit
        let useCovers = useSourceCovers
        Task {
            do {
                let result: ImportCommitResult
                if let custom { result = try await custom(customRows) }
                else { result = try await store.commit(items) }
                // File sources (Delicious) can apply their own covers to games left
                // without one — a background step, never blocking the success banner.
                if let after { await after(result, useCovers) }
                // Promotion-on-play (PLAN §16): a PS Plus claim that crossed the 10-minute gate
                // was just imported as an owned-via-subscription copy — link its Vault row to the
                // new game so the browser shows "In Library". Idempotent; no-op for other sources.
                if source == ImportSourceID.psn {
                    try? await RomCatalogStore(store.database).linkPromotedFromProducts(source: source)
                }
                successMessage = psnBanner ?? Self.successMessage(from: result, sourceLabel: sourceLabel)
                committed = true
                onLibraryChanged()
            } catch {
                commitError = "Couldn't import the games — nothing was changed."
            }
            isCommitting = false
        }
    }

    /// The PSN banner "N games imported from PlayStation · M updated" (PLAN §13.3), computed
    /// from the ticked rows (new = imported, already-in-library = updated).
    func psnSuccessMessage() -> String {
        let committable = rows.filter(\.isCommittable)
        let updated = committable.filter { $0.matchedGameID != nil }.count
        let imported = committable.count - updated
        var message = "\(imported) game\(imported == 1 ? "" : "s") imported from PlayStation"
        if updated > 0 { message += " · \(updated) updated" }
        return message
    }

    static func successMessage(from result: ImportCommitResult, sourceLabel: String) -> String {
        // One imported title = one copy added. A brand-new game ALSO bumps `gamesCreated`,
        // so summing the two counted every new game twice ("10 selected → 20 imported").
        let imported = result.productsAdded
        var bits = ["\(imported) game\(imported == 1 ? "" : "s") imported from \(sourceLabel)"]
        let addedToExisting = imported - result.gamesCreated
        if result.gamesCreated > 0, addedToExisting > 0 {
            bits.append("\(result.gamesCreated) new · \(addedToExisting) added to games you already had")
        }
        if result.skippedExisting > 0 {
            bits.append("\(result.skippedExisting) already in your library")
        }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Sheet

/// The shared import review sheet (PLAN §14.3): header summary + platform switch, three
/// buckets (*New / Already matched / Ignored*), one commit.
struct ImportReviewSheet: View {
    @Bindable var model: ImportReviewModel
    var onClose: () -> Void = {}
    /// The "In the Vault (N)" group is collapsed by default (PLAN §16 — read-only, out of the way).
    @State private var vaultExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await model.load() }
        .confirmationDialog(
            "Remove \(model.tickedRemovalCount) PS Plus cop\(model.tickedRemovalCount == 1 ? "y" : "ies")?",
            isPresented: $model.removalConfirming, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.confirmApplyRemovals() }
            Button("Cancel", role: .cancel) { model.removalConfirming = false }
        } message: {
            Text("These claims are no longer listed by PlayStation. Removing keeps any game you played (as played, not owned) and deletes copies you never played.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from \(model.sourceLabel)").font(.headline)
                Text(model.summaryLine).font(.caption).foregroundStyle(.secondary)
                if let plus = model.psPlusHeaderSummary {
                    Text(plus).font(.caption).foregroundStyle(.secondary)
                }
                if let note = model.summary.ownedGapNote {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if model.showsSourceCoverToggle {
                    Toggle("Use my \(model.sourceLabel) covers when a game has no cover",
                           isOn: $model.useSourceCovers)
                        .font(.caption).toggleStyle(.checkbox)
                }
            }
            Spacer()
            // The pc/mac platform switch is meaningful only where rows can be re-mapped between
            // pc and mac (GOG; Delicious hybrid discs) — hidden for PSN / Batocera (coordinator).
            if model.showsPlatformPolicy {
                Picker("Platform", selection: $model.platformPolicy) {
                    ForEach(ImportPlatformPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if model.isPSN {
            psnList
        } else {
            List {
                ForEach(model.presentBuckets, id: \.self) { bucket in
                    Section {
                        ForEach(model.rows(in: bucket)) { row in
                            ImportReviewRowView(model: model, row: row)
                        }
                    } header: {
                        bucketHeader(bucket)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    /// The richer PSN grouping (PLAN §13.3): one section per ``PSNReviewGroup`` plus a
    /// proposed-removals section for lapsed PS Plus claims.
    private var psnList: some View {
        List {
            ForEach(model.presentPSNGroups, id: \.self) { group in
                if group == .inTheVault {
                    Section { inTheVaultGroup }
                } else {
                    Section {
                        ForEach(model.psnRows(in: group)) { row in
                            PSNReviewRowView(model: model, row: row, group: group)
                        }
                        if group == .playedNoPurchase {
                            ownAsRow
                        }
                    } header: {
                        psnGroupHeader(group)
                    }
                }
            }
            if !model.proposedRemovals.isEmpty {
                Section {
                    ForEach(model.proposedRemovals) { removal in
                        removalRow(removal)
                    }
                    removalActionRow
                } header: {
                    HStack {
                        Text("Proposed removals").font(.headline)
                        Text("\(model.proposedRemovals.count)").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("PS Plus claims this sync no longer lists. Tick any to remove; nothing is removed unless you confirm.")
                        .font(.caption)
                }
            }
        }
        .listStyle(.inset)
    }

    /// The collapsed, read-only "In the Vault (N)" group (PLAN §16): the barely-played claims
    /// the 10-minute rule moved to the Vault, with a button that opens the Vault browser.
    private var inTheVaultGroup: some View {
        let rows = model.psnRows(in: .inTheVault)
        return DisclosureGroup(isExpanded: $vaultExpanded) {
            ForEach(rows) { row in
                PSNReviewRowView(model: model, row: row, group: .inTheVault)
            }
        } label: {
            HStack {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                Text("In the Vault").font(.headline)
                Text("\(rows.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Show in the Vault") { model.onShowInVault(); onClose() }
                    .controlSize(.small)
                    .accessibilityIdentifier("review.showInVault")
            }
        }
    }

    private func psnGroupHeader(_ group: PSNReviewGroup) -> some View {
        let total = model.psnRows(in: group).count
        let hasTicks = group != .ignored && group != .alreadyInLibrary && group != .inTheVault
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                if group == .psPlus {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color(hex: "#0070D1") ?? .blue)
                }
                Text(group.label).font(.headline)
                // "ticked / total" for groups with checkboxes; a plain total otherwise (coordinator).
                Text(hasTicks ? "\(model.psnTickedCount(in: group)) / \(total)" : "\(total)")
                    .foregroundStyle(.secondary)
                Spacer()
                if hasTicks {
                    Button("All") { model.selectAllPSN(in: group) }.controlSize(.small)
                    Button("None") { model.selectNonePSN(in: group) }.controlSize(.small)
                }
            }
            if let footnote = group.footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var ownAsRow: some View {
        HStack(spacing: 8) {
            Text("Own the ticked rows as").font(.caption).foregroundStyle(.secondary)
            // Physical is the default: these are played games with no digital licence, so most
            // likely discs (PLAN §13.3 rule 3 / item 2 — `service: other`).
            Button("Physical") { model.ownTickedAs(.physical) }
                .controlSize(.small).buttonStyle(.borderedProminent)
            Button("Digital") { model.ownTickedAs(.digital) }.controlSize(.small)
        }
        .disabled(!model.canOwnPlayedRows)
    }

    private func removalRow(_ removal: ImportSubscriptionRemovalProposal) -> some View {
        Toggle(isOn: Binding(
            get: { model.removalTicks.contains(removal.productID) },
            set: { model.toggleRemoval(removal.productID, $0) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(removal.gameTitle ?? removal.externalID)
                Text("PS Plus copy no longer claimed").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    @ViewBuilder
    private var removalActionRow: some View {
        HStack {
            Spacer()
            Button("Remove \(model.tickedRemovalCount) ticked cop\(model.tickedRemovalCount == 1 ? "y" : "ies")…",
                   role: .destructive) { model.requestApplyRemovals() }
                .controlSize(.small)
                .disabled(model.tickedRemovalCount == 0)
        }
    }

    private func bucketHeader(_ bucket: ImportReviewBucket) -> some View {
        HStack {
            Text(bucket.label).font(.headline)
            Text("\(model.rows(in: bucket).count)").foregroundStyle(.secondary)
            Spacer()
            if bucket != .ignored {
                Button("All") { model.selectAll(in: bucket) }.controlSize(.small)
                Button("None") { model.selectNone(in: bucket) }.controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let message = model.successMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("\(model.committableCount) selected").foregroundStyle(.secondary)
            }
            if let error = model.commitError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Spacer()
            if model.committed {
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button(model.commitButtonTitle) { model.commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCommit)
                    .overlay(alignment: .trailing) {
                        if model.isCommitting { ProgressView().controlSize(.small).offset(x: 22) }
                    }
            }
        }
        .padding(12)
    }
}

// MARK: - Row

private struct ImportReviewRowView: View {
    @Bindable var model: ImportReviewModel
    let row: ImportReviewRow
    /// The shared IGDB searcher for the inline "Find…" (PLAN §5.1 item 6); nil offline.
    @Environment(\.igdbCatalogSearcher) private var searcher
    /// The inline link-search sheet's model while open (created on "Find…").
    @State private var finderModel: IGDBLinkModel?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.bucket != .ignored { includeCheckbox }
            ImportCoverThumb(imageID: row.proposedMatch?.coverImageID)
            titleBlock
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .sheet(item: $finderModel) { model in IGDBLinkSheet(model: model) }
    }

    /// A ticked New row with no IGDB match will import unlinked (PLAN §5.1) — warn, and
    /// offer an inline "Find…" that opens the same link search.
    private var showsUnlinkedWarning: Bool {
        row.bucket == .new && row.include && row.proposedMatch == nil && row.matchedGameID == nil
    }

    @ViewBuilder
    private var unlinkedWarning: some View {
        if showsUnlinkedWarning {
            HStack(spacing: 4) {
                Label("no IGDB match — will import unlinked", systemImage: "link.badge.plus")
                    .font(.caption2).foregroundStyle(.orange)
                    .help("No IGDB match: this title imports unlinked — no metadata, cover or "
                          + "time estimates, and a later import could duplicate it. Link it here "
                          + "or later from the Unlinked list.")
                if searcher != nil {
                    Button("Find…") { openFinder() }
                        .font(.caption2).buttonStyle(.borderless)
                }
            }
        }
    }

    private func openFinder() {
        guard let searcher else { return }
        let m = IGDBLinkModel(
            gameID: 0, currentTitle: row.sourceTitle, platformSlugs: [], year: row.releaseYear,
            isLinked: false, prefill: IGDBLinkQuery.clean(row.sourceTitle), searcher: searcher)
        m.onChoose = { choice in
            let match = ScanMatch(igdbID: choice.igdbID, name: choice.title, releaseYear: choice.year,
                                  coverImageID: nil, platformSlugs: [], score: 1.0, matchedName: choice.title)
            model.chooseAlternative(match, externalID: row.externalID)
            finderModel = nil
        }
        m.onCancel = { finderModel = nil }
        finderModel = m
    }

    private var includeCheckbox: some View {
        Button {
            model.setInclude(!row.include, externalID: row.externalID)
        } label: {
            Image(systemName: row.include ? "checkmark.square.fill" : "square")
                .foregroundStyle(row.include ? Color.accentColor : .secondary)
                .font(.title3)
        }
        .buttonStyle(.borderless)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.matchedTitle ?? row.sourceTitle).bold()
                if let year = row.releaseYear { Text(String(year)).foregroundStyle(.secondary) }
                confidenceBadge
            }
            if row.showsSourceTitle, row.matchedTitle != nil {
                Text("\(model.sourceLabel): \(row.sourceTitle)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                platformMenu
                if row.linuxOnly {
                    Text("Linux-only → PC").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("This title runs only on Linux; imported as a PC game.")
                }
                if let note = row.duplicateNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                if let edition = row.edition {
                    Text(edition).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let reason = row.ignoreReason, row.bucket == .ignored {
                    Text(reason.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let detail = model.rowDetailByID[row.externalID], !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            unlinkedWarning
        }
    }

    private var confidenceBadge: some View {
        Group {
            if let score = row.proposedMatch?.score {
                Text("\(Int(score * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var platformMenu: some View {
        Menu {
            ForEach(model.platformChoices, id: \.self) { slug in
                Button(PlatformLabels.short(slug)) { model.setPlatform(slug, externalID: row.externalID) }
            }
        } label: {
            Text(row.platform.map(PlatformLabels.short) ?? "platform?")
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .background(.tint.opacity(0.2), in: Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            Menu {
                MatchAlternativesSection(alternatives: row.alternatives) { alt in
                    model.chooseAlternative(alt, externalID: row.externalID)
                }
                Divider()
                if row.bucket == .ignored {
                    Button("Restore") { model.restore(row.externalID) }
                } else {
                    Button("Ignore", role: .destructive) { model.ignore(row.externalID) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

// MARK: - PSN row

/// A compact PSN review row (PLAN §13.3): the include checkbox, cover, title/platform, and a
/// per-group annotation — the change line for *Already in your library*, an "own as" chip for
/// a played-only row the owner elected to own, and the alternatives/ignore menu.
private struct PSNReviewRowView: View {
    @Bindable var model: ImportReviewModel
    let row: ImportReviewRow
    let group: PSNReviewGroup

    /// Read-only groups have no include checkbox and no ignore/restore menu.
    private var isReadOnly: Bool { group == .inTheVault }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if group != .ignored && !isReadOnly { includeCheckbox }
            ImportCoverThumb(imageID: row.proposedMatch?.coverImageID)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.matchedTitle ?? row.sourceTitle).bold()
                    if let year = row.releaseYear { Text(String(year)).foregroundStyle(.secondary) }
                }
                if row.showsSourceTitle, row.matchedTitle != nil {
                    Text("PlayStation: \(row.sourceTitle)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let platform = row.platform {
                        Text(PlatformLabels.short(platform)).font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                    if group == .alreadyInLibrary {
                        Text(model.psnChangeDescription(for: row)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let format = row.ownAsFormat {
                        Text("own as \(format.label)").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let reason = row.ignoreReason, group == .ignored {
                        Text(reason.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if !isReadOnly {
                Menu {
                    MatchAlternativesSection(alternatives: row.alternatives) { alt in
                        model.chooseAlternative(alt, externalID: row.externalID)
                    }
                    Divider()
                    if group == .ignored {
                        Button("Restore") { model.restore(row.externalID) }
                    } else {
                        Button("Ignore", role: .destructive) { model.ignore(row.externalID) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private var includeCheckbox: some View {
        Button {
            model.setInclude(!row.include, externalID: row.externalID)
        } label: {
            Image(systemName: row.include ? "checkmark.square.fill" : "square")
                .foregroundStyle(row.include ? Color.accentColor : .secondary)
                .font(.title3)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Cover thumb

private struct ImportCoverThumb: View {
    let imageID: String?

    var body: some View {
        Group {
            if let imageID, let url = IGDBImageURL.cover(imageID: imageID, size: .coverSmall) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: 30, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary).font(.caption2))
    }
}
