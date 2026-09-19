import Foundation
import Testing
@testable import VGN

/// The Keychain-backed GOG token adapter (PLAN §14.1), against the in-memory fake secret
/// store — never the real Keychain. Round-trip, delete, corrupt-blob, one-JSON-blob.
struct KeychainGOGTokenStoreTests {
    private func token() -> GOGStoredToken {
        GOGStoredToken(
            accessToken: "access-aaaa", refreshToken: "refresh-bbbb",
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func roundTrips() throws {
        let secrets = InMemorySecretStore()
        let store = KeychainGOGTokenStore(secrets: secrets)
        #expect(try store.loadToken() == nil)
        try store.saveToken(token())
        #expect(try store.loadToken() == token())
    }

    @Test func storedAsOneJSONBlob() throws {
        let secrets = InMemorySecretStore()
        try KeychainGOGTokenStore(secrets: secrets).saveToken(token())
        // The whole token is one value under the single `gog.tokens` account.
        let raw = try secrets.string(for: .gogTokens)
        #expect(raw != nil)
        #expect(raw!.contains("access-aaaa"))
        #expect(raw!.contains("refresh-bbbb"))
        // No other secret key was written.
        #expect(try secrets.string(for: .igdbClientID) == nil)
    }

    @Test func deleteClears() throws {
        let secrets = InMemorySecretStore()
        let store = KeychainGOGTokenStore(secrets: secrets)
        try store.saveToken(token())
        try store.deleteToken()
        #expect(try store.loadToken() == nil)
        #expect(try secrets.string(for: .gogTokens) == nil)
    }

    @Test func corruptBlobReadsAsNoSession() throws {
        let secrets = InMemorySecretStore()
        try secrets.set("not-json", for: .gogTokens)
        #expect(try KeychainGOGTokenStore(secrets: secrets).loadToken() == nil)
    }
}
