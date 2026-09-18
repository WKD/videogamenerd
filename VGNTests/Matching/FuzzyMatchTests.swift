import Testing
@testable import VGN

struct FuzzyMatchTests {

    @Test("Exact-after-normalisation pairs score 1.0 (confident)")
    func exactPairs() {
        let pairs = [
            ("Final Fantasy VII", "Final Fantasy 7"),
            ("Ratchet & Clank", "Ratchet and Clank"),
            ("NieR:Automata", "NieR Automata"),
            ("Pokémon", "Pokemon"),
            ("Ōkami", "Okami"),
        ]
        for (a, b) in pairs {
            #expect(FuzzyMatch.score(a, b) == 1.0, "\(a) vs \(b)")
            #expect(FuzzyMatch.classify(FuzzyMatch.score(a, b)) == .confident)
        }
    }

    @Test("Region/edition-tagged variants match the base title confidently")
    func taggedVariants() {
        #expect(FuzzyMatch.classify(FuzzyMatch.score(
            "The Legend of Zelda: Ocarina of Time",
            "Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De)")) == .confident)
        #expect(FuzzyMatch.classify(FuzzyMatch.score(
            "Uncharted 2: Among Thieves - Game of the Year Edition",
            "Uncharted 2: Among Thieves")) == .confident)
    }

    @Test("Remaster is NOT a confident match at the default level")
    func remasterNotConfident() {
        let s = FuzzyMatch.score("The Last of Us", "The Last of Us Remastered")
        #expect(FuzzyMatch.classify(s) != .confident, "score was \(s)")
        #expect(s < FuzzyMatch.confidentThreshold)
    }

    @Test("Numbered sequels are distinguished (not confident)")
    func sequels() {
        #expect(FuzzyMatch.classify(FuzzyMatch.score("Final Fantasy X", "Final Fantasy X-2")) != .confident)
        #expect(FuzzyMatch.classify(FuzzyMatch.score("Mega Man X", "Mega Man 10")) != .confident)
        #expect(FuzzyMatch.classify(FuzzyMatch.score("Final Fantasy X", "Final Fantasy XII")) != .confident)
    }

    @Test("Alternative names rescue a French spine title")
    func alternativeNames() {
        // "Les Chevaliers de Baphomet" only matches "Broken Sword" via an alt name.
        let candidates: [(id: Int64, names: [String])] = [
            (1, ["Broken Sword: The Shadow of the Templars", "Les Chevaliers de Baphomet"]),
            (2, ["Broken Sword II", "Les Chevaliers de Baphomet 2"]),
        ]
        let ranked = FuzzyMatch.bestMatch(query: "Les Chevaliers de Baphomet", candidates: candidates)
        #expect(ranked.first?.id == 1)
        #expect(ranked.first?.confidence == .confident)
    }

    @Test("bestMatch ranks by score, best first")
    func ranking() {
        let candidates: [(id: Int64, names: [String])] = [
            (1, ["Grand Theft Auto V"]),
            (2, ["Grand Theft Auto IV"]),
            (3, ["Red Dead Redemption 2"]),
        ]
        let ranked = FuzzyMatch.bestMatch(query: "GTA 5", candidates: candidates)
        // "GTA 5" is not close to any full name, but V→5 helps GTA V most.
        #expect(ranked.first?.id == 1 || ranked.first?.id == 2)
        #expect(ranked.last?.id == 3)
    }

    @Test("Levenshtein distance is correct")
    func levenshtein() {
        #expect(FuzzyMatch.levenshtein("kitten", "sitting") == 3)
        #expect(FuzzyMatch.levenshtein("", "abc") == 3)
        #expect(FuzzyMatch.levenshtein("abc", "abc") == 0)
        #expect(FuzzyMatch.levenshtein("flaw", "lawn") == 2)
    }

    @Test("Jaro-Winkler behaves at the extremes")
    func jaroWinkler() {
        #expect(FuzzyMatch.jaroWinkler("abc", "abc") == 1.0)
        #expect(FuzzyMatch.jaroWinkler("", "") == 1.0)
        #expect(FuzzyMatch.jaroWinkler("abc", "") == 0.0)
        #expect(FuzzyMatch.jaroWinkler("MARTHA", "MARHTA".lowercased().uppercased()) > 0.9)
    }

    @Test("Self-similarity is 1 and empty vs non-empty is 0")
    func edges() {
        #expect(FuzzyMatch.score("Bloodborne", "Bloodborne") == 1.0)
        #expect(FuzzyMatch.levenshteinRatio("", "") == 1.0)
        #expect(FuzzyMatch.levenshteinRatio("abc", "") == 0.0)
    }

    @Test("Titles that normalise to empty are never a fuzzy match (no bogus dedupe)")
    func emptyNormalizedTitlesDoNotMatch() {
        // Both inputs collapse to "" after tag/punctuation folding: no signal,
        // so they must NOT read as a confident duplicate.
        #expect(FuzzyMatch.score("(USA)", "[Europe]") == 0.0)
        #expect(FuzzyMatch.classify(FuzzyMatch.score("(USA)", "(Japan)")) == .none)
        // A real title vs. an empty one is likewise not a match.
        #expect(FuzzyMatch.classify(FuzzyMatch.score("Bloodborne", "(USA)")) == .none)
        // A genuine identical pair is still a confident match.
        #expect(FuzzyMatch.classify(FuzzyMatch.score("Halo", "Halo")) == .confident)
    }

    @Test("Jaro-Winkler scores identical single characters as 1 (no window underflow)")
    func jaroWinklerSingleChar() {
        #expect(FuzzyMatch.jaroWinkler("a", "a") == 1.0)
        #expect(FuzzyMatch.jaroWinkler("a", "b") == 0.0)
    }
}
