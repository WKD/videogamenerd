import Foundation
import Testing
@testable import VGN

/// `GOGAccountModel` state, the Force-refresh confirmation text, sign-out wipe, and each
/// error surface — all against a ``FakeImportBackend`` (no network, no Keychain).
@MainActor
@Suite(.serialized)
struct GOGAccountModelTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func dataSets() -> [ImportDataSet] {
        [
            ImportDataSet(id: GOGEndpoint.userData, title: "Account", estimatedRequests: 1),
            ImportDataSet(id: GOGEndpoint.ownedGames, title: "Owned games", estimatedRequests: 1),
            ImportDataSet(id: GOGEndpoint.filteredProducts, title: "Library", estimatedRequests: 5),
        ]
    }

    private func makeModel(session: Bool, username: String? = nil,
                           ages: [ImportCacheAge] = []) throws -> (GOGAccountModel, FakeImportBackend) {
        let db = try AppDatabase.inMemory()
        let backend = FakeImportBackend(
            dataSets: dataSets(), staging: ImportStagingStore(db),
            session: session, username: username, ages: ages)
        let model = GOGAccountModel(backend: backend, login: nil)
        model.now = { self.now }
        return (model, backend)
    }

    @Test(.timeLimit(.minutes(1)))
    func signedInStateReflectsBackend() async throws {
        let ages = [
            ImportCacheAge(key: "userData.json", endpoint: GOGEndpoint.userData,
                           fetchedAt: now.addingTimeInterval(-3600), expiresAt: now, itemCount: 1),
            ImportCacheAge(key: "account/getFilteredProducts?mediaType=1&page=1",
                           endpoint: GOGEndpoint.filteredProducts,
                           fetchedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: now, itemCount: 100),
        ]
        let (model, _) = try makeModel(session: true, username: "gog_gamer", ages: ages)
        await model.refresh()
        #expect(model.signedIn)
        #expect(model.username == "gog_gamer")
        #expect(model.lastSync == now.addingTimeInterval(-3600))
    }

    @Test(.timeLimit(.minutes(1)))
    func signedOutState() async throws {
        let (model, _) = try makeModel(session: false)
        await model.refresh()
        #expect(!model.signedIn)
        #expect(model.username == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func forceRefreshConfirmationStatesCostAndAge() async throws {
        let ages = [ImportCacheAge(
            key: "account/getFilteredProducts?mediaType=1&page=1", endpoint: GOGEndpoint.filteredProducts,
            fetchedAt: now.addingTimeInterval(-3 * 86_400), expiresAt: now, itemCount: 100)]
        let (model, _) = try makeModel(session: true, ages: ages)
        await model.refresh()
        let library = model.dataSets.first { $0.id == GOGEndpoint.filteredProducts }!
        model.requestForceRefresh(library)
        let confirmation = try #require(model.forceRefreshConfirmation)
        #expect(confirmation.message.contains("up to 5 requests"))
        #expect(confirmation.message.contains("3 days old"))
    }

    @Test(.timeLimit(.minutes(1)))
    func forceRefreshOnNeverCachedSetSaysSo() async throws {
        let (model, _) = try makeModel(session: true)
        await model.refresh()
        let account = model.dataSets.first { $0.id == GOGEndpoint.userData }!
        model.requestForceRefresh(account)
        #expect(model.forceRefreshConfirmation?.message.contains("not cached yet") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func confirmForceRefreshDropsCacheAndSyncs() async throws {
        let (model, backend) = try makeModel(session: true)
        await model.refresh()
        var synced = false
        model.onSyncRequested = { synced = true }
        model.requestForceRefresh(model.dataSets[2])
        model.confirmForceRefresh()
        await poll(until: { backend.forceRefreshCalls.count == 1 })
        #expect(backend.forceRefreshCalls == [GOGEndpoint.filteredProducts])
        // The sync request fires AFTER the cache drop returns — poll on the post-condition
        // (asserting it right away raced under a loaded parallel run).
        await poll(until: { synced })
        #expect(synced)
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

    @Test func rejectedErrorSurface() throws {
        let (model, _) = try makeModel(session: true)
        let reject = ImportReject(
            source: "gog", endpoint: "account/getFilteredProducts", status: 403,
            reason: .loginPageOrHTML, redactedExcerpt: "<html>login</html>")
        model.present(error: ImportError.rejected(reject))
        let surface = try #require(model.pendingError)
        #expect(surface.message == ImportRejectReason.loginPageOrHTML.message)
        #expect(surface.stoppedNote == "VGN stopped and made no further requests.")
        #expect(surface.excerpt == "<html>login</html>")
    }

    @Test func budgetExceededSurface() throws {
        let (model, _) = try makeModel(session: true)
        model.present(error: ImportError.budgetExceeded(limit: 15))
        #expect(model.pendingError?.message.contains("15") == true)
        #expect(model.pendingError?.stoppedNote != nil)
    }

    @Test func notAuthenticatedSurface() throws {
        let (model, _) = try makeModel(session: true)
        model.present(error: ImportError.notAuthenticated)
        #expect(model.pendingError?.title == "Signed out of GOG")
    }

    @Test(.timeLimit(.minutes(1)))
    func syncNowInvokesCallback() async throws {
        let (model, _) = try makeModel(session: true)
        var count = 0
        model.onSyncRequested = { count += 1 }
        model.syncNow()
        #expect(count == 1)
    }
}
