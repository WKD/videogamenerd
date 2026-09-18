import Foundation
import Testing
@testable import VGN

struct LibretroFilenameTests {

    @Test("Parses regions, languages, disc, revision and title")
    func fullParse() {
        let f = LibretroFilenameParser.parse("Final Fantasy IX (USA) (Disc 1) (Rev 2) (En,Fr,De).png")
        #expect(f.title == "Final Fantasy IX")
        #expect(f.regions == ["USA"])
        #expect(f.languages == ["En", "Fr", "De"])
        #expect(f.disc == 1)
        #expect(f.revision == "2")
        #expect(f.isPrerelease == false)
    }

    @Test("Trailing-article form reflows to leading")
    func trailingArticle() {
        let f = LibretroFilenameParser.parse("Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De).png")
        #expect(f.title == "Legend of Zelda, The - Ocarina of Time")
        #expect(f.titleLeading == "The Legend of Zelda - Ocarina of Time")
        #expect(f.regions == ["Europe"])
    }

    @Test("Prerelease tags are flagged")
    func prerelease() {
        #expect(LibretroFilenameParser.parse("Some Game (USA) (Beta).png").isPrerelease)
        #expect(LibretroFilenameParser.parse("Some Game (Proto).png").isPrerelease)
        #expect(LibretroFilenameParser.parse("Some Game (Demo).png").isPrerelease)
    }

    @Test("libretroKey reverses the underscore substitution and drops 'and'")
    func keyReversesSubstitution() {
        // libretro replaces '&' with '_' → "Ratchet _ Clank"
        #expect(LibretroIndex.libretroKey("Ratchet _ Clank") == LibretroIndex.libretroKey("Ratchet & Clank"))
        #expect(LibretroIndex.libretroKey("Ratchet & Clank") == "ratchet clank")
    }
}

struct LibretroIndexTests {

    private let filenames = [
        "Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De).png",
        "Legend of Zelda, The - Ocarina of Time (USA).png",
        "Legend of Zelda, The - Ocarina of Time (Japan).png",
        "Legend of Zelda, The - Majora's Mask (Europe).png",
        "Final Fantasy VII (Europe) (Disc 1).png",
        "Final Fantasy VII (Europe) (Disc 2).png",
        "Final Fantasy VII (USA) (Disc 1).png",
        "Ratchet _ Clank (Europe).png",
        "Metal Gear Solid (Europe) (Disc 1) (Beta).png",
        "Metal Gear Solid (Europe) (Disc 1).png",
        "Metal Gear Solid (USA) (Disc 1).png",
    ]

    @Test("Matches an IGDB title to the preferred region filename")
    func matchRegion() {
        let index = LibretroIndex(filenames: filenames)
        let m = index.match(title: "The Legend of Zelda: Ocarina of Time")
        #expect(m != nil)
        // Europe preferred over USA/Japan.
        #expect(m?.filename == "Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De).png")
        #expect(m?.region == "Europe")
    }

    @Test("Prefers Disc 1 and skips beta when a clean copy exists")
    func discAndBeta() {
        let index = LibretroIndex(filenames: filenames)
        let ff = index.match(title: "Final Fantasy VII")
        #expect(ff?.disc == 1)
        #expect(ff?.region == "Europe")
        let mgs = index.match(title: "Metal Gear Solid")
        // Beta must be skipped in favour of the clean Europe Disc 1.
        #expect(mgs?.filename == "Metal Gear Solid (Europe) (Disc 1).png")
    }

    @Test("Matches Ratchet & Clank despite the underscore substitution")
    func ampersandSubstitution() {
        let index = LibretroIndex(filenames: filenames)
        let m = index.match(title: "Ratchet & Clank")
        #expect(m?.filename == "Ratchet _ Clank (Europe).png")
    }

    @Test("No match for a title absent from the repo")
    func noMatch() {
        let index = LibretroIndex(filenames: filenames)
        #expect(index.match(title: "Bloodborne") == nil)
    }

    @Test("Region preference is configurable")
    func configurableRegion() {
        let index = LibretroIndex(filenames: filenames, regionPreference: ["Japan", "USA", "Europe"])
        let m = index.match(title: "The Legend of Zelda: Ocarina of Time")
        #expect(m?.region == "Japan")
    }

    @Test("Indexes 10k filenames and does 1k lookups comfortably fast")
    func performance() {
        // Synthesize 10,000 filenames like a real repo: ~2,000 distinct franchises
        // (diverse first tokens → small buckets), each with a few region variants.
        var names: [String] = []
        names.reserveCapacity(10_000)
        let regions = ["Europe", "USA", "Japan", "World", "Germany"]
        let suffixes = ["Adventure", "Chronicles", "Legends", "Warriors", "Quest", "Saga"]
        var i = 0
        while names.count < 10_000 {
            let franchise = i / 5                 // 2,000 franchises, 5 variants each
            let suffix = suffixes[i % suffixes.count]
            let region = regions[i % regions.count]
            names.append("Zephyr\(franchise) \(suffix) (\(region)).png")
            i += 1
        }

        let buildStart = Date()
        let index = LibretroIndex(filenames: names)
        let buildMs = Date().timeIntervalSince(buildStart) * 1000
        #expect(index.count == 10_000)

        // 1,000 lookups against real franchise titles.
        let lookupStart = Date()
        var hits = 0
        for k in 0..<1_000 {
            let suffix = suffixes[k % suffixes.count]
            if index.match(title: "Zephyr\(k) \(suffix)") != nil { hits += 1 }
        }
        let lookupMs = Date().timeIntervalSince(lookupStart) * 1000
        print("LibretroIndex perf: build \(Int(buildMs)) ms for 10k names, \(Int(lookupMs)) ms for 1k lookups (\(hits) hits)")
        #expect(hits > 0)
        // Generous ceilings for debug-build CI variance; real numbers are far lower.
        #expect(lookupMs < 3_000)
        #expect(buildMs < 5_000)
    }
}
