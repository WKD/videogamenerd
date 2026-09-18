import Foundation
import Testing
import GRDB
@testable import VGN

/// `sort_title` via `TitleNormalizer` (Deliverable 2) and FTS search depth
/// (Deliverable 3).
@Suite struct SortTitleAndFTSTests {

    // MARK: - sort_title shape

    @Test func stripsEnglishAndFrenchLeadingArticles() async throws {
        #expect(SortTitle.make(from: "The Last of Us") == "last of us")
        #expect(SortTitle.make(from: "A Plague Tale") == "plague tale")
        #expect(SortTitle.make(from: "Les Chevaliers de Baphomet").hasPrefix("chevaliers"))
        #expect(SortTitle.make(from: "Le Dernier").hasPrefix("dernier"))
        // The "Zelda, The" comma form folds too.
        #expect(SortTitle.make(from: "Legend of Zelda, The").hasPrefix("legend of zelda"))
    }

    @Test func numeralsNormalisedNotCollapsed() async throws {
        // Roman numerals become arabic (natural order) but stay DISTINCT.
        let vii = SortTitle.make(from: "Final Fantasy VII")
        let viii = SortTitle.make(from: "Final Fantasy VIII")
        #expect(vii != viii)
        #expect(vii < viii)
        #expect(vii.contains("7"))
        #expect(viii.contains("8"))
    }

    @Test func naturalNumericOrdering() async throws {
        // Zero-padding gives "2" < "10" (not lexical "10" < "2").
        let ff1 = SortTitle.make(from: "Final Fantasy 1")
        let ff2 = SortTitle.make(from: "Final Fantasy 2")
        let ff10 = SortTitle.make(from: "Final Fantasy 10")
        #expect(ff1 < ff2)
        #expect(ff2 < ff10)
    }

    @Test func editionWordsNotStripped() async throws {
        // A remaster/edition denotes a separate game (PLAN §4) — keep the word so
        // the sort key stays distinct and recognisable.
        #expect(SortTitle.make(from: "Halo: Combat Evolved Anniversary").contains("anniversary"))
        #expect(SortTitle.make(from: "The Last of Us Part II").contains("2"))
    }

    @Test func gridSortByTitleIsNaturalAndArticleless() async throws {
        let store = try await TestDB.makeStore()
        for t in ["Final Fantasy 10", "Final Fantasy 2", "The Adventure", "Final Fantasy 1"] {
            _ = try await store.addGame(GameDraft(title: t, platformIDs: ["pc"], owned: true))
        }
        let ordered = try await store.gamesOnce(filter: LibraryFilter(sort: .title, ascending: true))
        #expect(ordered.map(\.title) == ["The Adventure", "Final Fantasy 1", "Final Fantasy 2", "Final Fantasy 10"])
    }

    // MARK: - FTS: diacritics-insensitive (v2 remove_diacritics 2)

    @Test func searchIgnoresDiacritics() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "Pokémon Red", platformIDs: ["snes"], owned: true))
        _ = try await store.addGame(GameDraft(title: "Ōkami", platformIDs: ["ps2"], owned: true))
        func titles(_ q: String) async throws -> Set<String> {
            Set(try await store.gamesOnce(filter: LibraryFilter(searchText: q)).map(\.title))
        }
        #expect(try await titles("pokemon") == ["Pokémon Red"])
        #expect(try await titles("pokémon") == ["Pokémon Red"])
        #expect(try await titles("okami") == ["Ōkami"])
    }

    // MARK: - FTS: multi-token prefix

    @Test func multiTokenPrefixSearch() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "Metal Gear Solid", platformIDs: ["ps2"], owned: true))
        _ = try await store.addGame(GameDraft(title: "Gran Turismo", platformIDs: ["ps2"], owned: true))
        func titles(_ q: String) async throws -> Set<String> {
            Set(try await store.gamesOnce(filter: LibraryFilter(searchText: q)).map(\.title))
        }
        #expect(try await titles("met gear sol") == ["Metal Gear Solid"])
        #expect(try await titles("gran tur") == ["Gran Turismo"])
    }

    // MARK: - FTS: punctuation can never cause a syntax error

    @Test func punctuationIsEscapedNeverErrors() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "NieR:Automata", platformIDs: ["ps4"], owned: true))
        func titles(_ q: String) async throws -> [String] {
            try await store.gamesOnce(filter: LibraryFilter(searchText: q)).map(\.title)
        }
        // A colon in the query must not break parsing, and still finds the game.
        #expect(try await titles("nier").contains("NieR:Automata"))
        #expect(try await titles("NieR:Automata").contains("NieR:Automata"))
        // Pure-punctuation / operator characters must never throw.
        for q in ["\"", "*", "-", "'", "(", ")", "^", "nier\"", "a - b", "* * *", ":"] {
            _ = try await titles(q)   // just: does not throw
        }
    }

    // MARK: - FTS: alt-title recall + selected sort respected

    @Test func altTitleRecallAndSortPreserved() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "Broken Sword", year: 1996,
            altTitles: ["Les Chevaliers de Baphomet"], platformIDs: ["pc"], owned: true))
        _ = try await store.addGame(GameDraft(title: "Baldur's Gate", year: 1998,
            platformIDs: ["pc"], owned: true))
        // Baphomet → Broken Sword (via alt titles).
        #expect(try await store.gamesOnce(filter: LibraryFilter(searchText: "Baphomet")).map(\.title) == ["Broken Sword"])
        // A 'b' prefix hits both; the selected sort (year desc) is honoured.
        let byYear = try await store.gamesOnce(filter: LibraryFilter(searchText: "b", sort: .year, ascending: false))
        #expect(byYear.map(\.title) == ["Baldur's Gate", "Broken Sword"])
    }
}
