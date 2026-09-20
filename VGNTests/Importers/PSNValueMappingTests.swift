import Foundation
import Testing
@testable import VGN

/// The `service` / `category` / combined-platform values learned from the **first real full
/// fetch** (231 game-list titles, 581 purchase entitlements, live 2026-09-20): the fourth
/// `service` spelling `none_purchased`, the `unknown` / `not_found` categories that are
/// delisted **games** (not apps), the extra media-app categories, the platform fallback to the
/// title-id prefix, and the order-independent combined-platform pick (PLAN §13.3 / §16). Pure —
/// synthetic DTOs, fake ids, well-known names only.
@Suite struct PSNValueMappingTests {

    // MARK: - Builders (synthetic, fake ids)

    private func trophy(_ name: String, platform: String = "PS5", progress: Int = 50) -> PSNTrophyTitle {
        PSNTrophyTitle(
            npCommunicationId: "NPWR\(String(format: "%05d", abs(name.hashValue) % 100000))_00",
            trophyTitleName: name, trophyTitlePlatform: platform, npServiceName: "trophy2",
            progress: progress, earnedTrophies: nil, lastUpdatedDateTime: nil, hiddenFlag: false)
    }

    private func gameTitle(_ name: String, category: String?, service: String?,
                           duration: String? = nil, titleId: String = "CUSA90000_00") -> PSNGameListTitle {
        PSNGameListTitle(
            titleId: titleId, name: name, localizedName: name, category: category, service: service,
            playCount: nil, firstPlayedDateTime: nil, lastPlayedDateTime: nil,
            playDuration: duration, concept: nil)
    }

    private func purchase(_ name: String, platform: String = "PS4", membership: String = "NONE",
                          titleId: String = "CUSA90000_00", isActive: Bool = true,
                          isPreOrder: Bool = false) -> PSNPurchasedGame {
        PSNPurchasedGame(
            name: name, platform: platform, membership: membership, isActive: isActive,
            isDownloadable: true, isPreOrder: isPreOrder, entitlementId: "ENT-\(name)",
            productId: nil, titleId: titleId, conceptIdRaw: nil, image: nil)
    }

    private func rows(_ t: [PSNTrophyTitle] = [], _ g: [PSNGameListTitle] = [],
                      _ p: [PSNPurchasedGame] = []) -> [ImportStagingRow] {
        PSNMapping.stagingRows(trophyTitles: t, gameList: g, purchases: p)
    }

    // MARK: - `service` — the four real spellings + tolerance (live 2026-09-20)

    @Test func serviceClassificationIsTolerant() {
        let cases: [(String?, PSNMapping.ServiceAccess?)] = [
            ("none(purchased)", .purchased),      // 100 titles
            ("none_purchased", .purchased),       // 67 titles — the PS4-era underscore spelling
            ("None (Purchased)", .purchased),     // case / spacing tolerance
            ("none-purchased", .purchased),       // hyphen tolerance
            ("NONE_PURCHASED", .purchased),
            ("ps_plus", .psPlus),                 // 27 titles
            ("PS_PLUS", .psPlus),
            ("ps plus", .psPlus),
            ("other", .other),                    // 37 titles
            ("OTHER", .other),
            (nil, nil),
            ("", nil),
            ("   ", nil),
            ("some_new_value", .unknown("some_new_value")),   // kept raw and shown
        ]
        for (raw, expected) in cases {
            #expect(PSNMapping.classifyService(raw) == expected, "service \(raw ?? "nil")")
        }
    }

    /// The two purchase spellings mean the same thing: a game-list `service` of either
    /// `none(purchased)` or `none_purchased`, with no entitlement in the purchases list, is
    /// still owned digital (PLAN §13.3 item 1).
    @Test func bothPurchaseSpellingsAreOwnedDigitalWithoutAnEntitlement() {
        for spelling in ["none(purchased)", "none_purchased"] {
            let out = rows([], [gameTitle("Digital \(spelling)", category: "ps4_game",
                                          service: spelling, duration: "PT10H")])
            #expect(out.count == 1)
            #expect(out[0].signals.contains(.owned), "\(spelling) → owned digital")
            #expect(out[0].subscription == nil)
            #expect(out[0].ignoreReason == nil)
        }
    }

    @Test func servicePsPlusAndOtherStayPlayedNotOwned() {
        // `ps_plus`, played, no entitlement → played, not owned, catalogue note.
        let plus = rows([trophy("Catalogue Climb", progress: 40)],
                        [gameTitle("Catalogue Climb", category: "ps4_game", service: "ps_plus",
                                   duration: "PT10H")])[0]
        #expect(plus.signals.contains(.played))
        #expect(!plus.signals.contains(.owned))
        #expect(plus.reviewNote == "played via PS Plus")
        // `other` → the owner's disc games: played, not owned, disc note.
        let disc = rows([trophy("Disc Domain", progress: 40)],
                        [gameTitle("Disc Domain", category: "ps4_game", service: "other",
                                   duration: "PT10H")])[0]
        #expect(disc.signals.contains(.played))
        #expect(!disc.signals.contains(.owned))
        #expect(disc.reviewNote == "probably a disc — not a digital licence")
    }

    // MARK: - `category` — apps vs delisted games vs future values (live 2026-09-20)

    @Test func categoryClassification() {
        let games = ["ps4_game", "ps5_native_game", "PS4_GAME", "ps6_future_game"]
        for c in games { #expect(PSNMapping.classifyCategory(c) == .game, "\(c)") }

        let apps = ["ps5_native_media_app", "ps5_web_based_media_app",
                    "ps4_videoservice_web_app", "ps4_nongame_mini_app"]
        for c in apps { #expect(PSNMapping.classifyCategory(c) == .app, "\(c)") }

        // `unknown` / `not_found` are NOT apps — they are delisted/old games.
        #expect(PSNMapping.classifyCategory("unknown") == .unknownCategory)
        #expect(PSNMapping.classifyCategory("not_found") == .unknownCategory)
        // A future non-game, non-app value is kept as a game with the "category unknown" note.
        #expect(PSNMapping.classifyCategory("ps6_mystery_widget") == .unknownCategory)
        // Absent category (a trophy/purchase-only title) is a plain game.
        #expect(PSNMapping.classifyCategory(nil) == .game)
        #expect(PSNMapping.classifyCategory("") == .game)
    }

    @Test func mediaAppCategoriesAreIgnored() {
        let apps = ["ps5_native_media_app", "ps5_web_based_media_app",
                    "ps4_videoservice_web_app", "ps4_nongame_mini_app"]
        for c in apps {
            let out = rows([], [gameTitle("Streamer \(c)", category: c, service: "none(purchased)",
                                          duration: "PT500H")])
            #expect(out.count == 1)
            #expect(out[0].ignoreReason == .mediaApp, "\(c) → media app")
        }
    }

    /// `unknown` / `not_found` titles: kept as games (never dropped, never apps), platform from
    /// the `CUSA…` title id (→ ps4), with a "category unknown" review note. These are the real
    /// delisted titles (Resident Evil Director's Cut, Game of Thrones, …).
    @Test func unknownAndNotFoundStayGamesWithAReviewNote() {
        for category in ["unknown", "not_found"] {
            let out = rows([], [gameTitle("Delisted \(category)", category: category,
                                          service: "none_purchased", duration: "PT10H",
                                          titleId: "CUSA12345_00")])
            #expect(out.count == 1)
            let row = out[0]
            #expect(row.ignoreReason == nil, "\(category) is a game, not ignored")
            #expect(row.signals.contains(.owned))               // none_purchased ⇒ owned digital
            #expect(row.platform == "ps4")                      // CUSA prefix
            #expect(row.reviewNote?.contains("category unknown") == true)
        }
    }

    // MARK: - Platform from the title-id prefix (live 2026-09-20 — only CUSA / PPSA seen)

    @Test func platformFromTitleIdPrefix() {
        #expect(PSNMapping.slug(fromTitleId: "PPSA90001_00") == "ps5")
        #expect(PSNMapping.slug(fromTitleId: "CUSA90001_00") == "ps4")
        #expect(PSNMapping.slug(fromTitleId: "PCSA00001_00") == "vita")
        #expect(PSNMapping.slug(fromTitleId: "XXXX00000_00") == nil)   // owner picks
        #expect(PSNMapping.slug(fromTitleId: nil) == nil)
        #expect(PSNMapping.slug(fromTitleId: "PPS") == nil)
    }

    /// When neither the category nor the title-id prefix determines the platform, the row is
    /// left with no platform for the owner to pick in the review sheet.
    @Test func undeterminablePlatformIsLeftForTheOwner() {
        let out = rows([], [gameTitle("Mystery Machine", category: "unknown",
                                      service: "none_purchased", duration: "PT10H",
                                      titleId: "ZZZZ00000_00")])
        #expect(out[0].platform == nil)
        #expect(out[0].reviewNote?.contains("category unknown") == true)
    }

    // MARK: - Combined trophy platforms — order-independent (live 2026-09-20)

    @Test func combinedPlatformPickIsOrderIndependent() {
        // The two real combined strings arrive oldest-first; PS4 wins either way.
        for raw in ["PSVITA,PS4", "PS4,PSVITA"] {
            #expect(PSNMapping.platformSlug(raw).slug == "ps4", "\(raw)")
            #expect(PSNMapping.platformSlug(raw).combined == true, "\(raw)")
        }
        for raw in ["PS3,PSVITA,PS4", "PS4,PSVITA,PS3", "PSVITA,PS3,PS4"] {
            #expect(PSNMapping.platformSlug(raw).slug == "ps4", "\(raw)")
            #expect(PSNMapping.platformSlug(raw).combined == true, "\(raw)")
        }
    }

    @Test func combinedTrophyStringAddsAnAlsoOnNote() {
        // "PSVITA,PS4" → ps4, note "also on VITA".
        let a = rows([trophy("Portable Port", platform: "PSVITA,PS4", progress: 40)])[0]
        #expect(a.platform == "ps4")
        #expect(a.reviewNote?.contains("also on VITA") == true)
        // "PS3,PSVITA,PS4" → ps4, note lists both other platforms.
        let b = rows([trophy("Triple Threat", platform: "PS3,PSVITA,PS4", progress: 40)])[0]
        #expect(b.platform == "ps4")
        #expect(b.reviewNote?.contains("also on") == true)
        #expect(b.reviewNote?.contains("VITA") == true)
        #expect(b.reviewNote?.contains("PS3") == true)
    }

    // MARK: - Combination rules with purchases (PLAN §13.3 / §16)

    /// An `unknown`-category title with a `PS_PLUS` entitlement played **> 600 s** is an owned-
    /// via-subscription game (the "+" badge), not vaulted, and keeps its "category unknown" note.
    @Test func unknownCategoryWithPSPlusOverGateIsOwnedViaSubscription() {
        let out = rows(
            [trophy("Subbed Saga", platform: "PS4", progress: 20)],
            [gameTitle("Subbed Saga", category: "unknown", service: "ps_plus",
                       duration: "PT2H", titleId: "CUSA55555_00")],
            [purchase("Subbed Saga", platform: "PS4", membership: "PS_PLUS", titleId: "CUSA55555_00")])
        #expect(out.count == 1)
        let row = out[0]
        #expect(row.signals.contains(.owned))
        #expect(row.subscription == .psPlus)
        #expect(row.ignoreReason == nil)                     // not vaulted (> 600 s), not an app
        #expect(row.reviewNote?.contains("PS Plus") == true)
        #expect(row.reviewNote?.contains("category unknown") == true)
    }

    /// A `PS_PLUS` entitlement played **≤ 600 s** goes to the Vault regardless of category.
    @Test func psPlusUnderTheGateIsVaulted() {
        let out = rows(
            [],
            [gameTitle("Vault Visitor", category: "ps4_game", service: "ps_plus",
                       duration: "PT5M", titleId: "CUSA66666_00")],
            [purchase("Vault Visitor", platform: "PS4", membership: "PS_PLUS", titleId: "CUSA66666_00")])
        #expect(out[0].ignoreReason == .vaultedSubscription)
        #expect(!out[0].signals.contains(.owned))
    }
}
