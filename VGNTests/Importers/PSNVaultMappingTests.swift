import Foundation
import Testing
@testable import VGN

/// Pure PSN → Vault mapping (PLAN §16): a PS Plus claim played at or below the 10-minute gate
/// (including never launched) becomes a Vault entry; a bought copy never is; cross-gen twins are
/// one entry; the gate edges (599/600/601 s) reuse the shared `ImportPolicy` constant; the
/// vault decision matches the staging row's `.vaultedSubscription` reason exactly.
@Suite struct PSNVaultMappingTests {

    private func purchase(_ name: String, platform: String = "PS5", membership: String = "PS_PLUS",
                          cover: String? = nil, ent: String? = nil, concept: String? = nil,
                          titleId: String? = nil) -> PSNPurchasedGame {
        PSNPurchasedGame(
            name: name, platform: platform, membership: membership, isActive: true,
            isDownloadable: true, isPreOrder: false, entitlementId: ent ?? "ENT-\(name)-\(platform)",
            productId: nil, titleId: titleId, conceptIdRaw: concept.map { PSNFlexibleID($0) },
            image: cover.map { PSNPurchasedGame.PSNImage(url: $0) })
    }

    private func gameList(_ name: String, seconds: Int, titleId: String) -> PSNGameListTitle {
        PSNGameListTitle(titleId: titleId, name: name, localizedName: nil, category: "ps5_native_game",
                         service: "ps_plus", playCount: 1, firstPlayedDateTime: nil,
                         lastPlayedDateTime: nil, playDuration: "PT\(seconds)S", concept: nil)
    }

    @Test func neverLaunchedPSPlusClaimGoesToTheVault() {
        let (entries, present) = PSNMapping.vaultEntries(
            trophyTitles: [], gameList: [],
            purchases: [purchase("Bloodborne", cover: "https://x/bb.png")])
        #expect(entries.count == 1)
        let e = entries[0]
        #expect(e.source == "psn")
        #expect(e.system == "ps5")
        #expect(e.membership == "ps_plus")
        #expect(e.coverURL == "https://x/bb.png")
        #expect(e.externalID == e.relativePath)     // external id doubles as relative_path
        #expect(present.contains(e.externalID))
    }

    @Test func boughtCopyIsNeverVaulted() {
        let (entries, _) = PSNMapping.vaultEntries(
            trophyTitles: [], gameList: [], purchases: [purchase("Owned Game", membership: "NONE")])
        #expect(entries.isEmpty)
    }

    @Test func gateEdges599_600_601() {
        func vaulted(_ seconds: Int) -> Bool {
            let (entries, _) = PSNMapping.vaultEntries(
                trophyTitles: [],
                gameList: [gameList("Edge", seconds: seconds, titleId: "CUSA-EDGE")],
                purchases: [purchase("Edge", titleId: "CUSA-EDGE")])
            return !entries.isEmpty
        }
        // The shared constant is 600; ≤ 600 vaults, > 600 does not.
        #expect(ImportPolicy.vaultPlaytimeGateSeconds == 600)
        #expect(vaulted(599))     // below → vault
        #expect(vaulted(600))     // exactly the gate → vault
        #expect(!vaulted(601))    // above → owned-via-subscription, not vaulted
    }

    @Test func crossGenTwinsAreOneEntry() {
        // Same concept id across PS4 + PS5 → one merged Vault entry with a cross-gen note.
        let (entries, _) = PSNMapping.vaultEntries(
            trophyTitles: [], gameList: [],
            purchases: [purchase("Twin", platform: "PS4", concept: "C1"),
                        purchase("Twin", platform: "PS5", concept: "C1")])
        #expect(entries.count == 1)
        #expect(entries[0].system == "ps5")     // newest generation wins
        #expect(entries[0].crossGenNote == "PS4 & PS5 versions")
    }

    @Test func vaultDecisionMatchesStagingIgnoreReason() {
        // The same inputs: a vaulted claim's staging row carries .vaultedSubscription, and it
        // appears in the Vault entries — the two never disagree (PLAN §16).
        let purchases = [purchase("Vaulted One")]
        let rows = PSNMapping.stagingRows(trophyTitles: [], gameList: [], purchases: purchases)
        let (entries, _) = PSNMapping.vaultEntries(trophyTitles: [], gameList: [], purchases: purchases)
        #expect(rows.first?.ignoreReason == .vaultedSubscription)
        #expect(entries.map(\.name) == ["Vaulted One"])
    }

    private func gameListCat(_ name: String, category: String, service: String, seconds: Int,
                             titleId: String) -> PSNGameListTitle {
        PSNGameListTitle(titleId: titleId, name: name, localizedName: nil, category: category,
                         service: service, playCount: 1, firstPlayedDateTime: nil,
                         lastPlayedDateTime: nil, playDuration: "PT\(seconds)S", concept: nil)
    }

    /// `none_purchased` (the PS4-era digital-purchase spelling) has the same Vault semantics as
    /// `none(purchased)`: it never asserts ownership over the PS Plus gate, so a claim under the
    /// gate still vaults (mirroring the staging row), and without any entitlement it is owned
    /// digital and never vaulted.
    @Test func nonePurchasedShareTheVaultSemanticsOfStaging() {
        let g = gameListCat("Underplayed", category: "ps4_game", service: "none_purchased",
                            seconds: 120, titleId: "CUSA-NP")
        let p = [purchase("Underplayed", platform: "PS4", titleId: "CUSA-NP")]
        let rows = PSNMapping.stagingRows(trophyTitles: [], gameList: [g], purchases: p)
        let (entries, _) = PSNMapping.vaultEntries(trophyTitles: [], gameList: [g], purchases: p)
        #expect(rows.first?.ignoreReason == .vaultedSubscription)   // gate wins over the service
        #expect(entries.map(\.name) == ["Underplayed"])
        #expect(entries.first?.system == "ps4")
        // A `none_purchased` entry with no entitlement is owned digital, never vaulted.
        let (none, _) = PSNMapping.vaultEntries(trophyTitles: [], gameList: [g], purchases: [])
        #expect(none.isEmpty)
    }

    /// An `unknown`-category claim is a delisted GAME, not an app: under the gate it still
    /// vaults, platform from the `CUSA…` title-id prefix, with a "category unknown" note — and
    /// the staging row agrees (`.vaultedSubscription`). An **app** category, by contrast, is a
    /// media app in both, so it never reaches the Vault.
    @Test func unknownCategoryVaultsAsAGameButAnAppDoesNot() {
        let g = gameListCat("Delisted", category: "unknown", service: "ps_plus",
                            seconds: 60, titleId: "CUSA-UNK")
        let p = [purchase("Delisted", platform: "PS4", titleId: "CUSA-UNK")]
        let rows = PSNMapping.stagingRows(trophyTitles: [], gameList: [g], purchases: p)
        let (entries, _) = PSNMapping.vaultEntries(trophyTitles: [], gameList: [g], purchases: p)
        #expect(rows.first?.ignoreReason == .vaultedSubscription)
        #expect(entries.count == 1)
        #expect(entries[0].system == "ps4")                        // CUSA prefix
        #expect(entries[0].crossGenNote?.contains("category unknown") == true)

        let app = gameListCat("Streamer", category: "ps4_videoservice_web_app", service: "ps_plus",
                              seconds: 60, titleId: "CUSA-APP")
        let ap = [purchase("Streamer", platform: "PS4", titleId: "CUSA-APP")]
        let appRows = PSNMapping.stagingRows(trophyTitles: [], gameList: [app], purchases: ap)
        let (appEntries, _) = PSNMapping.vaultEntries(trophyTitles: [], gameList: [app], purchases: ap)
        #expect(appRows.first?.ignoreReason == .mediaApp)          // app, not vaulted
        #expect(appEntries.isEmpty)
    }
}
