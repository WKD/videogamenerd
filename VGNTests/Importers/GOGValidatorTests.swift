import Foundation
import Testing
@testable import VGN

/// Every ``GOGResponseValidator`` rule of PLAN §14.2, on synthetic fixtures.
@Suite struct GOGValidatorTests {
    let validator = GOGResponseValidator()

    private func raw(_ name: String, status: Int = 200,
                     contentType: String = "application/json") throws -> ImportRawResponse {
        ImportRawResponse(status: status, headers: ["Content-Type": contentType],
                          body: try Fixtures.data(name))
    }
    private func rawJSON(_ json: String, status: Int = 200,
                         contentType: String = "application/json") -> ImportRawResponse {
        ImportRawResponse(status: status, headers: ["Content-Type": contentType], body: Data(json.utf8))
    }

    // MARK: - userData

    @Test func userDataLoggedInIsValid() throws {
        let v = validator.validate(try raw("gog-userdata-loggedin.json"),
                                   context: .init(endpoint: GOGEndpoint.userData))
        #expect(v == .valid(itemCount: 1))
    }

    @Test func userDataLoggedOutIsAuthChallenge() throws {
        let v = validator.validate(try raw("gog-userdata-loggedout.json"),
                                   context: .init(endpoint: GOGEndpoint.userData))
        #expect(v == .rejected(.authChallenge))
    }

    @Test func loginHTMLIsRejected() throws {
        let v = validator.validate(try raw("gog-login-page.html", contentType: "text/html"),
                                   context: .init(endpoint: GOGEndpoint.userData))
        #expect(v == .rejected(.loginPageOrHTML))
    }

    // MARK: - owned ids

    @Test func ownedIDsValid() throws {
        let v = validator.validate(try raw("gog-owned-ids.json"),
                                   context: .init(endpoint: GOGEndpoint.ownedGames))
        #expect(v == .valid(itemCount: 10))
    }

    @Test func ownedIDsEmptyWhenPreviouslyNonEmptyIsSuspicious() {
        let v = validator.validate(rawJSON(#"{"owned":[]}"#),
                                   context: .init(endpoint: GOGEndpoint.ownedGames, previousItemCount: 5))
        #expect(v == .rejected(.suspiciouslyEmpty))
    }

    // MARK: - products pages

    @Test func productsPageValid() throws {
        let v = validator.validate(try raw("gog-products-page1.json"),
                                   context: .init(endpoint: GOGEndpoint.filteredProducts, expectedPage: 1))
        #expect(v == .valid(itemCount: 4))
    }

    @Test func productsPageWrongEchoIsIncoherent() throws {
        // page1 fixture echoes page=1, but we expected page 2.
        let v = validator.validate(try raw("gog-products-page1.json"),
                                   context: .init(endpoint: GOGEndpoint.filteredProducts, expectedPage: 2))
        #expect(v == .rejected(.incoherentPaging))
    }

    @Test func productsPageChangingTotalsIsIncoherent() throws {
        let v = validator.validate(try raw("gog-products-page2.json"),
                                   context: .init(endpoint: GOGEndpoint.filteredProducts,
                                                  expectedPage: 2, expectedTotalPages: 9))
        #expect(v == .rejected(.incoherentPaging))
    }

    @Test func productsPageDuplicateIDsIsIncoherent() throws {
        let v = validator.validate(try raw("gog-products-incoherent.json"),
                                   context: .init(endpoint: GOGEndpoint.filteredProducts, expectedPage: 1))
        #expect(v == .rejected(.incoherentPaging))
    }

    @Test func productsPageDuplicateAgainstEarlierPageIsIncoherent() throws {
        let v = validator.validate(try raw("gog-products-page1.json"),
                                   context: .init(endpoint: GOGEndpoint.filteredProducts,
                                                  expectedPage: 1, seenIDs: ["100002"]))
        #expect(v == .rejected(.incoherentPaging))
    }

    @Test func emptyListValidWhenNoPriorButSuspiciousAfterPrior() throws {
        let fresh = validator.validate(try raw("gog-products-empty.json"),
                                       context: .init(endpoint: GOGEndpoint.filteredProducts, expectedPage: 1))
        #expect(fresh == .valid(itemCount: 0))
        let suspicious = validator.validate(try raw("gog-products-empty.json"),
                                            context: .init(endpoint: GOGEndpoint.filteredProducts,
                                                           expectedPage: 1, previousItemCount: 8))
        #expect(suspicious == .rejected(.suspiciouslyEmpty))
    }

    @Test func errorEnvelopeIsRejected() throws {
        let v = validator.validate(try raw("gog-error-envelope.json"),
                                   context: .init(endpoint: GOGEndpoint.filteredProducts, expectedPage: 1))
        #expect(v == .rejected(.errorEnvelope))
    }

    @Test func rateLimitedByStatus() {
        let v = validator.validate(
            ImportRawResponse(status: 429, headers: ["Retry-After": "7", "Content-Type": "application/json"],
                              body: Data("{}".utf8)),
            context: .init(endpoint: GOGEndpoint.userData))
        #expect(v == .rejected(.rateLimited(retryAfter: 7)))
    }

    // MARK: - Cross-page helpers

    @Test func sumAndOwnedGap() {
        #expect(GOGResponseValidator.sumMatchesTotal(seenCount: 10, totalProducts: 10))
        #expect(!GOGResponseValidator.sumMatchesTotal(seenCount: 9, totalProducts: 10))
        #expect(GOGResponseValidator.ownedGap(pageIDs: [1, 2, 3], ownedIDs: [1, 2]) == [3])
        #expect(GOGResponseValidator.ownedGap(pageIDs: [1, 2], ownedIDs: [1, 2, 3]).isEmpty)
    }
}
