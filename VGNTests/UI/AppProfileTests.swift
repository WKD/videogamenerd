import Foundation
import Testing
@testable import VGN

/// `-VGNProfile <name>`: an isolated library, preferences and Keychain namespace.
struct AppProfileTests {
    @Test func sanitisesTheName() {
        #expect(AppProfile.sanitise(nil) == nil)
        #expect(AppProfile.sanitise("") == nil)
        #expect(AppProfile.sanitise("psn-test") == "psn-test")
        #expect(AppProfile.sanitise("../../etc/passwd") == "etcpasswd")
        #expect(AppProfile.sanitise("a b/c:d") == "abcd")
        #expect(AppProfile.sanitise(String(repeating: "x", count: 80))?.count == 32)
    }

    @Test func derivesSeparateLocations() {
        #expect(AppProfile.folderName(base: "VGN", profile: nil) == "VGN")
        #expect(AppProfile.folderName(base: "VGN", profile: "psn-test") == "VGN-psn-test")
        #expect(AppProfile.keychainService(base: "com.x.App", profile: nil) == "com.x.App")
        #expect(AppProfile.keychainService(base: "com.x.App", profile: "psn-test") == "com.x.App.profile.psn-test")
        #expect(AppProfile.defaultsSuiteName(bundleID: "com.x.App", profile: "psn-test") == "com.x.App.profile.psn-test")
    }

    @Test func theTestHostRunsInTheDefaultProfile() {
        #expect(AppProfile.name == nil)
        #expect(AppPaths.folderName == "VGN")
    }

    @Test func profileSecretsAreSeparateButShareIGDBCredentials() throws {
        let real = InMemorySecretStore(seed: [.igdbClientID: "id", .igdbClientSecret: "secret", .psnTokens: "REAL-TOKENS"])
        let profile = InMemorySecretStore()
        let store = ProfileSecretStore(profile: profile, fallback: real)

        // IGDB credentials are readable from the default namespace…
        #expect(try store.string(for: .igdbClientID) == "id")
        // …but account tokens never leak into the profile.
        #expect(try store.string(for: .psnTokens) == nil)
        #expect(try store.string(for: .gogTokens) == nil)

        // Writes stay in the profile and never touch the real store.
        try store.set("TEST-TOKENS", for: .psnTokens)
        #expect(try store.string(for: .psnTokens) == "TEST-TOKENS")
        #expect(try real.string(for: .psnTokens) == "REAL-TOKENS")
        try store.set(nil, for: .psnTokens)
        #expect(try real.string(for: .psnTokens) == "REAL-TOKENS")
    }
}
