import Foundation
import Testing
@testable import VGN

/// The presenter drives a full file → stage → review pass without the open panel (the
/// panel is exercised only interactively). No cover context ⇒ no source-cover toggle.
@MainActor
@Suite(.serialized)
struct DeliciousWiringTests {

    @Test(.timeLimit(.minutes(1)))
    func startSyncReadsTheFileAndOpensTheReviewSheet() async throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "a", title: "Heavy Rain PS3", platforms: ["PlayStation 3"]),
            .init(uuid: "b", title: "Some Mac Game", platforms: ["Macintosh"]),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let db = try await DeliciousTestDB.makeSeeded()
        let presenter = DeliciousImportPresenter(
            staging: ImportStagingStore(db), matcher: NoMatchImportMatcher(),
            platformChoices: ["ps3", "mac", "pc"])
        presenter.startSync(url: url)

        // Wait for the background sync to open the review sheet.
        var model: ImportReviewModel?
        for _ in 0..<200 {
            if let m = presenter.reviewModel { model = m; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let review = try #require(model)
        await review.load()
        #expect(review.productFormat == .physical)
        #expect(review.rows.count == 2)
        #expect(review.showsSourceCoverToggle == false)           // no cover context here
        #expect(review.summaryLine == "2 games read from Delicious Library")
    }
}
