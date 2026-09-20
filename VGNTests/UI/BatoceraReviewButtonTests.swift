import Foundation
import Testing
@testable import VGN

/// The Batocera "Review…" affordance (D6, PLAN §15): Settings exposes a Review action when
/// candidates are waiting and calls the review callback once, and the auto-add banner offers
/// Review as a secondary action alongside Undo. No `/Volumes`, no timers.
@MainActor
@Suite(.serialized)
struct BatoceraReviewButtonTests {

    @Test func reviewExposedWhenCandidatesWaitingAndCallsCallbackOnce() async {
        let backend = FakeBatoceraBackend(
            isLive: false,
            status: BatoceraCatalogStatus(totalEntries: 10_911, systemsCount: 35, candidatesWaiting: 283))
        let model = BatoceraSettingsModel(backend: backend)
        await model.refresh()

        #expect(model.candidatesWaiting == 283)
        #expect(model.canReview)

        var reviewCalls = 0
        model.onReviewRequested = { reviewCalls += 1 }
        model.requestReview()
        #expect(reviewCalls == 1)
    }

    @Test func reviewHiddenWhenNothingWaiting() async {
        let backend = FakeBatoceraBackend(
            isLive: false,
            status: BatoceraCatalogStatus(totalEntries: 100, systemsCount: 5, candidatesWaiting: 0))
        let model = BatoceraSettingsModel(backend: backend)
        await model.refresh()
        #expect(model.canReview == false)
    }

    @Test func bannerSecondaryActionRunsAndDismisses() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        var undo = 0, review = 0
        vm.showBanner("3 favourites added from Batocera · 5 to review",
                      actionTitle: "Undo", action: { undo += 1 },
                      secondaryActionTitle: "Review…", secondaryAction: { review += 1 })
        #expect(vm.banner?.actionTitle == "Undo")
        #expect(vm.banner?.secondaryActionTitle == "Review…")

        vm.performBannerSecondaryAction()
        #expect(review == 1)
        #expect(undo == 0)
        #expect(vm.banner == nil)      // dismissed after the action
    }

    @Test func bannerPrimaryActionStillRuns() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        var undo = 0, review = 0
        vm.showBanner("3 favourites added from Batocera · 5 to review",
                      actionTitle: "Undo", action: { undo += 1 },
                      secondaryActionTitle: "Review…", secondaryAction: { review += 1 })
        vm.performBannerAction()
        #expect(undo == 1)
        #expect(review == 0)
        #expect(vm.banner == nil)
    }

    @Test func plainBannerHasNoSecondaryAction() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.showBanner("just info")
        #expect(vm.banner?.secondaryActionTitle == nil)
    }
}
