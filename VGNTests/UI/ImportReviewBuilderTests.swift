import Foundation
import Testing
@testable import VGN

/// Pure review-row construction, cross-photo collapse and draft building.
struct ImportReviewBuilderTests {

    @Test("The same spine across two overlapping photos collapses to one row")
    func crossPhotoCollapse() {
        let a = ImportFixtures.item(id: 0, photo: "IMG_1", title: "Bloodborne", platform: "ps4", igdbID: 1, bucket: .confident)
        let b = ImportFixtures.item(id: 0, photo: "IMG_2", title: "Bloodborne", platform: "ps4", igdbID: 1, bucket: .confident)
        let rows = PhotoScanReviewBuilder.rows(from: [
            ImportFixtures.result(photo: "IMG_1", items: [a]),
            ImportFixtures.result(photo: "IMG_2", items: [b]),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].seenInPhotos.count == 2)
        #expect(rows[0].seenCountLabel == "seen in 2 photos")
    }

    @Test("The same game on two platforms stays two rows (two copies)")
    func twoCopiesDifferentPlatform() {
        let a = ImportFixtures.item(id: 0, photo: "IMG_1", title: "Elden Ring", platform: "ps4", igdbID: 1, bucket: .confident)
        let b = ImportFixtures.item(id: 0, photo: "IMG_1", title: "Elden Ring", platform: "ps5", igdbID: 1, bucket: .confident, x: 2000)
        let rows = PhotoScanReviewBuilder.rows(from: [ImportFixtures.result(photo: "IMG_1", items: [a, b])])
        #expect(rows.count == 2)
    }

    @Test("Unmatched fragments collapse by normalised printed title + platform")
    func unmatchedCollapse() {
        let a = ImportFixtures.item(id: 0, photo: "IMG_1", title: "God of W…", platform: "ps3", igdbID: nil, bucket: .none)
        let b = ImportFixtures.item(id: 0, photo: "IMG_2", title: "god of w…", platform: "ps3", igdbID: nil, bucket: .none)
        let rows = PhotoScanReviewBuilder.rows(from: [
            ImportFixtures.result(photo: "IMG_1", items: [a]),
            ImportFixtures.result(photo: "IMG_2", items: [b]),
        ])
        #expect(rows.count == 1)
    }

    @Test("A game draft is owned, physical, photo-sourced, carrying the printed alt title")
    func gameDraft() {
        var row = PhotoScanReviewBuilder.rows(from: [ImportFixtures.result(photo: "IMG_1", items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Broken Sword", platform: "ps4", igdbID: 42, bucket: .confident)
        ])])[0]
        // Simulate a French spine: printed title differs from the matched name.
        row.item.printedTitle = "Les Chevaliers de Baphomet"
        let draft = PhotoScanReviewBuilder.gameDraft(for: row)
        #expect(draft.title == "Broken Sword")
        #expect(draft.igdbID == 42)
        #expect(draft.owned == true)
        #expect(draft.format == .physical)
        #expect(draft.source == .photo)
        #expect(draft.platformIDs == ["ps4"])
        #expect(draft.altTitles.contains("Les Chevaliers de Baphomet"))
    }

    @Test("match(from:) scores a search result against the printed title")
    func matchFromSearch() {
        let result = ImportFixtures.searchResult(id: 7, name: "Sekiro: Shadows Die Twice", altNames: ["Sekiro"])
        let match = PhotoScanReviewBuilder.match(from: result, query: "Sekiro")
        #expect(match.igdbID == 7)
        #expect(match.score > FuzzyMatch.plausibleThreshold)
        #expect(match.matchedName == "Sekiro")
    }

    @Test("Product + member drafts for a compilation preserve order and platform")
    func compilationDrafts() {
        let row = PhotoScanReviewBuilder.rows(from: [ImportFixtures.result(photo: "IMG_1", items: [
            ImportFixtures.item(id: 0, photo: "IMG_1", title: "Jak Collection", platform: "ps3", igdbID: 500, bucket: .confident, compilation: true)
        ])])[0]
        let product = PhotoScanReviewBuilder.productDraft(for: row)
        #expect(product.platformID == "ps3")
        #expect(product.source == .photo)
        let members = PhotoScanReviewBuilder.memberDrafts(from: [
            ImportFixtures.searchResult(id: 1, name: "Jak 1"),
            ImportFixtures.searchResult(id: 2, name: "Jak 2"),
        ], played: true)
        #expect(members.map(\.position) == [0, 1])
        #expect(members.allSatisfy { $0.played })
    }
}
