import AppKit
import Testing
import GRDB
@testable import VGN

/// The grid format badges (PLAN §8, wave 17): the pure ``FormatBadges`` order, the
/// per-format facts the grid SQL denormalises, and the PS Plus asset being in the bundle.
struct FormatBadgesTests {

    // MARK: Pure ordering

    @Test func badgeOrderIsPhysicalDigitalRomPSPlus() {
        let g = GameSummary(id: 1, title: "All", owned: true, hasROM: true,
                            physicalPlatformIDs: ["ps4"], digitalPlatformIDs: ["ps5"],
                            romPlatformIDs: ["ps2"], subscriptionPlatformIDs: ["ps4"])
        #expect(FormatBadges.badges(for: g).map(\.kind) == [.physical, .digital, .rom, .psPlus])
    }

    @Test func subscriptionOnlyShowsOnlyPSPlus() {
        let g = GameSummary(id: 1, title: "Plus", owned: true,
                            ownedOnlyViaSubscription: true, subscriptionPlatformIDs: ["ps5"])
        #expect(FormatBadges.badges(for: g).map(\.kind) == [.psPlus])
    }

    @Test func digitalPlusSubscriptionShowsBoth() {
        let g = GameSummary(id: 1, title: "Both", owned: true,
                            digitalPlatformIDs: ["ps5"], subscriptionPlatformIDs: ["ps4"])
        #expect(FormatBadges.badges(for: g).map(\.kind) == [.digital, .psPlus])
    }

    @Test func notOwnedHasNoBadges() {
        let g = GameSummary(id: 1, title: "Borrowed", played: true, owned: false)
        #expect(FormatBadges.badges(for: g).isEmpty)
    }

    @Test func badgeTooltipNamesFormatAndPlatforms() {
        let digital = FormatBadge(kind: .digital, platformIDs: ["ps5", "pc"])
        #expect(GameCell.badgeTooltip(digital) == "Digital · PS5, PC")
        let plus = FormatBadge(kind: .psPlus, platformIDs: ["ps4"])
        #expect(GameCell.badgeTooltip(plus) == "PS Plus · PS4 — expires with the subscription")
    }

    // MARK: The asset is in the bundle

    @Test func psPlusAssetExists() {
        #expect(NSImage(named: "PSPlusBadge") != nil)
    }

    // MARK: Facts from the grid SQL

    @Test func perFormatFactsComeFromTheGridQuery() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let store = LibraryStore(db)

        // A: physical + ROM on ps2 (several reformat-able copies).
        let a = try await store.addGame(GameDraft(title: "Cart Game", platformIDs: ["ps2"],
                                                  owned: true, played: true, format: .physical)).gameID
        _ = try await store.addCopy(gameID: a, platformID: "ps2", format: .rom)

        // B: real digital on ps5 + a PS Plus claim on ps4.
        let b = try await store.addGame(GameDraft(title: "Digital Game", platformIDs: ["ps5"],
                                                  owned: true, played: true, format: .digital)).gameID
        let bPlus = try await store.addCopy(gameID: b, platformID: "ps4", format: .digital)
        try await markSubscription(store, productID: bPlus)

        // C: subscription-only (PS Plus on ps5).
        let c = try await store.addGame(GameDraft(title: "Plus Only", platformIDs: ["ps5"],
                                                  played: true)).gameID
        let cPlus = try await store.addCopy(gameID: c, platformID: "ps5", format: .digital)
        try await markSubscription(store, productID: cPlus)

        // D: played, not owned.
        _ = try await store.addGame(GameDraft(title: "Borrowed", platformIDs: ["pc"], played: true))

        let games = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        func byTitle(_ t: String) throws -> GameSummary { try #require(games.first { $0.title == t }) }

        let cart = try byTitle("Cart Game")
        #expect(cart.hasPhysical && cart.hasROM && !cart.hasDigital)
        #expect(cart.physicalPlatformIDs == ["ps2"] && cart.romPlatformIDs == ["ps2"])
        #expect(cart.hasSeveralChangeableCopies)         // physical + rom = 2 reformat-able
        #expect(cart.singleCopyFormat == nil)
        #expect(FormatBadges.badges(for: cart).map(\.kind) == [.physical, .rom])

        let digital = try byTitle("Digital Game")
        #expect(digital.hasDigital && digital.hasSubscription && !digital.hasPhysical)
        #expect(digital.digitalPlatformIDs == ["ps5"] && digital.subscriptionPlatformIDs == ["ps4"])
        #expect(digital.singleCopyFormat == .digital)    // the one non-subscription single copy
        #expect(!digital.ownedOnlyViaSubscription)
        #expect(FormatBadges.badges(for: digital).map(\.kind) == [.digital, .psPlus])

        let plus = try byTitle("Plus Only")
        #expect(plus.hasSubscription && !plus.hasPhysical && !plus.hasDigital)
        #expect(plus.ownedOnlyViaSubscription)
        #expect(plus.singleCopyFormat == nil)            // a subscription copy is not reformat-able
        #expect(FormatBadges.badges(for: plus).map(\.kind) == [.psPlus])

        let borrowed = try byTitle("Borrowed")
        #expect(!borrowed.owned)
        #expect(FormatBadges.badges(for: borrowed).isEmpty)
    }

    private func markSubscription(_ store: LibraryStore, productID: Int64) async throws {
        try await store.database.dbWriter.write { db in
            try db.execute(sql: "UPDATE products SET subscription = 'ps_plus' WHERE id = ?",
                           arguments: [productID])
        }
    }
}
