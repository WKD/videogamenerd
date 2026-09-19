import Foundation

/// Pure PSN DTO → staging-row mapping (PLAN §13.3). Foundation only, no I/O, so every rule
/// is trivially testable: platform strings → VGN slugs, the three lists joined into one row
/// per game, the played/launched/100 % signals, PS Plus, and the noise rules (each with a
/// reason for the review sheet). Never creates a physical copy on its own (PLAN §13.3 —
/// "PSN never creates a physical copy").
enum PSNMapping {

    /// A game-list play time of ≥ 30 min promotes a 0 % trophy title to *played* (PLAN §13.3).
    static let playedPromotionSeconds = 30 * 60

    // MARK: - Entry point

    /// Join the three lists into one staging row per game (PLAN §13.3 — joined on
    /// concept/title id where present, else normalised name + platform). Order is
    /// deterministic (trophy titles first in their input order, then game-list-only, then
    /// purchase-only), so a re-sync produces a stable list.
    static func stagingRows(trophyTitles: [PSNTrophyTitle],
                            gameList: [PSNGameListTitle],
                            purchases: [PSNPurchasedGame]) -> [ImportStagingRow] {
        var merged: [String: Merged] = [:]
        var order: [String] = []

        func entry(forKey key: String, name: String, slug: String?) -> Int {
            if merged[key] == nil {
                merged[key] = Merged(name: name, slug: slug)
                order.append(key)
            }
            return 0
        }

        // 1) Trophy titles — the launch history (the only PS3/Vita source).
        for title in trophyTitles {
            let (slug, combined) = platformSlug(title.trophyTitlePlatform)
            let key = joinKey(name: title.trophyTitleName, slug: slug)
            _ = entry(forKey: key, name: title.trophyTitleName, slug: slug)
            merged[key]?.absorbTrophy(title, slug: slug, combined: combined)
        }

        // 2) Game list — play time / first-last / ids (PS4/PS5).
        for title in gameList {
            let slug = slug(fromCategory: title.category) ?? slug(fromCategory: title.service)
            let key = joinKey(name: title.name, slug: slug)
            _ = entry(forKey: key, name: title.name, slug: slug)
            merged[key]?.absorbGameList(title, slug: slug)
        }

        // 3) Purchases — owned digital + PS Plus.
        for purchase in purchases {
            let (slug, combined) = platformSlug(purchase.platform ?? "")
            let key = joinKey(name: purchase.name, slug: slug)
            _ = entry(forKey: key, name: purchase.name, slug: slug)
            merged[key]?.absorbPurchase(purchase, slug: slug, combined: combined)
        }

        return order.compactMap { merged[$0]?.row() }
    }

    // MARK: - Platform strings (PLAN §13.3)

    /// A VGN platform slug for a trophy/purchase platform string, plus whether it was a
    /// **combined** string (e.g. `"PS4,PS5"`) — the review sheet shows a note then. Pick
    /// rule for a combined string: the **newest** platform (the one the owner most likely
    /// plays on), since VGN models one copy per platform.
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

    /// The game list gives a `category`/`service` like `ps4_game`, `ps5_native_game`.
    private static func slug(fromCategory raw: String?) -> String? {
        guard let s = raw?.lowercased() else { return nil }
        if s.contains("ps5") { return "ps5" }
        if s.contains("ps4") { return "ps4" }
        if s.contains("ps3") { return "ps3" }
        if s.contains("vita") { return "vita" }
        if s.contains("psp") { return "psp" }
        return nil
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

    // MARK: - Join key

    static func joinKey(name: String, slug: String?) -> String {
        TitleNormalizer.normalize(name, level: .canonical) + "|" + (slug ?? "?")
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
        var name: String
        var slug: String?
        var combinedPlatform = false

        var npCommunicationId: String?
        var conceptId: String?
        var titleId: String?
        var entitlementId: String?

        var progress: Int?
        var playDurationS: Int?
        var firstPlayedAt: Date?
        var lastPlayedAt: Date?

        var owned = false
        var membership: String?
        var isPreOrder = false
        var isActive = true

        init(name: String, slug: String?) {
            self.name = name
            self.slug = slug
        }

        func absorbTrophy(_ t: PSNTrophyTitle, slug: String?, combined: Bool) {
            npCommunicationId = npCommunicationId ?? t.npCommunicationId
            progress = max(progress ?? 0, t.progress)
            if let last = t.lastUpdatedDateTime, last != .distantPast {
                lastPlayedAt = maxDate(lastPlayedAt, last)
            }
            if self.slug == nil { self.slug = slug }
            combinedPlatform = combinedPlatform || combined
        }

        func absorbGameList(_ g: PSNGameListTitle, slug: String?) {
            titleId = titleId ?? g.titleId
            if let cid = g.concept?.id { conceptId = conceptId ?? String(cid) }
            if let secs = g.playDurationSeconds { playDurationS = max(playDurationS ?? 0, secs) }
            if let first = g.firstPlayedDateTime, first != .distantPast {
                firstPlayedAt = minDate(firstPlayedAt, first)
            }
            if let last = g.lastPlayedDateTime, last != .distantPast {
                lastPlayedAt = maxDate(lastPlayedAt, last)
            }
            if self.slug == nil { self.slug = slug }
        }

        func absorbPurchase(_ p: PSNPurchasedGame, slug: String?, combined: Bool) {
            owned = true
            entitlementId = entitlementId ?? p.entitlementId
            titleId = titleId ?? p.titleId
            if let cid = p.conceptId { conceptId = conceptId ?? cid }
            membership = membership ?? p.membership
            isPreOrder = isPreOrder || (p.isPreOrder ?? false)
            if p.isActive == false { isActive = false }
            if self.slug == nil { self.slug = slug }
            combinedPlatform = combinedPlatform || combined
        }

        /// The stable external id: concept → title → trophy comm-id → entitlement → name+slug.
        var externalID: String {
            if let c = conceptId { return "concept:\(c)" }
            if let t = titleId { return "title:\(t)" }
            if let n = npCommunicationId { return "npwr:\(n)" }
            if let e = entitlementId { return "ent:\(e)" }
            return "name:\(PSNMapping.joinKey(name: name, slug: slug))"
        }

        /// Turn the merged game into a staging row (PLAN §13.3 rules).
        func row() -> ImportStagingRow {
            let promoted = (playDurationS ?? 0) >= PSNMapping.playedPromotionSeconds
            let played = (progress ?? 0) > 0 || promoted
            let launchedNotPlayed = !played && (progress != nil) && (progress == 0)

            var signals: ImportSignals = []
            if played { signals.insert(.played) }
            if owned { signals.insert(.owned) }

            // PS Plus / raw membership → subscription flag on the owned copy.
            let subscription: ProductSubscription? = owned
                ? ProductSubscription(storage: membership).flatMap { $0.isReallyOwnedMembership ? nil : $0 }
                : nil

            // Noise: name-based first, then purchase-only markers.
            var ignore = PSNMapping.nameNoise(name)
            if ignore == nil, owned, isPreOrder { ignore = .preOrder }
            if ignore == nil, owned, !isActive { ignore = .inactiveEntitlement }

            // Status pre-fill: a 100 % trophy title is completed (PLAN §13.3).
            let statusPrefill: PlayStatus? = (progress == 100) ? .completed : nil

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
                subscription: subscription,
                launchedNotPlayed: launchedNotPlayed,
                reviewNote: PSNMapping.reviewNote(owned: owned, played: played,
                                                  launchedNotPlayed: launchedNotPlayed,
                                                  subscription: subscription,
                                                  combinedPlatform: combinedPlatform),
                statusPrefill: statusPrefill)
        }

        private func maxDate(_ a: Date?, _ b: Date) -> Date { a.map { max($0, b) } ?? b }
        private func minDate(_ a: Date?, _ b: Date) -> Date { a.map { min($0, b) } ?? b }
    }

    // MARK: - Review note (copy-format rules 1–4, PLAN §13.3)

    static func reviewNote(owned: Bool, played: Bool, launchedNotPlayed: Bool,
                           subscription: ProductSubscription?, combinedPlatform: Bool) -> String? {
        var note: String?
        if let subscription {
            note = subscription.isPSPlus ? "PS Plus" : subscription.rawValue
        } else if launchedNotPlayed {
            note = "Launched, 0 %"
        } else if played && !owned {
            note = "Played — no purchase found"   // rule 3
        }
        if combinedPlatform {
            let platformNote = "listed on multiple platforms"
            note = note.map { "\($0) · \(platformNote)" } ?? platformNote
        }
        return note
    }
}

private extension ProductSubscription {
    /// `NONE` (or an empty membership) means the copy is really owned, not on a subscription.
    var isReallyOwnedMembership: Bool {
        rawValue.compare("none", options: .caseInsensitive) == .orderedSame
    }
}
