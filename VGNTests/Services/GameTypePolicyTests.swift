import Foundation
import Testing
@testable import VGN

/// The pure "what counts as a game" classifier (PLAN §5.1, owner 2026-09-20) and the
/// ``BundleMemberResult`` / ``BundleLeftOut`` value types. Table-driven, Foundation only.
struct GameTypePolicyTests {

    // MARK: isStandaloneGame — the drop/keep table

    @Test func standaloneTable() {
        // Dropped from a bundle's members — not a game on its own.
        let dropped: [IGDBGameType] = [.dlcAddon, .expansion, .mod, .season, .pack, .update]
        for type in dropped {
            #expect(!GameTypePolicy.isStandaloneGame(type), "\(type) should NOT be standalone")
        }
        // Kept — a game in its own right (incl. standalone_expansion, episode, and unknown).
        let kept: [IGDBGameType] = [
            .mainGame, .bundle, .standaloneExpansion, .episode,
            .remake, .remaster, .expandedGame, .port, .fork, .unknown(99),
        ]
        for type in kept {
            #expect(GameTypePolicy.isStandaloneGame(type), "\(type) should be standalone")
        }
    }

    /// Every raw IGDB id maps consistently through the enum and the policy — no id is
    /// accidentally dropped, and the two owner call-outs (standalone_expansion 4, episode 6)
    /// are kept.
    @Test func rawIDsRoundTripAndKeepStandaloneExpansionAndEpisode() {
        for raw in 0...14 {
            let type = IGDBGameType(rawValue: raw)
            #expect(type.rawValue == raw)
        }
        #expect(GameTypePolicy.isStandaloneGame(IGDBGameType(rawValue: 4)))   // standalone_expansion
        #expect(GameTypePolicy.isStandaloneGame(IGDBGameType(rawValue: 6)))   // episode
        #expect(!GameTypePolicy.isStandaloneGame(IGDBGameType(rawValue: 2)))  // expansion
    }

    // MARK: foldsIntoParent — only a port

    @Test func onlyPortFolds() {
        #expect(GameTypePolicy.foldsIntoParent(.port))
        for type: IGDBGameType in [.mainGame, .remake, .remaster, .expandedGame, .fork,
                                   .expansion, .bundle, .episode, .unknown(7)] {
            #expect(!GameTypePolicy.foldsIntoParent(type), "\(type) must not fold")
        }
    }

    // MARK: Human labels

    @Test func humanLabels() {
        #expect(GameTypePolicy.label(for: .expansion, parentName: "Diablo II") == "Expansion of Diablo II")
        #expect(GameTypePolicy.label(for: .dlcAddon, parentName: "Diablo II") == "DLC for Diablo II")
        #expect(GameTypePolicy.label(for: .port, parentName: "Super Mario Galaxy") == "Port of Super Mario Galaxy")
        #expect(GameTypePolicy.label(for: .expansion) == "Expansion")
        #expect(GameTypePolicy.label(for: .port) == "Port")
        #expect(GameTypePolicy.label(for: .mainGame) == nil)
        #expect(GameTypePolicy.label(for: .unknown(42)) == nil)
    }

    @Test func droppedKindLabels() {
        #expect(GameTypePolicy.droppedKindLabel(.expansion) == "expansion")
        #expect(GameTypePolicy.droppedKindLabel(.dlcAddon) == "DLC")
        #expect(GameTypePolicy.droppedKindLabel(.season) == "season")
        #expect(GameTypePolicy.droppedKindLabel(.pack) == "pack")
        #expect(GameTypePolicy.droppedKindLabel(.update) == "update")
    }

    // MARK: BundleLeftOut display + BundleMemberResult

    @Test func leftOutDisplayText() {
        let dropped = BundleLeftOut.dropped("Season of Infamy", kind: "expansion")
        #expect(dropped.displayText == "Season of Infamy — expansion")
        #expect(!dropped.folded)

        let folded = BundleLeftOut.folded("Super Mario Galaxy", to: "→ the 2007 original")
        #expect(folded.displayText == "Super Mario Galaxy → the 2007 original")
        #expect(folded.folded)
    }

    @Test func worthCompilationNeedsTwo() {
        #expect(!BundleMemberResult().isWorthCompilation)
        #expect(!BundleMemberResult(members: [Self.result(1, "One")]).isWorthCompilation)
        #expect(BundleMemberResult(members: [Self.result(1, "One"), Self.result(2, "Two")]).isWorthCompilation)
    }

    private static func result(_ id: Int64, _ name: String) -> IGDBSearchResult {
        IGDBSearchResult(id: id, name: name, releaseYear: nil, coverImageID: nil,
                         platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                         genres: [], alternativeNames: [], gameType: .mainGame)
    }
}
