import Foundation
import Testing
@testable import VGN

/// The GOG wiring only constructs live GOG objects (auth actor, real backend, sign-in) in
/// live mode with services (PLAN §14.4). Sample/seeded modes — and live without a services
/// graph — get an inert backend that never touches the network or the Keychain.
@MainActor
@Suite(.serialized)
struct GOGWiringTests {
    private func build(mode: LaunchMode, withGraph: Bool) throws -> GOGImportBuilder.Wiring {
        let db = try AppDatabase.inMemory()
        // No graph is passed here (building a real graph is unnecessary — the point is
        // that non-live / graph-less modes must NOT reach for the live path).
        return GOGImportBuilder.build(
            mode: mode, database: db, secrets: InMemorySecretStore(),
            graph: nil, platformCatalog: nil, onLibraryChanged: {})
    }

    @Test(.timeLimit(.minutes(1)))
    func sampleModeUsesInertBackendAndNoSignIn() throws {
        let wiring = try build(mode: .sampleData, withGraph: false)
        #expect(wiring.presenter.backend is InertImportBackend)
        #expect(wiring.account.login == nil)
        #expect(!wiring.account.canSignIn)
    }

    @Test(.timeLimit(.minutes(1)))
    func liveWithoutServicesFallsBackToInert() throws {
        let wiring = try build(mode: .live, withGraph: false)
        #expect(wiring.presenter.backend is InertImportBackend)
        #expect(wiring.account.login == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func inertBackendIsSignedOutAndSyncsNothing() async throws {
        let wiring = try build(mode: .sampleData, withGraph: false)
        #expect(await wiring.presenter.backend.hasSession() == false)
        let result = try await wiring.presenter.backend.runSync { _ in }
        #expect(result.matches.isEmpty)
        #expect(result.rows.isEmpty)
    }
}
