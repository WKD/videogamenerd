import Foundation
import Testing
@testable import VGN

/// Every §13.2 "not bogus" rule for PSN responses.
@Suite struct PSNValidatorTests {
    private let validator = PSNResponseValidator()

    private func resp(_ fixture: String, status: Int = 200,
                      contentType: String = "application/json") throws -> ImportRawResponse {
        ImportRawResponse(status: status, headers: ["Content-Type": contentType],
                          body: try Fixtures.data(fixture))
    }
    private func ctx(_ endpoint: String, seen: Set<String> = [], previous: Int? = nil) -> ImportValidationContext {
        ImportValidationContext(endpoint: endpoint, seenIDs: seen, previousItemCount: previous)
    }

    // MARK: - Transport gates

    @Test func htmlLoginPageRejected() throws {
        let r = ImportRawResponse(status: 200, headers: ["Content-Type": "text/html"],
                                  body: try Fixtures.data("psn-login-page.html"))
        #expect(validator.validate(r, context: ctx(PSNEndpoint.profile)).reason == .loginPageOrHTML)
    }
    @Test func authChallengeAndRateLimit() throws {
        let json = Data("{}".utf8)
        let r401 = ImportRawResponse(status: 401, headers: [:], body: json)
        let r429 = ImportRawResponse(status: 429, headers: ["Retry-After": "30"], body: json)
        #expect(validator.validate(r401, context: ctx(PSNEndpoint.profile)).reason == .authChallenge)
        #expect(validator.validate(r429, context: ctx(PSNEndpoint.trophyTitles)).reason == .rateLimited(retryAfter: 30))
    }

    // MARK: - Profile

    @Test func profileValidAndInvalid() throws {
        #expect(validator.validate(try resp("psn-profile.json"), context: ctx(PSNEndpoint.profile)).isValid)
        let empty = ImportRawResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        #expect(validator.validate(empty, context: ctx(PSNEndpoint.profile)).reason == .schemaMismatch)
    }

    // MARK: - Trophy titles

    @Test func trophyValid() throws {
        let v = validator.validate(try resp("psn-trophy-probe.json"), context: ctx(PSNEndpoint.trophyTitles))
        #expect(v == .valid(itemCount: 10))
    }
    @Test func trophyDuplicateIsIncoherent() throws {
        #expect(validator.validate(try resp("psn-trophy-incoherent.json"),
                                   context: ctx(PSNEndpoint.trophyTitles)).reason == .incoherentPaging)
    }
    @Test func trophyEmptyValidForNewAccountButSuspiciousAfterCache() throws {
        let empty = try resp("psn-trophy-empty.json")
        #expect(validator.validate(empty, context: ctx(PSNEndpoint.trophyTitles)).isValid)     // brand-new account
        #expect(validator.validate(empty, context: ctx(PSNEndpoint.trophyTitles, previous: 5)).reason == .suspiciouslyEmpty)
    }
    @Test func trophyBadCommunicationIDRejected() throws {
        let bad = ImportRawResponse(status: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"trophyTitles":[{"npCommunicationId":"BOGUS1","trophyTitleName":"X","trophyTitlePlatform":"PS5","progress":10}],"totalItemCount":1}"#.utf8))
        #expect(validator.validate(bad, context: ctx(PSNEndpoint.trophyTitles)).reason == .schemaMismatch)
    }

    // MARK: - Game list

    @Test func gameListValid() throws {
        #expect(validator.validate(try resp("psn-gamelist.json"), context: ctx(PSNEndpoint.gameList)).isValid)
    }
    @Test func gameListBadTitleIDRejected() throws {
        let bad = ImportRawResponse(status: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"titles":[{"titleId":"lowercase","name":"X"}],"totalItemCount":1}"#.utf8))
        #expect(validator.validate(bad, context: ctx(PSNEndpoint.gameList)).reason == .schemaMismatch)
    }

    // MARK: - Purchases (GraphQL)

    @Test func purchasesValid() throws {
        let v = validator.validate(try resp("psn-purchases.json"), context: ctx(PSNEndpoint.purchases))
        #expect(v == .valid(itemCount: 5))
    }
    @Test func purchasesPersistedQueryNotFoundIsErrorEnvelope() throws {
        #expect(validator.validate(try resp("psn-purchases-pqnf.json"),
                                   context: ctx(PSNEndpoint.purchases)).reason == .errorEnvelope)
    }
    @Test func purchasesEmptyWithErrorsNullIsValid() throws {
        // `errors: null` must NOT be treated as an error envelope.
        #expect(validator.validate(try resp("psn-purchases-empty.json"),
                                   context: ctx(PSNEndpoint.purchases)).isValid)
    }

    // MARK: - Id patterns

    @Test func idPatterns() {
        #expect(PSNResponseValidator.isCommunicationID("NPWR90001_00"))
        #expect(!PSNResponseValidator.isCommunicationID("CUSA90001_00"))
        #expect(PSNResponseValidator.isTitleID("CUSA90001_00"))
        #expect(PSNResponseValidator.isTitleID("PPSA01234_00"))
        #expect(!PSNResponseValidator.isTitleID("lower1234"))
    }
}
