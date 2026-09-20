import Foundation
import Testing
@testable import VGN

/// "From the vault" scoring (PLAN §16): the pure ``DiscoverScorer`` now spans both sources.
/// A matched PS Plus JRPG beats a ROM shooter for a JRPG-loving library; a set deadline lifts a
/// finishable PS Plus game; the deadline reason renders; unmatched PS Plus entries never appear.
struct VaultScorerTests {

    private func mkRanked(_ id: Int64, score: Double, traits: [GameTrait]) -> RankedGame {
        RankedGame(id: id, igdbID: nil, score: score, traits: traits)
    }

    private func rom(_ id: Int64, name: String, system: String = "snes",
                     genre: String? = nil, rating: Double? = nil) -> RomCatalogEntry {
        RomCatalogEntry(id: id, source: "batocera", system: system, platformID: system,
                        relativePath: "./\(name).zip", name: name, genre: genre, rating: rating)
    }

    private func psPlus(_ id: Int64, name: String, traits: [GameTrait],
                        lengthMain: Int? = nil, lengthComplete: Int? = nil,
                        igdbRating: Double? = nil, matched: Bool = true) -> RomCatalogEntry {
        var e = RomCatalogEntry.makePSNVault(externalID: "ent:\(id)", platform: "ps5", name: name,
                                             coverURL: nil, membership: "ps_plus")
        e.id = id
        if matched {
            e.matchState = .matched
            e.igdbID = 1000 + id
            e.traitsJSON = RomCatalogEntry.encodeTraits(traits)
            e.lengthMainSeconds = lengthMain
            e.lengthCompleteSeconds = lengthComplete
            e.igdbRating = igdbRating
        }
        return e
    }

    private func jrpgLibrary() -> [RankedGame] {
        var ranked: [RankedGame] = []
        for i in 0..<12 {
            ranked.append(mkRanked(Int64(i + 1), score: 0.9,
                                   traits: [GameTrait(kind: .genre, value: "Role-playing (RPG)")]))
        }
        for i in 0..<12 {
            ranked.append(mkRanked(Int64(i + 100), score: 0.1,
                                   traits: [GameTrait(kind: .genre, value: "Shooter")]))
        }
        return ranked
    }

    @Test func psPlusJRPGBeatsRomShooterForJRPGLibrary() {
        let ranked = jrpgLibrary()
        let jrpg = psPlus(1, name: "Persona", traits: [GameTrait(kind: .genre, value: "Role-playing (RPG)")])
        let shooter = rom(2, name: "Loud Shooter", genre: "Shoot'em Up", rating: 0.98)

        let scored = DiscoverScorer.score(entries: [jrpg, shooter], ranked: ranked,
                                          options: .init(prioritisePSPlus: false))
        #expect(scored.first?.entry.id == jrpg.id)
    }

    @Test func deadlineLiftsFinishablePSPlusGame() {
        let ranked = jrpgLibrary()
        let rpg = GameTrait(kind: .genre, value: "Role-playing (RPG)")
        let short = psPlus(1, name: "Short RPG", traits: [rpg], lengthMain: 20 * 3600)

        // Same entry, no date vs a near deadline: the boost grows.
        let noDate = DiscoverScorer.score(entries: [short], ranked: ranked,
                                          options: .init(prioritisePSPlus: false))
        let dated = DiscoverScorer.score(entries: [short], ranked: ranked,
                                         options: .init(psPlusMonthsLeft: 2, prioritisePSPlus: false))
        #expect(dated.first!.score > noDate.first!.score)
        // The deadline reason renders.
        let hasDeadline = dated.first!.reasons.contains {
            if case .leavesWithSubscriptionDeadline = $0 { return true }
            return false
        }
        #expect(hasDeadline)
    }

    @Test func unmatchedPSPlusNeverAppears() {
        let ranked = jrpgLibrary()
        let unmatched = psPlus(1, name: "Mystery", traits: [], matched: false)
        let scored = DiscoverScorer.score(entries: [unmatched], ranked: ranked)
        #expect(scored.isEmpty)
    }

    @Test func romTimeStaysNeutralPSPlusUsesLength() {
        let ranked = jrpgLibrary()
        let rpg = GameTrait(kind: .genre, value: "Role-playing (RPG)")
        // A quick-session bracket; a 100 h PS Plus game should fit poorly, a ROM (no length) neutral.
        let bracket = TimeBracket(shelf: .evening)
        let longGame = psPlus(1, name: "Epic RPG", traits: [rpg], lengthMain: 100 * 3600)
        let romGame = rom(2, name: "RPG ROM", genre: "Role Playing Game")

        let scored = DiscoverScorer.score(entries: [longGame, romGame], ranked: ranked,
                                          options: .init(bracket: bracket, prioritisePSPlus: false))
        // The ROM's time is neutral; the long PS Plus game takes a time penalty, so the ROM leads.
        #expect(scored.first?.entry.id == romGame.id)
        // The PS Plus game carries a fitsBracket reason (it has a length); the ROM does not.
        let psReasons = scored.first { $0.entry.id == longGame.id }!.reasons
        #expect(psReasons.contains { if case .fitsBracket = $0 { return true }; return false })
    }
}
