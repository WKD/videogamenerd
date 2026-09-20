import AppKit
import Testing
import GRDB
@testable import VGN

/// The grid format badges (PLAN §8, wave 17): the pure ``FormatBadges`` order, the
/// per-format facts the grid SQL denormalises, and the PS Plus asset being in the bundle.
struct FormatBadgesTests {

    // MARK: Pure ordering

    /// The bottom row is real formats only, in order — physical → digital → ROM. PS Plus
    /// (a licence, not a format) is NOT here; it draws in the top-left corner (wave 19, D5).
    @Test func badgeOrderIsPhysicalDigitalRomAndPSPlusIsSeparate() {
        let g = GameSummary(id: 1, title: "All", owned: true, hasROM: true,
                            physicalPlatformIDs: ["ps4"], digitalPlatformIDs: ["ps5"],
                            romPlatformIDs: ["ps2"], subscriptionPlatformIDs: ["ps4"])
        #expect(FormatBadges.badges(for: g).map(\.kind) == [.physical, .digital, .rom])
        // PS Plus is exposed separately, for the corner.
        #expect(FormatBadges.licensing(for: g)?.kind == .psPlus)
        #expect(FormatBadges.licensing(for: g)?.platformIDs == ["ps4"])
    }

    @Test func subscriptionOnlyShowsNoFormatBadgeButHasLicensing() {
        let g = GameSummary(id: 1, title: "Plus", owned: true,
                            ownedOnlyViaSubscription: true, subscriptionPlatformIDs: ["ps5"])
        #expect(FormatBadges.badges(for: g).isEmpty)               // no format badge (unchanged)
        #expect(FormatBadges.licensing(for: g)?.kind == .psPlus)   // the corner shows PS Plus
    }

    @Test func digitalPlusSubscriptionShowsDigitalPlusCornerLicensing() {
        let g = GameSummary(id: 1, title: "Both", owned: true,
                            digitalPlatformIDs: ["ps5"], subscriptionPlatformIDs: ["ps4"])
        #expect(FormatBadges.badges(for: g).map(\.kind) == [.digital])
        #expect(FormatBadges.licensing(for: g)?.kind == .psPlus)
    }

    @Test func noSubscriptionHasNoLicensingBadge() {
        let g = GameSummary(id: 1, title: "Owned", owned: true, digitalPlatformIDs: ["pc"])
        #expect(FormatBadges.licensing(for: g) == nil)
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

    // MARK: Shared glyph mapping (D3)

    /// The one glyph set the grid, Quick Add and the rest of the app share — and, crucially,
    /// none of them is a *filled circle* (the old white-blob bug: a filled-circle glyph painted
    /// white inside the tinted badge circle is unreadable).
    @Test func sharedGlyphsAreDistinctAndNotFilledCircles() {
        #expect(FormatBadgeKind.physical.symbolName == "opticaldisc")
        #expect(FormatBadgeKind.digital.symbolName == "arrow.down.to.line")
        #expect(FormatBadgeKind.rom.symbolName == "memorychip")
        for kind in [FormatBadgeKind.physical, .digital, .rom] {
            #expect(!kind.symbolName.hasSuffix(".fill"), "\(kind) uses a filled glyph")
        }
        // The digital badge must not be the circled arrow (draws as a dot in a circle).
        #expect(!FormatBadgeKind.digital.symbolName.contains("circle"))
    }

    @Test func sharedGlyphsResolveToRealSFSymbols() {
        for kind in [FormatBadgeKind.physical, .digital, .rom] {
            #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(kind.symbolName)")
        }
    }

    @Test func productFormatMapsToTheBadgeKind() {
        #expect(ProductFormat.physical.badgeKind == .physical)
        #expect(ProductFormat.digital.badgeKind == .digital)
        #expect(ProductFormat.rom.badgeKind == .rom)
    }

    // MARK: Badge-row overflow rule (D5 — now max 4 at the bottom)

    /// The bottom row now holds at most four badges — physical + digital + ROM + played (PS Plus
    /// moved to the corner) — and never draws wider than the tile at any width, 110…230 pt (it
    /// wraps rather than overflow if it ever had to).
    @Test func fourBadgesFitAtEveryTileWidth() {
        for width in stride(from: FormatBadgeLayout.minTile, through: FormatBadgeLayout.maxTile, by: 5) {
            #expect(FormatBadgeLayout.fits(count: 4, cellWidth: width), "4 badges overflow at \(width)")
        }
    }

    /// Badges stay a legible size (never below 18 pt) and grow gently with the tile.
    @Test func badgeDiameterStaysLegibleAndScales() {
        #expect(FormatBadgeLayout.diameter(cellWidth: FormatBadgeLayout.minTile) >= 18)
        #expect(FormatBadgeLayout.diameter(cellWidth: FormatBadgeLayout.maxTile) <= 24)
        #expect(FormatBadgeLayout.diameter(cellWidth: 110) <= FormatBadgeLayout.diameter(cellWidth: 230))
    }

    /// The four bottom badges share one line even at the narrowest tile (no wrap needed once
    /// PS Plus left the row), and of course at the default tile.
    @Test func fourBadgesShareOneLineFromTheNarrowestTile() {
        #expect(FormatBadgeLayout.perLine(cellWidth: FormatBadgeLayout.minTile) >= 4)
        #expect(FormatBadgeLayout.perLine(cellWidth: 150) >= 4)
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
        #expect(FormatBadges.badges(for: digital).map(\.kind) == [.digital])
        #expect(FormatBadges.licensing(for: digital)?.kind == .psPlus)

        let plus = try byTitle("Plus Only")
        #expect(plus.hasSubscription && !plus.hasPhysical && !plus.hasDigital)
        #expect(plus.ownedOnlyViaSubscription)
        #expect(plus.singleCopyFormat == nil)            // a subscription copy is not reformat-able
        #expect(FormatBadges.badges(for: plus).isEmpty)  // PS-Plus-only shows no format badge
        #expect(FormatBadges.licensing(for: plus)?.kind == .psPlus)

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
