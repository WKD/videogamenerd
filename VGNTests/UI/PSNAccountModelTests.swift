import Foundation
import Testing
@testable import VGN

/// `PSNAccountModel` state, the paste-NPSSO validation (never echoed), the Force-refresh
/// confirmation text, sign-out wipe, and each error surface — all against a
/// ``FakeImportBackend`` (no network, no Keychain).
@MainActor
@Suite(.serialized)
struct PSNAccountModelTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func dataSets() -> [ImportDataSet] {
        [
            ImportDataSet(id: PSNEndpoint.profile, title: "Profile", estimatedRequests: 1),
            ImportDataSet(id: PSNEndpoint.trophyTitles, title: "Trophy titles", estimatedRequests: 4),
            ImportDataSet(id: PSNEndpoint.gameList, title: "Game list", estimatedRequests: 3),
            ImportDataSet(id: PSNEndpoint.purchases, title: "Purchases", estimatedRequests: 4),
        ]
    }

    private func makeModel(session: Bool, username: String? = nil,
                           ages: [ImportCacheAge] = []) throws -> (PSNAccountModel, FakeImportBackend) {
        let db = try AppDatabase.inMemory()
        let backend = FakeImportBackend(
            source: ImportSourceID.psn, sourceLabel: "PlayStation",
            dataSets: dataSets(), staging: ImportStagingStore(db),
            session: session, username: username, ages: ages)
        let model = PSNAccountModel(backend: backend, login: nil)
        model.now = { self.now }
        return (model, backend)
    }

    @Test(.timeLimit(.minutes(1)))
    func signedInStateReflectsBackendAndUsesOnlineID() async throws {
        let ages = [ImportCacheAge(key: PSNEndpoint.profile, endpoint: PSNEndpoint.profile,
                                   fetchedAt: now.addingTimeInterval(-3600), expiresAt: now, itemCount: 1)]
        let (model, _) = try makeModel(session: true, username: "nerd_ps", ages: ages)
        model.sessionExpiryProvider = { self.now.addingTimeInterval(60 * 86_400) }
        await model.refresh()
        #expect(model.signedIn)
        #expect(model.onlineID == "nerd_ps")
        #expect(model.lastSync == now.addingTimeInterval(-3600))
        #expect(model.sessionExpiry == now.addingTimeInterval(60 * 86_400))
    }

    @Test(.timeLimit(.minutes(1)))
    func signedOutClearsOnlineIDAndExpiry() async throws {
        let (model, _) = try makeModel(session: false)
        model.sessionExpiryProvider = { self.now }
        await model.refresh()
        #expect(!model.signedIn)
        #expect(model.onlineID == nil)
        #expect(model.sessionExpiry == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func pasteNPSSORejectsImplausibleWithoutEchoingIt() async throws {
        let (model, backend) = try makeModel(session: false)
        model.npssoInput = "too-short"
        model.submitPastedNPSSO()
        // Rejected: nothing exchanged, the field is NOT cleared, and the value never
        // appears in the error surface.
        #expect(backend.completedCode == nil)
        let surface = try #require(model.pendingError)
        #expect(!surface.title.contains("too-short"))
        #expect(!surface.message.contains("too-short"))
        #expect(model.npssoInput == "too-short")
    }

    @Test(.timeLimit(.minutes(1)))
    func pasteNPSSOExchangesPlausibleAndClearsField() async throws {
        let (model, backend) = try makeModel(session: false)
        let npsso = String(repeating: "a", count: 64)   // plausible shape
        model.npssoInput = npsso
        model.pasteExpanded = true
        model.submitPastedNPSSO()
        #expect(model.npssoInput == "")           // cleared immediately
        #expect(!model.pasteExpanded)
        await poll(until: { backend.completedCode == npsso })
        #expect(backend.completedCode == npsso)   // passed through as the sign-in code
    }

    @Test(.timeLimit(.minutes(1)))
    func webLoginCompletesSignIn() async throws {
        let (model, backend) = try makeModel(session: false)
        let npsso = String(repeating: "b", count: 48)
        model.showLogin = true
        model.completeSignIn(npsso: npsso)
        #expect(!model.showLogin)
        await poll(until: { backend.completedCode == npsso })
        await poll(until: { model.signedIn })
    }

    @Test(.timeLimit(.minutes(1)))
    func forceRefreshConfirmationStatesCostAndAgeInPlayStationWording() async throws {
        let ages = [ImportCacheAge(key: "trophyTitles?x", endpoint: PSNEndpoint.trophyTitles,
                                   fetchedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: now, itemCount: 10)]
        let (model, _) = try makeModel(session: true, ages: ages)
        await model.refresh()
        let trophies = model.dataSets.first { $0.id == PSNEndpoint.trophyTitles }!
        model.requestForceRefresh(trophies)
        let confirmation = try #require(model.forceRefreshConfirmation)
        #expect(confirmation.message.contains("up to 4 requests"))
        #expect(confirmation.message.contains("3 days old"))
        #expect(confirmation.message.contains("PlayStation"))
    }

    @Test(.timeLimit(.minutes(1)))
    func confirmForceRefreshDropsCacheAndSyncs() async throws {
        let (model, backend) = try makeModel(session: true)
        await model.refresh()
        var synced = false
        model.onSyncRequested = { synced = true }
        let gameList = model.dataSets.first { $0.id == PSNEndpoint.gameList }!
        model.requestForceRefresh(gameList)
        model.confirmForceRefresh()
        // `onSyncRequested` fires strictly after the awaited forceRefresh, so polling on
        // `synced` guarantees the call was recorded too (no ordering race).
        await poll(until: { synced })
        #expect(backend.forceRefreshCalls == [PSNEndpoint.gameList])
    }

    @Test(.timeLimit(.minutes(1)))
    func signOutHonoursWipeTick() async throws {
        let (model, backend) = try makeModel(session: true)
        await model.refresh()
        model.requestSignOut()
        #expect(model.signOutConfirming)
        model.signOutAlsoWipeCache = true
        model.confirmSignOut()
        await poll(until: { backend.signOutCalls.count == 1 })
        #expect(backend.signOutCalls == [true])
        await poll(until: { model.signedIn == false })
    }

    @Test func rejectedErrorSurfaceShowsStopMessageAndExcerpt() throws {
        let (model, _) = try makeModel(session: true)
        let reject = ImportReject(
            source: "psn", endpoint: "gameList", status: 403,
            reason: .authChallenge, redactedExcerpt: "{\"error\":\"…\"}")
        model.present(error: ImportError.rejected(reject))
        let surface = try #require(model.pendingError)
        #expect(surface.message == ImportRejectReason.authChallenge.message)
        #expect(surface.stoppedNote == "VGN stopped and made no further requests.")
        #expect(surface.excerpt == "{\"error\":\"…\"}")
    }

    @Test func budgetExceededAndNotAuthenticatedSurfaces() throws {
        let (model, _) = try makeModel(session: true)
        model.present(error: ImportError.budgetExceeded(limit: 40))
        #expect(model.pendingError?.message.contains("40") == true)
        model.present(error: ImportError.notAuthenticated)
        #expect(model.pendingError?.title == "Signed out of PlayStation")
    }
}
