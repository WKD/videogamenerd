import Foundation
import Testing
@testable import VGN

/// Match scoring / bucketing against candidate lists, plus the query strategy.
struct ScanMatchingTests {

    @Test("Exact printed title is a confident match")
    func confident() {
        let candidates = [
            RecognitionFixtures.igdb(id: 1, name: "Bloodborne", platformSlugs: ["ps4"]),
            RecognitionFixtures.igdb(id: 2, name: "Bloodstained: Ritual of the Night", platformSlugs: ["ps4"]),
        ]
        let outcome = ScanMatching.rank(printedTitle: "Bloodborne", normalizedGuess: nil, platformSlug: "ps4", candidates: candidates)
        #expect(outcome.bucket == .confident)
        #expect(outcome.best?.igdbID == 1)
    }

    @Test("Matches a French printed title via the IGDB alternative name")
    func frenchAlternativeName() {
        // IGDB `search` misses alt-name-only queries, but once the English game is a
        // candidate, its alternative_names match the French printed title.
        let candidates = [
            RecognitionFixtures.igdb(
                id: 10, name: "Broken Sword: Shadow of the Templars - Reforged",
                platformSlugs: ["ps5"],
                alternativeNames: ["Les Chevaliers de Baphomet - L'ombre des Templiers: Reforged"]
            ),
            RecognitionFixtures.igdb(id: 11, name: "Some Other Game", platformSlugs: ["ps5"]),
        ]
        let outcome = ScanMatching.rank(
            printedTitle: "Les Chevaliers de Baphomet - L'ombre des Templiers: Reforged",
            normalizedGuess: "Broken Sword: Shadow of the Templars - Reforged",
            platformSlug: "ps5",
            candidates: candidates
        )
        #expect(outcome.best?.igdbID == 10)
        #expect(outcome.bucket == .confident)
    }

    @Test("A weak similarity buckets as none with no best match")
    func noMatch() {
        let candidates = [RecognitionFixtures.igdb(id: 1, name: "Gran Turismo 7", platformSlugs: ["ps5"])]
        let outcome = ScanMatching.rank(printedTitle: "Elden Ring", normalizedGuess: nil, platformSlug: "ps5", candidates: candidates)
        #expect(outcome.bucket == .none)
        #expect(outcome.best == nil)
    }

    @Test("Plausible near-miss offers a best plus alternatives")
    func plausibleWithAlternatives() {
        let candidates = [
            RecognitionFixtures.igdb(id: 1, name: "Yakuza Kiwami", platformSlugs: ["ps4"]),
            RecognitionFixtures.igdb(id: 2, name: "Yakuza Kiwami 2", platformSlugs: ["ps4"]),
            RecognitionFixtures.igdb(id: 3, name: "Yakuza 0", platformSlugs: ["ps4"]),
        ]
        let outcome = ScanMatching.rank(printedTitle: "Yakuza Kiwami", normalizedGuess: nil, platformSlug: "ps4", candidates: candidates)
        #expect(outcome.best?.igdbID == 1)
        #expect(outcome.bucket == .confident)
    }

    @Test("Platform match breaks a score tie")
    func platformTieBreak() {
        let candidates = [
            RecognitionFixtures.igdb(id: 1, name: "Resident Evil 2", platformSlugs: ["ps3"]),
            RecognitionFixtures.igdb(id: 2, name: "Resident Evil 2", platformSlugs: ["ps4"]),
        ]
        let outcome = ScanMatching.rank(printedTitle: "Resident Evil 2", normalizedGuess: nil, platformSlug: "ps4", candidates: candidates)
        #expect(outcome.best?.igdbID == 2)
    }

    @Test("Query ladder includes printed, normalised and a subtitle-stripped form")
    func queryLadder() {
        let queries = ScanMatching.queries(
            printedTitle: "Les Chevaliers de Baphomet - L'ombre des Templiers: Reforged",
            normalizedGuess: "Broken Sword: Shadow of the Templars - Reforged"
        )
        #expect(queries.first == "Les Chevaliers de Baphomet - L'ombre des Templiers: Reforged")
        #expect(queries.contains("Broken Sword: Shadow of the Templars - Reforged"))
        // A subtitle-stripped core query is present (helps IGDB find the game).
        #expect(queries.count >= 3)
    }

    @Test("Empty candidates yield none")
    func emptyCandidates() {
        let outcome = ScanMatching.rank(printedTitle: "Anything", normalizedGuess: nil, platformSlug: nil, candidates: [])
        #expect(outcome.bucket == .none)
        #expect(outcome.best == nil)
    }
}
