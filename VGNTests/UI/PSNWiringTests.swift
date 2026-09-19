import Foundation
import Testing
@testable import VGN

/// The PSN wiring only constructs live PSN objects (auth actor, real backend, sign-in) in
/// live mode with services (PLAN §13). Sample/seeded modes — and live without a services
/// graph — get the shared inert backend that never touches the network or the Keychain.
@MainActor
@Suite(.serialized)
struct PSNWiringTests {
    private func build(mode: LaunchMode) throws -> PSNImportBuilder.Wiring {
        let db = try AppDatabase.inMemory()
        return PSNImportBuilder.build(
            mode: mode, database: db, secrets: InMemorySecretStore(),
            graph: nil, platformCatalog: nil, onLibraryChanged: {})
    }

    @Test(.timeLimit(.minutes(1)))
    func sampleModeUsesInertBackendAndNoSignIn() throws {
        let wiring = try build(mode: .sampleData)
        #expect(wiring.presenter.backend is InertImportBackend)
        #expect(wiring.presenter.backend.source == ImportSourceID.psn)
        #expect(wiring.presenter.backend.sourceLabel == "PlayStation")
        #expect(wiring.account.login == nil)
        #expect(!wiring.account.canSignIn)
    }

    @Test(.timeLimit(.minutes(1)))
    func liveWithoutServicesFallsBackToInert() throws {
        let wiring = try build(mode: .live)
        #expect(wiring.presenter.backend is InertImportBackend)
        #expect(wiring.account.login == nil)
    }

    @Test func theLiveSafetyLatchIsOffByDefault() {
        // Live PSN objects are only built once the owner arms the latch (PLAN §13.5).
        #expect(AppPreferences.defaults.object(forKey: PSNImportBuilder.liveEnabledKey) == nil)
        #expect(AppPreferences.defaults.bool(forKey: PSNImportBuilder.liveEnabledKey) == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func inertBackendIsSignedOutAndSyncsNothing() async throws {
        let wiring = try build(mode: .sampleData)
        #expect(await wiring.presenter.backend.hasSession() == false)
        let result = try await wiring.presenter.backend.runSync { _ in }
        #expect(result.rows.isEmpty)
    }
}

/// Pure NPSSO-cookie matching for the login sheet — no browser needed.
@Suite struct PSNLoginCookiesTests {
    private func cookie(_ name: String, _ domain: String, _ value: String) -> (name: String, domain: String, value: String) {
        (name, domain, value)
    }

    @Test func matchesExactDomain() {
        let cookies = [cookie("npsso", "ca.account.sony.com", "THE-NPSSO-VALUE")]
        #expect(PSNLoginCookies.npssoValue(from: cookies, name: "npsso", domain: "ca.account.sony.com") == "THE-NPSSO-VALUE")
    }

    @Test func matchesLeadingDotAndSubdomain() {
        let cookies = [cookie("npsso", ".account.sony.com", "V")]
        #expect(PSNLoginCookies.npssoValue(from: cookies, name: "npsso", domain: "ca.account.sony.com") == "V")
    }

    @Test func ignoresWrongNameOrEmptyValue() {
        let cookies = [cookie("other", "ca.account.sony.com", "X"),
                       cookie("npsso", "ca.account.sony.com", "   ")]
        #expect(PSNLoginCookies.npssoValue(from: cookies, name: "npsso", domain: "ca.account.sony.com") == nil)
    }

    @Test func caseInsensitiveName() {
        let cookies = [cookie("NPSSO", "CA.ACCOUNT.SONY.COM", "Z")]
        #expect(PSNLoginCookies.npssoValue(from: cookies, name: "npsso", domain: "ca.account.sony.com") == "Z")
    }
}
