import Foundation

/// Pure PSN DTO → staging-row mapping (PLAN §13.3 / §16). Foundation only, no I/O, so every
/// rule is trivially testable: platform strings → VGN slugs, the three lists joined into one
/// row per game, the played/launched/100 % signals, the `service`/`category` rules learned
/// live (2026-09-20), PS Plus (owned-via-subscription vs the Vault), cross-gen twins, and the
/// noise rules (each with a reason for the review sheet). Never creates a physical copy on
/// its own (PLAN §13.3 — "PSN never creates a physical copy").
enum PSNMapping {

    /// A game-list play time of ≥ 30 min promotes a 0 % trophy title to *played* (PLAN §13.3).
    static let playedPromotionSeconds = 30 * 60

    /// The Vault's shared 10-minute gate (PLAN §16): a `PS_PLUS` entitlement played **at or
    /// below** this goes to the Vault (staged ignored), not the library.
    static var vaultGateSeconds: Int { ImportPolicy.vaultPlaytimeGateSeconds }

    // MARK: - Entry point

    /// Join the three lists into one staging row per game. The join is by **concept id →
    /// title id → normalised name** (name only, so cross-gen twins with different title ids
    /// and a null concept id still merge): trophy titles carry no ids so they join by name +
    /// platform-agnostic canonical name (PLAN §13.3, live 2026-09-20). Order is deterministic
    /// (trophy titles first in input order, then game-list-only, then purchase-only), so a
    /// re-sync produces a stable list.
    static func stagingRows(trophyTitles: [PSNTrophyTitle],
                            gameList: [PSNGameListTitle],
                            purchases: [PSNPurchasedGame]) -> [ImportStagingRow] {
        let index = MergeIndex()

        // 1) Trophy titles — the whole launch history (one list; PS3/PS4/PS5/Vita mixed).
        for title in trophyTitles {
            let p = platformSlugs(title.trophyTitlePlatform)
            let m = index.upsert(concept: nil, title: nil, name: title.trophyTitleName)
            m.absorbTrophy(title, slugs: p.all, combined: p.combined)
        }

        // 2) Game list — play time / first-last / ids + `service`/`category` (PS4/PS5). The
        //    platform is the category's generation, falling back to the title-id prefix for
        //    `unknown` / `not_found` categories (live 2026-09-20).
        for title in gameList {
            let slug = slug(fromCategory: title.category) ?? slug(fromTitleId: title.titleId)
            let m = index.upsert(concept: title.concept?.id, title: title.titleId, name: title.name)
            m.absorbGameList(title, slug: slug)
        }

        // 3) Purchases — owned digital, PS Plus, cross-gen twins.
        for purchase in purchases {
            let (slug, _) = platformSlug(purchase.platform ?? "")
            let m = index.upsert(concept: purchase.conceptId, title: purchase.titleId, name: purchase.name)
            m.absorbPurchase(purchase, slug: slug)
        }

        return index.ordered.compactMap { $0.row() }
    }

    /// Build the PS Plus **Vault** entries from the three lists (PLAN §16). A vaulted game is a
    /// PS Plus claim (never a bought copy) played at or below the 10-minute gate — including
    /// never launched. Cross-gen twins are one entry (the same merge as ``stagingRows``), so a
    /// re-sync is stable. Returns the entries plus the set of external ids currently vaulted,
    /// for ``RomCatalogStore/syncPSNVault(entries:presentExternalIDs:)`` to remove claims that
    /// vanished (or crossed the gate into the review sheet).
    static func vaultEntries(trophyTitles: [PSNTrophyTitle],
                             gameList: [PSNGameListTitle],
                             purchases: [PSNPurchasedGame])
        -> (entries: [RomCatalogEntry], presentExternalIDs: Set<String>) {
        // The same merge as `stagingRows` (identical platform pick incl. the title-id fallback
        // for `unknown` / `not_found` categories), so the Vault and the review sheet agree.
        let index = MergeIndex()
        for title in trophyTitles {
            let p = platformSlugs(title.trophyTitlePlatform)
            index.upsert(concept: nil, title: nil, name: title.trophyTitleName)
                .absorbTrophy(title, slugs: p.all, combined: p.combined)
        }
        for title in gameList {
            let slug = slug(fromCategory: title.category) ?? slug(fromTitleId: title.titleId)
            index.upsert(concept: title.concept?.id, title: title.titleId, name: title.name)
                .absorbGameList(title, slug: slug)
        }
        for purchase in purchases {
            let (slug, _) = platformSlug(purchase.platform ?? "")
            index.upsert(concept: purchase.conceptId, title: purchase.titleId, name: purchase.name)
                .absorbPurchase(purchase, slug: slug)
        }

        var entries: [RomCatalogEntry] = []
        var present = Set<String>()
        for merged in index.ordered where merged.isVaulted {
            let ext = merged.externalID
            present.insert(ext)
            entries.append(RomCatalogEntry.makePSNVault(
                externalID: ext,
                platform: merged.bestSlug ?? "",
                name: merged.name,
                coverURL: merged.coverURL,
                membership: ProductSubscription.psPlus.rawValue,
                crossGenNote: merged.vaultCrossGenNote))
        }
        return (entries, present)
    }

    // MARK: - Join index

    /// A small union index keyed by concept id, title id and canonical name. A source item
    /// finds an existing merged game by concept → title → name (in that priority), then
    /// registers the merged game under every id it now knows, so a later twin joins it.
    final class MergeIndex {
        private var byConcept: [String: Merged] = [:]
        private var byTitle: [String: Merged] = [:]
        private var byName: [String: Merged] = [:]
        private(set) var ordered: [Merged] = []

        func upsert(concept: String?, title: String?, name: String) -> Merged {
            let nameKey = PSNMapping.canonicalNameKey(name)
            let found = concept.flatMap { byConcept[$0] }
                ?? title.flatMap { byTitle[$0] }
                ?? byName[nameKey]
            let m: Merged
            if let found {
                m = found
            } else {
                m = Merged(name: name)
                ordered.append(m)
            }
            if let concept { byConcept[concept] = m }
            if let title { byTitle[title] = m }
            if byName[nameKey] == nil { byName[nameKey] = m }
            return m
        }
    }

    // MARK: - Platform strings (PLAN §13.3)

    /// A VGN platform slug for a trophy/purchase platform string, plus whether it was a
    /// **combined** string (e.g. `"PS4,PS5"`, `"PS3,PSVITA"`). Pick rule for a combined
    /// string: the **newest** platform, since VGN models one copy per platform. The pick is
    /// **order-independent** — the real combined strings arrive oldest-first (`"PSVITA,PS4"`,
    /// `"PS3,PSVITA,PS4"`, live 2026-09-20) yet still resolve to the newest console.
    static func platformSlug(_ raw: String) -> (slug: String?, combined: Bool) {
        let p = platformSlugs(raw)
        return (p.best, p.combined)
    }

    /// Every recognised slug in a (possibly combined) platform string, plus the newest one
    /// (`best`) and whether the string listed more than one. Used to record *all* platforms of
    /// a combined trophy title so the review note can say "also on …".
    static func platformSlugs(_ raw: String) -> (best: String?, all: [String], combined: Bool) {
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        let slugs = parts.compactMap(Self.slug(fromToken:))
        let best = slugs.max(by: { generationRank($0) < generationRank($1) })
        let combined = slugs.isEmpty ? parts.count > 1 : Set(slugs).count > 1
        return (best, slugs, combined)
    }

    private static func slug(fromToken token: String) -> String? {
        switch token {
        case "PS5": return "ps5"
        case "PS4": return "ps4"
        case "PS3": return "ps3"
        case "PS2": return "ps2"
        case "PS1", "PSX", "PSONE": return "ps1"
        case "PSVITA", "VITA", "PSV": return "vita"
        case "PSP": return "psp"
        default: return nil
        }
    }

    /// The game list has no platform field; the **`category`** (`ps4_game`, `ps5_native_game`,
    /// `ps5_native_media_app`) gives it (live, 2026-09-20). Returns nil when the category does
    /// not name a generation (`unknown` / `not_found`) — the caller falls back to the title id.
    static func slug(fromCategory raw: String?) -> String? {
        guard let s = raw?.lowercased() else { return nil }
        if s.contains("ps5") { return "ps5" }
        if s.contains("ps4") { return "ps4" }
        if s.contains("ps3") { return "ps3" }
        if s.contains("vita") { return "vita" }
        if s.contains("psp") { return "psp" }
        return nil
    }

    /// A VGN slug from the leading format code of a PSN `titleId`, used when the game-list
    /// `category` cannot give the platform (`unknown` / `not_found`). In the owner's real data
    /// (live 2026-09-20) only two prefixes appear: `PPSA…` = PS5, `CUSA…` = PS4 (all six
    /// `unknown` and both `not_found` rows were `CUSA…`, i.e. PS4). The other well-known Sony
    /// codes are mapped best-effort; anything unrecognised returns nil so the owner picks the
    /// platform in the review row.
    static func slug(fromTitleId titleId: String?) -> String? {
        guard let id = titleId, id.count >= 4 else { return nil }
        switch id.prefix(4).uppercased() {
        case "PPSA", "PPSE": return "ps5"                                   // PS5 (seen: PPSA)
        case "CUSA", "CUSE": return "ps4"                                   // PS4 (seen: CUSA)
        case "PCSA", "PCSB", "PCSC", "PCSD", "PCSE", "PCSF", "PCSG":
            return "vita"                                                   // PS Vita (best-effort)
        default: return nil
        }
    }

    /// How the game-list `category` classifies a title (PLAN §13.3, live 2026-09-20).
    enum CategoryKind: Equatable {
        /// A game — `category` ends in `_game`, or is absent (a trophy/purchase-only title).
        case game
        /// A non-game app (Netflix, Plex, YouTube, Media Player…) → *Ignored* ("media app").
        case app
        /// `unknown` / `not_found` (delisted/old games) or any future non-game, non-app value
        /// → kept as a **game** with a "category unknown" review note; platform from the id.
        case unknownCategory
    }

    /// Category keywords that mark a non-game app, matched anywhere in the value:
    /// `ps5_native_media_app`, `ps5_web_based_media_app`, `ps4_videoservice_web_app`,
    /// `ps4_nongame_mini_app` (live 2026-09-20).
    private static let appCategoryKeywords = ["media_app", "videoservice", "web_app",
                                              "nongame", "mini_app"]

    /// Classify a game-list `category`. Unseen future values fall through the same ladder:
    /// a `…_game` is a game, an app-keyword value is an app, everything else is kept as a
    /// game flagged "category unknown" — **never silently dropped**.
    static func classifyCategory(_ raw: String?) -> CategoryKind {
        guard let c = raw?.lowercased(), !c.isEmpty else { return .game }
        if appCategoryKeywords.contains(where: { c.contains($0) }) { return .app }
        if c.hasSuffix("_game") { return .game }
        return .unknownCategory
    }

    /// The game-list `service` normalised to how a title was accessed. Two spellings of a
    /// digital purchase are seen live (2026-09-20): `none(purchased)` (both generations) and
    /// `none_purchased` (only ever on `CUSA…` = PS4-generation records — the underscore form
    /// never appears on a PS5 / `ps5_native_game` title); both fold to ``ServiceAccess/purchased``.
    /// Normalisation drops case, spaces, underscores, hyphens and parentheses, so
    /// `None (Purchased)`, `none-purchased`, `PS Plus`, `ps_plus` … all map to one case;
    /// genuinely unknown strings are kept **raw and shown** and never assert ownership.
    enum ServiceAccess: Equatable {
        case purchased                 // none(purchased) / none_purchased → owned digital
        case psPlus                    // ps_plus → played through PS Plus
        case other                     // other → neither (the owner's disc games)
        case unknown(String)           // kept raw and shown
    }

    static func classifyService(_ raw: String?) -> ServiceAccess? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased().filter({ $0.isLetter }) {
        case "nonepurchased": return .purchased
        case "psplus": return .psPlus
        case "other": return .other
        default: return .unknown(trimmed)
        }
    }

    /// Generation ordering for the combined-platform pick, strictly decreasing by release
    /// (PS5 > PS4 > Vita > PS3 > PSP > PS2 > PS1). The newest wins; for the real trophy
    /// strings `"PSVITA,PS4"` / `"PS3,PSVITA,PS4"` this is PS4 regardless of the listed order.
    private static func generationRank(_ slug: String) -> Int {
        switch slug {
        case "ps5": return 7
        case "ps4": return 6
        case "vita": return 5
        case "ps3": return 4
        case "psp": return 3
        case "ps2": return 2
        case "ps1": return 1
        default: return 0
        }
    }

    // MARK: - Membership (PLAN §13.3, live 2026-09-20)

    /// Classify a purchase `membership`: `NONE` (or absent) = a bought copy I really own;
    /// `PS_PLUS` (any case) = a subscription claim; anything else is kept **raw and shown**.
    static func classifyMembership(_ raw: String?) -> (bought: Bool, plus: Bool, unknownRaw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (bought: true, plus: false, unknownRaw: nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("NONE") == .orderedSame { return (true, false, nil) }
        if ProductSubscription(storage: trimmed)?.isPSPlus == true { return (false, true, nil) }
        return (false, false, trimmed)
    }

    // MARK: - Join key / match title

    static func canonicalNameKey(_ name: String) -> String {
        TitleNormalizer.normalize(name, level: .canonical)
    }

    static func joinKey(name: String, slug: String?) -> String {
        canonicalNameKey(name) + "|" + (slug ?? "?")
    }

    /// The IGDB-match title: the display name with ™/®/©/℠ stripped, whitespace collapsed, and
    /// the platform tail Sony appends dropped (PLAN §13.3 item 5 / D5), case preserved. Set on
    /// the row only when it differs from `name` (the shown title is never changed).
    static func cleanMatchTitle(_ name: String) -> String {
        var s = name
        for symbol in ["™", "®", "©", "℠"] { s = s.replacingOccurrences(of: symbol, with: "") }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return dropPlatformTail(s)
    }

    /// Drop a trailing platform tail Sony appends for MATCHING only (PLAN §13.3 / D5): a run of
    /// PlayStation platform tokens at the end of the title — "… PS4 & PS5", "… (PS4)", "… PS5",
    /// "… for PS4", "… PS4/PS5" — so a cross-gen twin matches the same IGDB game as its sibling.
    /// Deliberately conservative: it only strips a **trailing** run of recognised platform tokens
    /// (optionally in parentheses, optionally after "for"), never the interior of a title, and
    /// never the whole string — a title that *is* a platform token is left alone. Counter-cases
    /// like "Persona 5", "NBA 2K21", "Katamari Damacy" carry no platform token and are untouched.
    static func dropPlatformTail(_ title: String) -> String {
        // One platform token: PS1–PS5, PS Vita, PSVR(2), PlayStation 4/5, PlayStation Vita.
        let tok = #"(?:ps\s?[1-5]|ps\s?vita|psvr\s?2?|playstation\s?[1-5]|playstation\s?vita)"#
        // A parenthesised tail: " (PS4)", " (PS4/PS5)".
        let paren = #"\s*\((?:"# + tok + #")(?:\s*[,/&]\s*(?:"# + tok + #"))*\)\s*$"#
        // A bare tail: " PS4 & PS5", " for PS4", optionally joined by & , / and.
        let bare = #"\s+(?:for\s+)?(?:"# + tok + #")(?:\s*(?:&|,|/|and)\s*(?:"# + tok + #"))*\s*$"#
        for pattern in [paren, bare] {
            if let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let stripped = title.replacingCharacters(in: range, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Never strip the whole title away (a title that is only a platform token stays).
                if !stripped.isEmpty { return stripped }
            }
        }
        return title
    }

    // MARK: - Noise (PLAN §13.3)

    /// A noise reason for a name (demos, betas, themes/avatars, add-ons, media apps), or nil.
    static func nameNoise(_ name: String) -> ImportIgnoreReason? {
        let h = name.lowercased()
        if containsAny(h, mediaAppKeywords) { return .mediaApp }
        if containsAny(h, demoKeywords) { return .demoOrPrologue }
        if containsAny(h, betaKeywords) { return .betaOrTrial }
        if containsAny(h, themeKeywords) { return .themeOrAvatar }
        if containsAny(h, addOnKeywords) { return .dlcOrExpansion }
        return nil
    }

    private static let demoKeywords = ["(demo)", " demo", "demo)", "trial version"]
    private static let betaKeywords = [" beta", "(beta)", " alpha ", "open beta", "closed beta"]
    private static let themeKeywords = ["dynamic theme", " theme", "avatar", "wallpaper"]
    private static let addOnKeywords = ["add-on", "add on", " dlc", "season pass", "expansion pass",
                                        "bundle pack", "- pack"]
    private static let mediaAppKeywords = ["netflix", "spotify", "youtube", "hulu", "disney+",
                                           "twitch", "crunchyroll", "plex", "amazon prime",
                                           "apple tv", "media player", "wwe network"]

    private static func containsAny(_ h: String, _ needles: [String]) -> Bool {
        needles.contains { h.contains($0) }
    }

    // MARK: - Merge accumulator

    /// One game as merged from the three lists, before it becomes a staging row.
    final class Merged {
        /// The display name kept for the row — the first source's name (trophy first), which
        /// may carry ™/®/© (the match title strips them; the shown name does not).
        let name: String
        /// Every VGN slug seen across the three sources; the row's platform is the newest.
        var platforms: Set<String> = []
        var combinedPlatform = false

        var npCommunicationId: String?
        var conceptId: String?
        var titleId: String?

        var progress: Int?
        var playDurationS: Int?
        var firstPlayedAt: Date?
        var lastPlayedAt: Date?

        var hasTrophy = false
        var hasGameList = false
        /// The raw game-list `service` (`none(purchased)` / `ps_plus` / `other` / unknown).
        var service: String?
        var category: String?

        // Purchases.
        var purchaseSeen = false
        var boughtSeen = false        // membership NONE / absent
        var plusSeen = false          // membership PS_PLUS
        var unknownMembership: String?
        var purchasePlatforms: Set<String> = []
        var entitlementByPlatform: [String: String] = [:]
        var anyEntitlementId: String?
        var isPreOrder = false
        var isActive = true
        /// The PS Store cover URL (first purchase that carries one) — for the Vault (PLAN §16).
        var coverURL: String?

        init(name: String) { self.name = name }

        func absorbTrophy(_ t: PSNTrophyTitle, slugs: [String], combined: Bool) {
            hasTrophy = true
            npCommunicationId = npCommunicationId ?? t.npCommunicationId
            progress = max(progress ?? 0, t.progress)
            if let last = t.lastUpdatedDateTime, last != .distantPast {
                lastPlayedAt = maxDate(lastPlayedAt, last)
            }
            // Record every platform of a combined string so the note can say "also on …";
            // `bestSlug` still picks the newest for the row's own platform.
            for s in slugs { platforms.insert(s) }
            combinedPlatform = combinedPlatform || combined
        }

        func absorbGameList(_ g: PSNGameListTitle, slug: String?) {
            hasGameList = true
            titleId = titleId ?? g.titleId
            if let cid = g.concept?.id { conceptId = conceptId ?? cid }
            if let secs = g.playDurationSeconds { playDurationS = max(playDurationS ?? 0, secs) }
            if let first = g.firstPlayedDateTime, first != .distantPast {
                firstPlayedAt = minDate(firstPlayedAt, first)
            }
            if let last = g.lastPlayedDateTime, last != .distantPast {
                lastPlayedAt = maxDate(lastPlayedAt, last)
            }
            if let slug { platforms.insert(slug) }
            service = service ?? g.service
            category = category ?? g.category
        }

        func absorbPurchase(_ p: PSNPurchasedGame, slug: String?) {
            purchaseSeen = true
            if let cid = p.conceptId { conceptId = conceptId ?? cid }
            titleId = titleId ?? p.titleId
            anyEntitlementId = anyEntitlementId ?? p.entitlementId
            if let slug {
                platforms.insert(slug)
                purchasePlatforms.insert(slug)
                if let e = p.entitlementId, entitlementByPlatform[slug] == nil { entitlementByPlatform[slug] = e }
            }
            let m = PSNMapping.classifyMembership(p.membership)
            if m.bought { boughtSeen = true }
            if m.plus { plusSeen = true }
            if let unknown = m.unknownRaw { unknownMembership = unknownMembership ?? unknown }
            isPreOrder = isPreOrder || (p.isPreOrder ?? false)
            if p.isActive == false { isActive = false }
            if coverURL == nil, let url = p.image?.url, !url.isEmpty { coverURL = url }
        }

        /// The game-list `category` classification (`.game` / `.app` / `.unknownCategory`).
        var categoryKind: PSNMapping.CategoryKind { PSNMapping.classifyCategory(category) }

        /// The bare PS Plus gate: a PS Plus claim, never bought, at or below the 10-minute gate
        /// (including never launched). The *decision* to vault also honours the higher-priority
        /// noise guards — see ``ignoreReason``.
        private var meetsVaultGate: Bool {
            guard purchaseSeen, !boughtSeen, plusSeen else { return false }
            return (playDurationS ?? 0) <= PSNMapping.vaultGateSeconds
        }

        /// The **single source of truth** for the staging row's ignore reason, shared by
        /// ``row()`` and ``isVaulted`` so the review sheet and the Vault can never disagree. A
        /// PS Plus claim that is *also* an app / pre-order / inactive is ignored for **that**
        /// higher-priority reason and does **not** go to the Vault.
        var ignoreReason: ImportIgnoreReason? {
            if categoryKind == .app { return .mediaApp }
            if let n = PSNMapping.nameNoise(name) { return n }
            if purchaseSeen, isPreOrder { return .preOrder }
            if purchaseSeen, !isActive { return .inactiveEntitlement }
            if meetsVaultGate { return .vaultedSubscription }
            return nil
        }

        /// Whether this merged game goes to **The Vault** (PLAN §16) — exactly when the staging
        /// row's ignore reason is ``ImportIgnoreReason/vaultedSubscription``.
        var isVaulted: Bool { ignoreReason == .vaultedSubscription }

        /// The other platforms of a **combined trophy** string, newest-first, for the "also on"
        /// note (shared by the staging note and the Vault note).
        var alsoOnPlatforms: [String] {
            guard combinedPlatform, let best = bestSlug else { return [] }
            return platforms.subtracting([best])
                .sorted { PSNMapping.generationRankPublic($0) > PSNMapping.generationRankPublic($1) }
                .map { $0.uppercased() }
        }

        /// The combined-platform annotation shared by the staging review note and the Vault:
        /// "PS4 & PS5 versions" for a cross-gen purchase, else "also on …" for a combined
        /// trophy string, else nil.
        var platformAnnotation: String? {
            if purchasePlatforms.count > 1 {
                let names = purchasePlatforms
                    .sorted { PSNMapping.generationRankPublic($0) < PSNMapping.generationRankPublic($1) }
                    .map { $0.uppercased() }
                return names.joined(separator: " & ") + " versions"
            }
            let others = alsoOnPlatforms
            return others.isEmpty ? nil : "also on " + others.joined(separator: ", ")
        }

        /// The Vault entry's note: the same platform annotation **and** "category unknown"
        /// flag the staging row's review note carries (the ownership text is always "PS Plus"
        /// for a Vault entry, so it is omitted here).
        var vaultCrossGenNote: String? {
            var parts: [String] = []
            if let p = platformAnnotation { parts.append(p) }
            if categoryKind == .unknownCategory { parts.append("category unknown") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// The chosen entitlement id for a cross-gen game: the **PS5** one wins, else PS4,
        /// else any (PLAN §13.3 item (a) — a stable external id across syncs).
        var chosenEntitlementId: String? {
            entitlementByPlatform["ps5"] ?? entitlementByPlatform["ps4"]
                ?? entitlementByPlatform.values.sorted().first ?? anyEntitlementId
        }

        /// The row's platform: the newest generation seen across the three sources.
        var bestSlug: String? {
            platforms.max(by: { PSNMapping.generationRankPublic($0) < PSNMapping.generationRankPublic($1) })
        }

        /// The stable external id: concept → chosen entitlement (owned) → title → trophy
        /// comm-id → any entitlement → name+slug.
        var externalID: String {
            if let c = conceptId { return "concept:\(c)" }
            if purchaseSeen, let e = chosenEntitlementId { return "ent:\(e)" }
            if let t = titleId { return "title:\(t)" }
            if let n = npCommunicationId { return "npwr:\(n)" }
            if let e = anyEntitlementId { return "ent:\(e)" }
            return "name:\(PSNMapping.joinKey(name: name, slug: bestSlug))"
        }

        /// Turn the merged game into a staging row (PLAN §13.3 / §16 rules).
        func row() -> ImportStagingRow {
            let slug = bestSlug
            let crossGen = purchasePlatforms.count > 1

            let playtime = playDurationS ?? 0
            let promoted = playtime >= PSNMapping.playedPromotionSeconds
            let played = (progress ?? 0) > 0 || promoted
            let launchedNotPlayed = !played && hasTrophy && (progress ?? 0) == 0

            let serviceAccess = PSNMapping.classifyService(service)
            let servicePurchased = serviceAccess == .purchased

            // Ownership + subscription + Vault (PLAN §13.3 / §16).
            var owned = false
            var subscription: ProductSubscription?
            var vaulted = false
            if purchaseSeen {
                if boughtSeen {
                    owned = true                                   // a bought copy always wins
                } else if plusSeen {
                    if playtime > PSNMapping.vaultGateSeconds {
                        owned = true; subscription = .psPlus       // owned-via-subscription "+"
                    } else {
                        vaulted = true                             // to the Vault, not the library
                    }
                } else if let raw = unknownMembership {
                    owned = true; subscription = ProductSubscription(storage: raw)
                } else {
                    owned = true
                }
            }
            // A game-list `service` of `none(purchased)` is owned digital even if the
            // purchases list missed it (PLAN §13.3 item 2).
            if !owned, !vaulted, servicePurchased { owned = true }

            var signals: ImportSignals = []
            if played { signals.insert(.played) }
            if owned { signals.insert(.owned) }

            // Noise, in priority order — the single source of truth shared with the Vault
            // (`ignoreReason`). `unknown` / `not_found` are NOT apps: they stay games (flagged
            // "category unknown"); only app-keyword categories are ignored.
            let ignore = ignoreReason

            let statusPrefill: PlayStatus? = (progress == 100) ? .completed : nil

            let clean = PSNMapping.cleanMatchTitle(name)
            let matchTitle = (clean != name && !clean.isEmpty) ? clean : nil

            let note = PSNMapping.reviewNote(
                owned: owned, played: played, launchedNotPlayed: launchedNotPlayed,
                subscription: subscription, service: serviceAccess,
                purchasePlatforms: purchasePlatforms, crossGen: crossGen,
                otherPlatforms: alsoOnPlatforms, categoryUnknown: categoryKind == .unknownCategory)

            return ImportStagingRow(
                source: ImportSourceID.psn,
                externalID: externalID,
                name: name,
                platform: slug,
                signals: signals,
                playDurationS: playDurationS,
                firstPlayedAt: firstPlayedAt,
                lastPlayedAt: lastPlayedAt,
                ignoreReason: ignore,
                matchTitle: matchTitle,
                subscription: subscription,
                launchedNotPlayed: launchedNotPlayed,
                reviewNote: note,
                statusPrefill: statusPrefill)
        }

        private func maxDate(_ a: Date?, _ b: Date) -> Date { a.map { max($0, b) } ?? b }
        private func minDate(_ a: Date?, _ b: Date) -> Date { a.map { min($0, b) } ?? b }
    }

    static func generationRankPublic(_ slug: String) -> Int { generationRank(slug) }

    // MARK: - Review note (copy-format rules 1–4 + service rules, PLAN §13.3)

    static func reviewNote(owned: Bool, played: Bool, launchedNotPlayed: Bool,
                           subscription: ProductSubscription?, service: ServiceAccess?,
                           purchasePlatforms: Set<String>, crossGen: Bool,
                           otherPlatforms: [String], categoryUnknown: Bool) -> String? {
        var note: String?
        if let subscription {
            note = subscription.isPSPlus ? "PS Plus" : subscription.rawValue
        } else if played, !owned {
            switch service {
            case .psPlus: note = "played via PS Plus"                        // item 2, catalogue
            case .other:  note = "probably a disc — not a digital licence"   // item 2, disc
            default:      note = "Played — no purchase found"                // rule 3
            }
        } else if launchedNotPlayed {
            note = "Launched, 0 %"
        }

        // Platform annotations.
        if crossGen {
            let names = purchasePlatforms
                .sorted { generationRank($0) < generationRank($1) }
                .map { $0.uppercased() }
            let platformNote = names.joined(separator: " & ") + " versions"
            note = note.map { "\($0) · \(platformNote)" } ?? platformNote
        } else if !otherPlatforms.isEmpty {
            let platformNote = "also on " + otherPlatforms.joined(separator: ", ")
            note = note.map { "\($0) · \(platformNote)" } ?? platformNote
        }

        // A game whose category we don't recognise (`unknown` / `not_found`): kept as a game,
        // flagged so the owner can confirm the platform.
        if categoryUnknown {
            let n = "category unknown"
            note = note.map { "\($0) · \(n)" } ?? n
        }
        return note
    }
}
