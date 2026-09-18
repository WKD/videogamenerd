import Foundation
import Testing
@testable import VGN

struct IGDBQueryTests {

    @Test("Escapes double quotes and backslashes in search text")
    func escaping() {
        #expect(IGDBQuery.escape(#"say "hi""#) == #"say \"hi\""#)
        #expect(IGDBQuery.escape(#"back\slash"#) == #"back\\slash"#)
        #expect(IGDBQuery.escape("line\nbreak") == "line break")
    }

    @Test("A search query embeds escaped text and terminates every clause")
    func searchBuild() {
        let q = IGDBQuery()
            .search(#"Uncharted "Drake""#)
            .fields(["name", "cover.image_id"])
            .limit(12)
            .build()
        #expect(q == #"search "Uncharted \"Drake\""; fields name,cover.image_id; limit 12;"#)
    }

    @Test("Where / sort / offset compose in order")
    func fullBuild() {
        let q = IGDBQuery()
            .fields(["name"])
            .filter("id = (1,2,3)")
            .sort("first_release_date desc")
            .limit(5)
            .offset(10)
            .build()
        #expect(q == "fields name; where id = (1,2,3); sort first_release_date desc; limit 5; offset 10;")
    }

    @Test("idSet formats integer id lists")
    func idSet() {
        #expect(IGDBQuery.idSet([1, 2, 3] as [Int64]) == "(1,2,3)")
        #expect(IGDBQuery.idSet([48] as [Int]) == "(48)")
    }
}

struct IGDBGameTypeTests {

    @Test("Maps the live game_type ids verified during recording")
    func mapping() {
        #expect(IGDBGameType(rawValue: 0) == .mainGame)
        #expect(IGDBGameType(rawValue: 3) == .bundle)
        #expect(IGDBGameType(rawValue: 8) == .remake)
        #expect(IGDBGameType(rawValue: 9) == .remaster)
        #expect(IGDBGameType(rawValue: 10) == .expandedGame)
        #expect(IGDBGameType(rawValue: 11) == .port)
        #expect(IGDBGameType(rawValue: 13) == .pack)
    }

    @Test("Unknown ids round-trip through .unknown")
    func unknown() {
        #expect(IGDBGameType(rawValue: 99) == .unknown(99))
        #expect(IGDBGameType(rawValue: 99).rawValue == 99)
    }

    @Test("Bundle and pack are compilations")
    func compilation() {
        #expect(IGDBGameType.bundle.isCompilation)
        #expect(IGDBGameType.pack.isCompilation)
        #expect(!IGDBGameType.mainGame.isCompilation)
        #expect(!IGDBGameType.remaster.isCompilation)
    }
}
