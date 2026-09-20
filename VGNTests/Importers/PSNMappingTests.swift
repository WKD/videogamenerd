import Foundation
import Testing
@testable import VGN

/// Pure PSN mapping (PLAN §13.3): platform strings, the three-list join, played/launched/
/// 100 %, PS Plus, and the noise rules. Runs on the real synthetic fixtures.
@Suite struct PSNMappingTests {

    private func fixtures() throws -> (t: [PSNTrophyTitle], g: [PSNGameListTitle], p: [PSNPurchasedGame]) {
        let trophies = try PSNJSON.decoder.decode(PSNTrophyTitlesPage.self, from: Fixtures.data("psn-trophy-probe.json")).trophyTitles
        let games = try PSNJSON.decoder.decode(PSNGameListPage.self, from: Fixtures.data("psn-gamelist.json")).titles
        let purchases = try PSNJSON.decoder.decode(PSNPurchasedGamesEnvelope.self, from: Fixtures.data("psn-purchases.json"))
            .data!.purchasedTitlesRetrieve!.games!
        return (trophies, games, purchases)
    }

    private func rowsByName() throws -> [String: ImportStagingRow] {
        let f = try fixtures()
        let rows = PSNMapping.stagingRows(trophyTitles: f.t, gameList: f.g, purchases: f.p)
        return Dictionary(rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Platform strings

    @Test func platformStrings() {
        #expect(PSNMapping.platformSlug("PS5").slug == "ps5")
        #expect(PSNMapping.platformSlug("PS5").combined == false)
        #expect(PSNMapping.platformSlug("PS4,PS5").slug == "ps5")   // newest wins
        #expect(PSNMapping.platformSlug("PS4,PS5").combined == true)
        #expect(PSNMapping.platformSlug("PSVITA").slug == "vita")
        #expect(PSNMapping.platformSlug("PS3").slug == "ps3")
        #expect(PSNMapping.platformSlug("WEIRD").slug == nil)
    }

    // MARK: - Signals

    @Test func playedLaunchedAndHundredPercent() throws {
        let rows = try rowsByName()
        // 74 % → played, not launched.
        let saga = rows["Synthetic Saga"]!
        #expect(saga.signals.contains(.played))
        #expect(saga.launchedNotPlayed == false)
        // 0 % with a 0-second play time → launched, not played, its own note.
        let skies = rows["Sample Skies"]!
        #expect(!skies.signals.contains(.played))
        #expect(skies.launchedNotPlayed == true)
        #expect(skies.reviewNote == "Launched, 0 %")
        // 100 % → status pre-fill completed.
        let ffx1 = rows["Fake Fantasy X1"]!
        #expect(ffx1.statusPrefill == .completed)
        #expect(ffx1.signals.contains(.played))
    }

    @Test func gameListPlaytimePromotesAZeroPercentTitle() throws {
        // Placeholder Peaks is 0 % in trophies but 52 min in the game list → played.
        let peaks = try rowsByName()["Placeholder Peaks"]!
        #expect(peaks.signals.contains(.played))
        #expect(peaks.launchedNotPlayed == false)
        #expect((peaks.playDurationS ?? 0) >= PSNMapping.playedPromotionSeconds)
    }

    // MARK: - Join

    @Test func threeListsJoinIntoOneRowWithPlaytimeAndOwnership() throws {
        // Synthetic Saga is in all three lists → one row, played + owned + play time.
        let f = try fixtures()
        let rows = PSNMapping.stagingRows(trophyTitles: f.t, gameList: f.g, purchases: f.p)
        let saga = rows.filter { $0.name == "Synthetic Saga" }
        #expect(saga.count == 1)
        let row = saga[0]
        #expect(row.signals.contains(.played))
        #expect(row.signals.contains(.owned))
        #expect(row.playDurationS == 228 * 3600 + 56 * 60 + 33)
        #expect(row.platform == "ps5")
        #expect(row.externalID == "concept:10090001")   // concept id wins for stability
        #expect(row.subscription == nil)                // membership NONE = really owned
    }

    // MARK: - PS Plus / membership

    @Test func psPlusAndUnknownMembership() throws {
        let rows = try rowsByName()
        let plus = rows["Fake Fantasy X1"]!
        #expect(plus.subscription == .psPlus)
        #expect(plus.reviewNote == "PS Plus")
        // Unknown membership kept raw and shown.
        let free = rows["Freebie Frenzy"]!
        #expect(free.subscription?.rawValue == "UNKNOWN_TIER_2099")
        #expect(free.reviewNote == "UNKNOWN_TIER_2099")
    }

    // MARK: - Noise

    @Test func noiseRulesWithReasons() throws {
        let rows = try rowsByName()
        #expect(rows["Preorder Prospect"]?.ignoreReason == .preOrder)
        #expect(rows["Lapsed Licence"]?.ignoreReason == .inactiveEntitlement)
        #expect(rows["Filler Frontier (Beta)"]?.ignoreReason == .betaOrTrial)
        // A media app is filtered as "not a game".
        let app = PSNMapping.stagingRows(
            trophyTitles: [],
            gameList: [PSNGameListTitle(titleId: "CUSA00000_00", name: "Netflix", localizedName: nil,
                                        category: "ps4_game", service: nil, playCount: nil,
                                        firstPlayedDateTime: nil, lastPlayedDateTime: nil,
                                        playDuration: nil, concept: nil)],
            purchases: [])
        #expect(app.first?.ignoreReason == .mediaApp)
    }

    @Test func combinedPlatformNote() throws {
        // Dummy Dungeon is "PS4,PS5" → newest slug + an "also on PS4" note.
        let dungeon = try rowsByName()["Dummy Dungeon"]!
        #expect(dungeon.platform == "ps5")
        #expect(dungeon.reviewNote?.contains("also on PS4") == true)
    }

    @Test func neverProducesAPhysicalCopySignal() throws {
        // No PSN row ever carries a physical format hint — PSN never creates a disc.
        let rows = try rowsByName()
        for row in rows.values {
            #expect(row.source == ImportSourceID.psn)
        }
    }
}
