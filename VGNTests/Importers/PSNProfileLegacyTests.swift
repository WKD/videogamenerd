import Foundation
import Testing
@testable import VGN

/// S2 (2026-09-19): the modern profile endpoint rejects `me` (400 "path: accountId"); the
/// legacy `profile2` endpoint resolves it. Shape per psn-api `getProfileFromUserName`.
struct PSNProfileLegacyTests {
    @Test func decodesTheLegacyNestedProfileWithThePlusFlag() throws {
        let json = #"{"profile":{"onlineId":"TestUser_01","accountId":"1234567890123456789","plus":0}}"#
        let profile = try PSNJSON.decoder.decode(PSNProfile.self, from: Data(json.utf8))
        #expect(profile.onlineId == "TestUser_01")
        #expect(profile.accountId == "1234567890123456789")
        #expect(profile.hasPlus == false)
    }

    @Test func plusMayBeOneOrABool() throws {
        let one = try PSNJSON.decoder.decode(PSNProfile.self, from: Data(#"{"profile":{"onlineId":"a","plus":1}}"#.utf8))
        #expect(one.hasPlus == true)
        let flag = try PSNJSON.decoder.decode(PSNProfile.self, from: Data(#"{"onlineId":"a","isPlus":true}"#.utf8))
        #expect(flag.hasPlus == true)
        let absent = try PSNJSON.decoder.decode(PSNProfile.self, from: Data(#"{"onlineId":"a"}"#.utf8))
        #expect(absent.hasPlus == nil)
    }

    @Test func theAllowListHoldsTheLegacyProfileURLAndNotTheRejectedOne() {
        let legacy = URL(string: "https://us-prof.np.community.playstation.net/userProfile/v1/users/me/profile2?fields=onlineId,accountId,plus")!
        let rejected = URL(string: "https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles")!
        let someoneElse = URL(string: "https://us-prof.np.community.playstation.net/userProfile/v1/users/SomeoneElse/profile2")!
        #expect(ImportAllowList.psn.allows(legacy))
        #expect(!ImportAllowList.psn.allows(rejected))
        #expect(!ImportAllowList.psn.allows(someoneElse))   // only my own profile
    }
}
