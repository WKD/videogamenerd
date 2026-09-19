import Foundation
import Testing
@testable import VGN

/// The Keychain-seam PSN token store (over an in-memory secret store — never the real
/// Keychain). Round-trip, delete, and corrupt-blob tolerance.
@Suite struct KeychainPSNTokenStoreTests {
    private let token = PSNStoredToken(
        accessToken: "A.token", refreshToken: "R-token",
        expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
        refreshExpiresAt: Date(timeIntervalSince1970: 1_705_000_000))

    @Test func roundTripAndDelete() throws {
        let secrets = InMemorySecretStore()
        let store = KeychainPSNTokenStore(secrets: secrets)
        try store.saveToken(token)
        #expect(try store.loadToken() == token)
        try store.deleteToken()
        #expect(try store.loadToken() == nil)
    }

    @Test func corruptBlobReadsAsNoSession() throws {
        let secrets = InMemorySecretStore(seed: [.psnTokens: "not json"])
        #expect(try KeychainPSNTokenStore(secrets: secrets).loadToken() == nil)
    }

    @Test func npssoIsNeverStored() throws {
        // The store only ever persists tokens; the NPSSO has no field here at all.
        let secrets = InMemorySecretStore()
        try KeychainPSNTokenStore(secrets: secrets).saveToken(token)
        let blob = try secrets.string(for: .psnTokens) ?? ""
        #expect(!blob.lowercased().contains("npsso"))
    }
}
