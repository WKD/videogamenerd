import Foundation
import Testing
@testable import VGN

/// Prefix-aware merge (PLAN §6.2 deliverable 1): edge-cut spine fragments read in a
/// neighbouring tile ("God of W…", "…IE TWICE") fold into the complete read, while two
/// complete sequel titles that merely share a prefix stay apart.
struct RecognitionMergePrefixTests {

    // MARK: - isTruncation (pure)

    @Test("Trailing-ellipsis fragments are truncations of their full title")
    func trailingEllipsis() {
        #expect(ScanMerge.isTruncation(of: "God of War III", fragment: "God of W…"))
        #expect(ScanMerge.isTruncation(of: "Super Mario Odyssey", fragment: "Super Ma…"))
        #expect(ScanMerge.isTruncation(of: "Super Mario Odyssey", fragment: "Super…"))
        #expect(ScanMerge.isTruncation(of: "Final Fantasy VII", fragment: "FINAL FA…"))
        #expect(ScanMerge.isTruncation(of: "The Legend of Zelda", fragment: "The Legend o…"))
        #expect(ScanMerge.isTruncation(of: "Mario Party Superstars", fragment: "Mario Pa…"))
        // Three-dot marker variant.
        #expect(ScanMerge.isTruncation(of: "God of War Collection", fragment: "God of..."))
    }

    @Test("Leading-ellipsis fragments are suffix truncations")
    func leadingEllipsis() {
        #expect(ScanMerge.isTruncation(of: "Sekiro: Shadows Die Twice", fragment: "…IE TWICE"))
        #expect(ScanMerge.isTruncation(of: "Metal Gear Solid V: The Phantom Pain", fragment: "...ission") == false)
        // "…ission" is a suffix of "Mission"-ending titles:
        #expect(ScanMerge.isTruncation(of: "Splinter Cell: Mission", fragment: "...ission"))
        #expect(ScanMerge.isTruncation(of: "Red Dead", fragment: "DEA...") == false)
    }

    @Test("Marker-less mid-word cuts are truncations; token-boundary shares are not")
    func midWordVersusBoundary() {
        // Mid-word cut → truncation.
        #expect(ScanMerge.isTruncation(of: "Uncharted 4", fragment: "Uncharte"))
        #expect(ScanMerge.isTruncation(of: "God of War III", fragment: "God of Wa"))
        // Complete titles sharing a prefix at a token boundary → NOT truncation.
        #expect(ScanMerge.isTruncation(of: "Final Fantasy X-2", fragment: "Final Fantasy X") == false)
        #expect(ScanMerge.isTruncation(of: "Yakuza Kiwami 2", fragment: "Yakuza Kiwami") == false)
        #expect(ScanMerge.isTruncation(of: "Portal 2", fragment: "Portal") == false)
    }

    @Test("A ≤2-char core is too short to be a trusted truncation")
    func tooShort() {
        #expect(ScanMerge.isTruncation(of: "Danganronpa", fragment: "DA…") == false)
        #expect(ScanMerge.isTruncation(of: "Days Gone", fragment: "DA…") == false)
    }

    // MARK: - merge() end to end

    @Test("A trailing-ellipsis fragment merges into the complete read at the same spine")
    func fragmentMergesIntoComplete() {
        let full = RecognitionFixtures.anchored(id: 0, title: "God of War III", platform: "ps3", confidence: 0.9, x: 1000, tileID: 0)
        let frag = RecognitionFixtures.anchored(id: 1, title: "God of W…", platform: "ps3", confidence: 0.4, x: 1030, tileID: 1)
        let merged = ScanMerge.merge([full, frag])
        #expect(merged.count == 1)
        #expect(merged[0].printedTitle == "God of War III")   // complete read wins the title
        #expect(merged[0].memberCount == 2)
    }

    @Test("The complete read wins the title even when the fragment scored higher")
    func completeWinsOverConfidentFragment() {
        let frag = RecognitionFixtures.anchored(id: 0, title: "God of W…", platform: "ps3", confidence: 0.95, x: 1000, tileID: 0)
        let full = RecognitionFixtures.anchored(id: 1, title: "God of War III", platform: "ps3", confidence: 0.6, x: 1025, tileID: 1)
        let merged = ScanMerge.merge([frag, full])
        #expect(merged.count == 1)
        #expect(merged[0].printedTitle == "God of War III")
    }

    @Test("A leading-ellipsis fragment folds into its suffix match")
    func leadingFragmentMerges() {
        let full = RecognitionFixtures.anchored(id: 0, title: "Sekiro: Shadows Die Twice", platform: "ps4", confidence: 0.9, x: 2000, tileID: 0)
        let frag = RecognitionFixtures.anchored(id: 1, title: "…IE TWICE", platform: "ps4", confidence: 0.4, x: 2020, tileID: 1)
        let merged = ScanMerge.merge([full, frag])
        #expect(merged.count == 1)
        #expect(merged[0].printedTitle == "Sekiro: Shadows Die Twice")
    }

    @Test("Complete sequels sharing a prefix at the same spine stay two")
    func sequelsStayApart() {
        let a = RecognitionFixtures.anchored(id: 0, title: "Final Fantasy X", platform: "ps3", confidence: 0.9, x: 1000, tileID: 0)
        let b = RecognitionFixtures.anchored(id: 1, title: "Final Fantasy X-2", platform: "ps3", confidence: 0.9, x: 1015, tileID: 1)
        let merged = ScanMerge.merge([a, b])
        #expect(merged.count == 2)
    }

    @Test("A fragment far from the full read is not merged (geometry guard)")
    func distantFragmentStays() {
        let full = RecognitionFixtures.anchored(id: 0, title: "God of War III", platform: "ps3", confidence: 0.9, x: 500, tileID: 0)
        let frag = RecognitionFixtures.anchored(id: 1, title: "God of W…", platform: "ps3", confidence: 0.4, x: 3200, tileID: 1)
        let merged = ScanMerge.merge([full, frag])
        #expect(merged.count == 2)
    }
}
