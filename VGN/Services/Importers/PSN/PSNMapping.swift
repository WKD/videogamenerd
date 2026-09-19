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
            let (slug, combined) = platformSlug(title.trophyTitlePlatform)
            let m = index.upsert(concept: nil, title: nil, name: title.trophyTitleName)
            m.absorbTrophy(title, slug: slug, combined: combined)
        }

        // 2) Game list — play time / first-last / ids + `service`/`category` (PS4/PS5).
        for title in gameList {
            let slug = slug(fromCategory: title.category)
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
    /// string: the **newest** platform, since VGN models one copy per platform.
    static func platformSlug(_ raw: String) -> (slug: String?, combined: Bool) {
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        let slugs = parts.compactMap(Self.slug(fromToken:))
        guard let best = slugs.max(by: { generationRank($0) < generationRank($1) }) else {
            return (nil, parts.count > 1)
        }
        return (best, Set(slugs).count > 1)
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
    /// `ps5_native_media_app`) gives it (live, 2026-09-20).
    static func slug(fromCategory raw: String?) -> String? {
        guard let s = raw?.lowercased() else { return nil }
        if s.contains("ps5") { return "ps5" }
        if s.contains("ps4") { return "ps4" }
        if s.contains("ps3") { return "ps3" }
        if s.contains("vita") { return "vita" }
        if s.contains("psp") { return "psp" }
        return nil
    }

    /// A category that does not end in `_game` is a media app (Netflix, Plex…) → *Ignored*
    /// with reason "media app" (PLAN §13.3, live 2026-09-20).
    static func categoryIsApp(_ category: String?) -> Bool {
        guard let c = category?.lowercased(), !c.isEmpty else { return false }
        return !c.hasSuffix("_game")
    }

    private static func generationRank(_ slug: String) -> Int {
        switch slug {
        case "ps5": return 9
        case "ps4", "vita": return 8
        case "ps3", "psp": return 7
        case "ps2": return 6
        case "ps1": return 5
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

    /// The IGDB-match title: the display name with ™/®/©/℠ stripped and whitespace collapsed,
    /// case preserved (PLAN §13.3 item 5). Set on the row only when it differs from `name`.
    static func cleanMatchTitle(_ name: String) -> String {
        var s = name
        for symbol in ["™", "®", "©", "℠"] { s = s.replacingOccurrences(of: symbol, with: "") }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        init(name: String) { self.name = name }

        func absorbTrophy(_ t: PSNTrophyTitle, slug: String?, combined: Bool) {
            hasTrophy = true
            npCommunicationId = npCommunicationId ?? t.npCommunicationId
            progress = max(progress ?? 0, t.progress)
            if let last = t.lastUpdatedDateTime, last != .distantPast {
                lastPlayedAt = maxDate(lastPlayedAt, last)
            }
            if let slug { platforms.insert(slug) }
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

            let svc = service?.lowercased()
            let servicePurchased = svc?.contains("purchased") == true

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

            // Noise, in priority order.
            var ignore: ImportIgnoreReason?
            if PSNMapping.categoryIsApp(category) { ignore = .mediaApp }
            if ignore == nil { ignore = PSNMapping.nameNoise(name) }
            if ignore == nil, purchaseSeen, isPreOrder { ignore = .preOrder }
            if ignore == nil, purchaseSeen, !isActive { ignore = .inactiveEntitlement }
            if ignore == nil, vaulted { ignore = .vaultedSubscription }

            let statusPrefill: PlayStatus? = (progress == 100) ? .completed : nil

            let clean = PSNMapping.cleanMatchTitle(name)
            let matchTitle = (clean != name && !clean.isEmpty) ? clean : nil

            let note = PSNMapping.reviewNote(
                owned: owned, played: played, launchedNotPlayed: launchedNotPlayed,
                subscription: subscription, service: svc, purchasePlatforms: purchasePlatforms,
                combinedPlatform: combinedPlatform, crossGen: crossGen)

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
                           subscription: ProductSubscription?, service: String?,
                           purchasePlatforms: Set<String>,
                           combinedPlatform: Bool, crossGen: Bool) -> String? {
        var note: String?
        if let subscription {
            note = subscription.isPSPlus ? "PS Plus" : subscription.rawValue
        } else if played, !owned {
            if service == "ps_plus" {
                note = "played via PS Plus"                                   // item 2, catalogue
            } else if service == "other" {
                note = "probably a disc — not a digital licence"             // item 2, disc
            } else {
                note = "Played — no purchase found"                          // rule 3
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
        } else if combinedPlatform {
            let platformNote = "listed on multiple platforms"
            note = note.map { "\($0) · \(platformNote)" } ?? platformNote
        }
        return note
    }
}
