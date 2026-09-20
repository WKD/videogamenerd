import Foundation
import Testing
@testable import VGN

/// PSN sign-in wording (PLAN §13, D3 wave 16): a failure during the NPSSO → code → token
/// exchange now reads as a *sign-in* failure ("Couldn't sign in to PlayStation — …"), not the
/// generic "sync failed". Presentation-only mapping — the auth layer is untouched.
@MainActor
struct PSNSignInErrorTests {

    private struct DummyError: LocalizedError { var errorDescription: String? { "boom" } }

    @Test func signInFailureReadsAsSignInNotSync() {
        let model = PSNAccountModel.preview(signedIn: false)
        let surface = model.signInErrorSurface(DummyError())
        #expect(surface.title == "Couldn't sign in to PlayStation")
        #expect(surface.title.lowercased().contains("sync") == false)
        // Carries the underlying detail so it is still actionable.
        #expect(surface.message == "boom")
    }

    @Test func notAuthenticatedGetsAFriendlySignInMessage() {
        let model = PSNAccountModel.preview(signedIn: false)
        let surface = model.signInErrorSurface(ImportError.notAuthenticated)
        #expect(surface.title == "Couldn't sign in to PlayStation")
        #expect(surface.message.contains("didn't go through"))
    }

    @Test func readySignInReasonKeepsTheSignInTitle() {
        let model = PSNAccountModel.preview(signedIn: false)
        let surface = model.signInErrorSurface(reason: "We couldn't read the sign-in token.")
        #expect(surface.title == "Couldn't sign in to PlayStation")
        #expect(surface.message == "We couldn't read the sign-in token.")
    }

    @Test func contrastGenericSyncMappingStillSaysSyncFailed() {
        // The generic (sync) mapping is unchanged — proof the sign-in path differs deliberately.
        let sync = ImportErrorSurface.make(from: DummyError(), sourceLabel: "PlayStation")
        #expect(sync.title == "PlayStation sync failed")
    }
}
