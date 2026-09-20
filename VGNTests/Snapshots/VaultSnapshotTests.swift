#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// The Vault browser (PLAN §16): the row variants (matched PS Plus with year/genre/rating,
/// unmatched, hand-vaulted Owned, In Library), the populated browser, and the two empty
/// states. Off by default like every snapshot suite; references are added, never re-recorded.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: snapshotSuitesEnabled()))
struct VaultSnapshotTests {
    private let group = "16 Vault"

    private func env(_ store: RomCatalogStore) -> BatoceraEnvironment {
        BatoceraEnvironment(
            catalog: store, thumbnails: BatoceraThumbnailLoader(romsRoot: nil),
            discover: InertDiscoverBackend(), isLive: false, romsRoot: nil,
            addToLibrary: { _ in }, inspectGame: nil, showCatalogue: nil)
    }

    // MARK: Row variants (VaultBrowserRow hosted directly — the store paths don't persist
    // year/genre, so a fully-populated matched row is built by hand).

    @Test func rowVariants() async throws {
        let store = RomCatalogStore(try await BatoceraTestSupport.makeSeededDB())
        let e = env(store)

        var matched = RomCatalogEntry.makePSNVault(externalID: "ent:1", platform: "ps5",
                                                   name: "Bloodborne", coverURL: nil, membership: "ps_plus")
        matched.id = 1; matched.igdbID = 42; matched.matchState = .matched
        matched.releaseYear = 2015; matched.genre = "Action RPG"; matched.igdbRating = 92

        var unmatched = RomCatalogEntry.makePSNVault(externalID: "ent:2", platform: "ps4",
                                                     name: "Some PS Plus Game", coverURL: nil, membership: "ps_plus")
        unmatched.id = 2; unmatched.matchState = nil

        var owned = RomCatalogEntry.makeSentToVault(source: "psn", externalID: "ent:3", platform: "ps5",
                                                    name: "Stray", igdbID: 7, membership: nil, owned: true)
        owned.id = 3; owned.matchState = .matched; owned.releaseYear = 2022; owned.genre = "Adventure"; owned.igdbRating = 84

        var inLib = RomCatalogEntry.makePSNVault(externalID: "ent:4", platform: "ps5",
                                                 name: "Returnal", coverURL: nil, membership: "ps_plus")
        inLib.id = 4; inLib.igdbID = 99; inLib.matchState = .matched; inLib.promotedGameID = 500
        inLib.releaseYear = 2021; inLib.genre = "Roguelike"

        let rows = [matched, unmatched, owned, inLib]
        await SnapshotHarness.capture(group: group, "vault-rows",
                                      size: SnapSize(width: 660, height: 280)) {
            VStack(spacing: 0) {
                ForEach(rows) { entry in
                    VaultBrowserRow(entry: entry, env: e, isSelected: false, onTap: {}, onCommandTap: {},
                                    onAdd: {}, onNotInterested: {}, onFindMatch: {}, onInspect: { _ in })
                    Divider()
                }
            }
            .frame(width: 640)
            .padding()
        }
    }

    // MARK: Populated browser + empty states

    private func seed(_ store: RomCatalogStore) async throws {
        let names = ["Bloodborne", "Returnal", "Stray", "Death Stranding", "Ghost of Tsushima"]
        let entries = names.enumerated().map { i, name in
            RomCatalogEntry.makePSNVault(externalID: "ent:\(i)", platform: i % 2 == 0 ? "ps5" : "ps4",
                                         name: name, coverURL: nil, membership: "ps_plus")
        }
        _ = try await store.syncPSNVault(entries: entries, presentExternalIDs: Set(entries.map(\.externalIDColumn!)))
        if let first = try await store.browse(source: "psn", system: nil, filter: .all, sort: .title,
                                              search: "", limit: 1, offset: 0).first {
            try await store.setVaultMatch(id: first.id, igdbID: 42, traits: [],
                                          lengthMainSeconds: nil, lengthCompleteSeconds: nil, igdbRating: 92)
        }
    }

    @Test func browser() async throws {
        let store = RomCatalogStore(try await BatoceraTestSupport.makeSeededDB())
        try await seed(store)
        let model = RomCatalogueModel(catalog: store, source: .psn)
        model.start()
        await SnapshotHarness.settle(rounds: 8)
        await SnapshotHarness.capture(group: group, "vault-browser") {
            RomCatalogueContent(env: env(store), model: model).frame(width: 820, height: 560)
        }
    }

    @Test func emptyUnconfigured() async throws {
        let store = RomCatalogStore(try await BatoceraTestSupport.makeSeededDB())
        let model = RomCatalogueModel(catalog: store, source: .psn)
        model.start()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "vault-empty-unconfigured",
                                      size: SnapSize(width: 820, height: 480)) {
            RomCatalogueContent(env: env(store), model: model).frame(width: 820, height: 460)
        }
    }

    @Test func emptyFiltered() async throws {
        let store = RomCatalogStore(try await BatoceraTestSupport.makeSeededDB())
        try await seed(store)
        let model = RomCatalogueModel(catalog: store, source: .psn)
        model.start()
        await SnapshotHarness.settle(rounds: 6)
        model.searchText = "zzzzz-no-match"
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "vault-empty-filtered",
                                      size: SnapSize(width: 820, height: 480)) {
            RomCatalogueContent(env: env(store), model: model).frame(width: 820, height: 460)
        }
    }
}
#endif
