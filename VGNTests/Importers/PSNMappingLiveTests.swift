import Foundation
import Testing
@testable import VGN

/// PSN mapping rules learned on the real account (live, 2026-09-20): the single trophy list,
/// the `service`/`category` fields, the name/id join incl. the tricky real title pairs,
/// ™/®/© handling for the IGDB match title, cross-gen twins, and The Vault's 10-minute PS
/// Plus gate (PLAN §13.3 / §16). Pure — synthetic DTOs, fake ids, well-known names only.
@Suite struct PSNMappingLiveTests {

    // MARK: - Builders (synthetic, fake ids)

    private func trophy(_ name: String, platform: String = "PS5", progress: Int = 50,
                        service: String = "trophy2", npwr: String? = nil) -> PSNTrophyTitle {
        PSNTrophyTitle(
            npCommunicationId: npwr ?? "NPWR\(String(format: "%05d", abs(name.hashValue) % 100000))_00",
            trophyTitleName: name, trophyTitlePlatform: platform, npServiceName: service,
            progress: progress, earnedTrophies: nil, lastUpdatedDateTime: nil, hiddenFlag: false)
    }

    private func gameTitle(_ name: String, platform: String = "ps5", concept: String? = nil,
                           service: String? = nil, category: String? = nil,
                           duration: String? = nil, titleId: String? = nil) -> PSNGameListTitle {
        PSNGameListTitle(
            titleId: titleId ?? "CUSA\(String(format: "%05d", abs(name.hashValue) % 100000))_00",
            name: name, localizedName: name,
            category: category ?? "\(platform)_native_game", service: service,
            playCount: nil, firstPlayedDateTime: nil, lastPlayedDateTime: nil,
            playDuration: duration, concept: concept.map { PSNConcept(idRaw: PSNFlexibleID($0)) })
    }

    private func purchase(_ name: String, platform: String = "PS5", membership: String = "NONE",
                          ent: String? = nil, concept: String? = nil, titleId: String? = nil,
                          isActive: Bool = true, isPreOrder: Bool = false) -> PSNPurchasedGame {
        PSNPurchasedGame(
            name: name, platform: platform, membership: membership, isActive: isActive,
            isDownloadable: true, isPreOrder: isPreOrder, entitlementId: ent ?? "ENT-\(name)",
            productId: nil, titleId: titleId, conceptIdRaw: concept.map { PSNFlexibleID($0) },
            image: nil)
    }

    private func rows(_ t: [PSNTrophyTitle] = [], _ g: [PSNGameListTitle] = [],
                      _ p: [PSNPurchasedGame] = []) -> [ImportStagingRow] {
        PSNMapping.stagingRows(trophyTitles: t, gameList: g, purchases: p)
    }

    // MARK: - Flexible concept id (Int in the game list, String in purchases)

    @Test func conceptIdDecodesFromIntOrStringOrNull() throws {
        let g = try PSNJSON.decoder.decode(PSNConcept.self, from: Data(#"{"id": 10090001}"#.utf8))
        #expect(g.id == "10090001")
        let s = try PSNJSON.decoder.decode(PSNConcept.self, from: Data(#"{"id": "10090002"}"#.utf8))
        #expect(s.id == "10090002")
        let n = try PSNJSON.decoder.decode(PSNConcept.self, from: Data(#"{"id": null}"#.utf8))
        #expect(n.id == nil)
    }

    @Test func gameListAndPurchaseJoinOnConceptIdAcrossIntAndString() {
        // Different names, same concept id (Int on the game list, String on the purchase) →
        // one row (the id join beats the name mismatch).
        let out = rows([], [gameTitle("Alpha Working Title", concept: "999", duration: "PT20H")],
                       [purchase("Beta Store Name", concept: "999")])
        #expect(out.count == 1)
        #expect(out[0].signals.contains(.owned))
        #expect(out[0].signals.contains(.played))
    }

    // MARK: - The name join (real title pairs) — never merges a shared prefix

    @Test func nameJoinHandlesTheTrickyRealPairs() {
        // Each pair is the same game across sources; it must collapse to one row.
        let pairs: [(trophy: String, other: String)] = [
            ("ELDEN RING™", "ELDEN RING"),
            ("Uncharted™: Legacy of Thieves Collection", "UNCHARTED: Legacy of Thieves Collection"),
            ("DEATHLOOP", "Deathloop"),
        ]
        for pair in pairs {
            let out = rows([trophy(pair.trophy, progress: 80)], [], [purchase(pair.other)])
            #expect(out.count == 1, "\(pair) should join to one game")
            #expect(out[0].signals.contains(.played))
            #expect(out[0].signals.contains(.owned))
        }
        // Two different games that merely share a prefix must NOT merge.
        let distinct = rows([trophy("God of War", progress: 60)], [],
                            [purchase("God of War Ragnarök")])
        #expect(distinct.count == 2)
    }

    // MARK: - ™ / ® / © → matchTitle (kept off the display name)

    @Test func trademarkSymbolsStrippedForTheMatchTitleOnly() {
        let out = rows([trophy("ELDEN RING™", progress: 90)])
        #expect(out.count == 1)
        #expect(out[0].name == "ELDEN RING™")          // display keeps the symbol
        #expect(out[0].matchTitle == "ELDEN RING")     // IGDB match strips it
    }

    // MARK: - service rules (PLAN §13.3 item 2)

    @Test func serviceNonePurchasedIsOwnedDigitalEvenWithoutAPurchase() {
        let out = rows([], [gameTitle("Digital Buy", service: "none(purchased)", duration: "PT10H")])
        #expect(out.count == 1)
        #expect(out[0].signals.contains(.owned))
        #expect(out[0].subscription == nil)
    }

    @Test func servicePSPlusWithoutEntitlementIsPlayedNotOwned() {
        let out = rows([], [gameTitle("Catalogue Play", service: "ps_plus", duration: "PT20H")])
        #expect(out.count == 1)
        #expect(!out[0].signals.contains(.owned))
        #expect(out[0].signals.contains(.played))
        #expect(out[0].reviewNote == "played via PS Plus")
    }

    @Test func serviceOtherIsPlayedNotOwnedProbablyADisc() {
        let out = rows([], [gameTitle("Disc Play", service: "other", duration: "PT40H")])
        #expect(out.count == 1)
        #expect(!out[0].signals.contains(.owned))
        #expect(out[0].signals.contains(.played))
        #expect(out[0].reviewNote == "probably a disc — not a digital licence")
    }

    // MARK: - category → media apps are ignored (PLAN §13.3 item 3)

    @Test func categoryNotEndingInGameIsAMediaApp() {
        let out = rows([], [
            gameTitle("Some Streamer", category: "ps5_native_media_app", duration: "PT500H"),
            gameTitle("Web Streamer", category: "ps5_web_based_media_app", duration: "PT100H"),
            gameTitle("A Real Game", category: "ps5_native_game", duration: "PT5H"),
        ])
        let byName = Dictionary(out.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["Some Streamer"]?.ignoreReason == .mediaApp)
        #expect(byName["Web Streamer"]?.ignoreReason == .mediaApp)
        #expect(byName["A Real Game"]?.ignoreReason == nil)
        #expect(byName["A Real Game"]?.platform == "ps5")   // platform from the category
    }

    // MARK: - Cross-gen twins (PLAN §13.3 item (a))

    @Test func crossGenPurchaseTwinsBecomeOneGameNewestPlatform() {
        // Same game as a PS4 and a PS5 entitlement, null concept id, different title ids.
        let out = rows([], [], [
            purchase("Cross Gen Quest", platform: "PS4", ent: "ENT-PS4", titleId: "CUSA00001_00"),
            purchase("Cross Gen Quest", platform: "PS5", ent: "ENT-PS5", titleId: "PPSA00001_00"),
        ])
        #expect(out.count == 1)
        #expect(out[0].platform == "ps5")                       // PS5 wins
        #expect(out[0].externalID == "ent:ENT-PS5")            // stable on the PS5 entitlement
        #expect(out[0].reviewNote?.contains("PS4 & PS5 versions") == true)
    }

    @Test func boughtTwinWinsOverThePSPlusTwin() {
        // A PS Plus PS4 claim + a bought PS5 copy of the same game → one owned copy, no flag.
        let out = rows([], [], [
            purchase("Owned Both Ways", platform: "PS4", membership: "PS_PLUS", ent: "ENT-PLUS"),
            purchase("Owned Both Ways", platform: "PS5", membership: "NONE", ent: "ENT-BOUGHT"),
        ])
        #expect(out.count == 1)
        #expect(out[0].signals.contains(.owned))
        #expect(out[0].subscription == nil)                    // bought wins, not a subscription
        #expect(out[0].ignoreReason == nil)                    // never vaulted
        #expect(out[0].reviewNote?.contains("PS4 & PS5 versions") == true)
    }

    @Test func differentEditionsWithDifferentNamesStaySeparate() {
        let out = rows([], [], [
            purchase("Racer", platform: "PS5", ent: "ENT-A"),
            purchase("Racer: Deluxe Championship", platform: "PS5", ent: "ENT-B"),
        ])
        #expect(out.count == 2)
    }

    // MARK: - The Vault's 10-minute PS Plus gate (PLAN §16)

    /// A PS Plus claim played for `seconds` (nil = no game-list entry). Returns its row.
    private func psPlusRow(playedSeconds: Int?) -> ImportStagingRow {
        let name = "Plus Gated"
        var game: [PSNGameListTitle] = []
        if let s = playedSeconds {
            game = [gameTitle(name, concept: "42", service: "ps_plus", duration: "PT\(s)S")]
        }
        let out = rows([], game, [purchase(name, platform: "PS5", membership: "PS_PLUS",
                                            ent: "ENT-G", concept: "42")])
        return out.first { $0.name == name }!
    }

    @Test func psPlusGateVaultsAtOrBelowTenMinutes() {
        // 0 / 599 / 600 → Vault (staged ignored, no copy); 601 → owned-via-subscription.
        for seconds in [nil, 599, 600] as [Int?] {
            let row = psPlusRow(playedSeconds: seconds)
            #expect(row.ignoreReason == .vaultedSubscription, "\(String(describing: seconds)) → Vault")
            #expect(!row.signals.contains(.owned))
            #expect(row.subscription == nil)
        }
        let played = psPlusRow(playedSeconds: 601)
        #expect(played.ignoreReason == nil)
        #expect(played.signals.contains(.owned))
        #expect(played.subscription == .psPlus)                // the "+" badge case
    }

    @Test func boughtNeverPlayedIsNeverVaulted() {
        // A real purchase (membership NONE) with no play time is the backlog, not the Vault.
        let out = rows([], [], [purchase("Unplayed Backlog", membership: "NONE")])
        #expect(out.count == 1)
        #expect(out[0].ignoreReason == nil)
        #expect(out[0].signals.contains(.owned))
        #expect(!out[0].signals.contains(.played))
    }

    // MARK: - Launched vs played (PLAN §13.3 item 6 — Myst, 5 m 22 s)

    @Test func zeroPercentTrophyUnderThirtyMinutesStaysLaunched() {
        // Myst: a 0 % trophy title with 5 m 22 s in the game list is still only "Launched".
        let out = rows([trophy("Myst", progress: 0)],
                       [gameTitle("Myst", service: "other", duration: "PT5M22S")])
        #expect(out.count == 1)
        #expect(out[0].launchedNotPlayed == true)
        #expect(!out[0].signals.contains(.played))
        #expect(out[0].reviewNote == "Launched, 0 %")
    }

    // MARK: - The same npCommunicationId never double-counts (PLAN §13.3 item 1)

    @Test func duplicateTrophyTitleDoesNotDoubleCount() {
        let out = rows([trophy("Doubled", progress: 40, npwr: "NPWR12345_00"),
                        trophy("Doubled", progress: 40, npwr: "NPWR12345_00")])
        #expect(out.count == 1)
    }

    // MARK: - Combined trophy platform strings (PLAN §13.3 item 1)

    @Test func combinedTrophyPlatformStringsMapToTheNewestSlug() {
        #expect(PSNMapping.platformSlug("PS3").slug == "ps3")
        #expect(PSNMapping.platformSlug("PSVITA").slug == "vita")
        #expect(PSNMapping.platformSlug("PS3,PSVITA").slug == "vita")   // newest of the two
        #expect(PSNMapping.platformSlug("PS3,PSVITA").combined == true)
        #expect(PSNMapping.platformSlug("PS4,PS5").slug == "ps5")
    }
}
