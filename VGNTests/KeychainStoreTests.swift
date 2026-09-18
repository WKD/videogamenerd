import Testing
import Foundation
@testable import VGN

struct SecretStoreFakeTests {

    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        #expect(try store.string(for: .igdbClientID) == nil)
        #expect(store.hasValue(for: .igdbClientID) == false)

        try store.set("abc", for: .igdbClientID)
        #expect(try store.string(for: .igdbClientID) == "abc")
        #expect(store.hasValue(for: .igdbClientID) == true)

        try store.set("def", for: .igdbClientID)   // overwrite
        #expect(try store.string(for: .igdbClientID) == "def")

        try store.set(nil, for: .igdbClientID)      // delete
        #expect(try store.string(for: .igdbClientID) == nil)

        try store.set("", for: .igdbClientID)       // empty == delete
        #expect(try store.string(for: .igdbClientID) == nil)
    }

    @Test func credentialsProviderNeedsBoth() async {
        let store = InMemorySecretStore()
        let provider = SecretsCredentialsProvider(store: store)
        #expect(await provider.igdbCredentials() == nil)

        try? store.set("id", for: .igdbClientID)
        #expect(await provider.igdbCredentials() == nil)   // secret still missing

        try? store.set("secret", for: .igdbClientSecret)
        let creds = await provider.igdbCredentials()
        #expect(creds?.clientID == "id")
        #expect(creds?.secret == "secret")
    }
}

struct KeychainStoreTests {

    /// One real-Keychain round-trip against a unique, throwaway service so it
    /// never collides with the app's items and cleans itself up. Skips
    /// gracefully if the Keychain is unavailable in the test host.
    @Test func realKeychainRoundTrip() {
        let service = "com.wkd.VGN.test.\(UUID().uuidString)"
        let store = KeychainStore(service: service)

        // Probe: if the host can't use the Keychain (CI, no signing), bail out
        // without failing the suite.
        do {
            try store.set("hello", for: .igdbClientID)
        } catch {
            return
        }
        defer {
            try? store.set(nil, for: .igdbClientID)
            try? store.set(nil, for: .igdbClientSecret)
        }

        #expect((try? store.string(for: .igdbClientID)) == "hello")

        try? store.set("world", for: .igdbClientID)         // update path
        #expect((try? store.string(for: .igdbClientID)) == "world")

        try? store.set("s3cr3t", for: .igdbClientSecret)    // second key
        #expect((try? store.string(for: .igdbClientSecret)) == "s3cr3t")
        #expect(store.hasValue(for: .igdbClientSecret) == true)

        try? store.set(nil, for: .igdbClientID)             // delete path
        #expect((try? store.string(for: .igdbClientID)) == nil)
    }
}
