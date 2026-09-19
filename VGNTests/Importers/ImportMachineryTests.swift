import Foundation
import Testing
@testable import VGN

/// Shared importer machinery: budget, pacer, allow-list, retry policy, redactor, and the
/// source-agnostic validator gates. All deterministic; the pacer uses a `ManualClock`.
@Suite(.timeLimit(.minutes(1)))
struct ImportMachineryTests {

    // MARK: - Budget

    @Test func budgetThrowsWhenExhausted() throws {
        var budget = ImportRequestBudget(limit: 2)
        try budget.consume()
        try budget.consume()
        #expect(budget.remaining == 0)
        #expect(throws: ImportError.self) { try budget.consume() }
        #expect(budget.used == 2)   // the over-budget attempt did not count
    }

    // MARK: - Allow-list

    @Test func allowListPassesListedAndRejectsOthers() throws {
        let list = ImportAllowList.gog
        #expect(list.allows(URL(string: "https://embed.gog.com/userData.json")!))
        #expect(list.allows(URL(string: "https://embed.gog.com/account/getFilteredProducts?page=1")!))
        #expect(list.allows(URL(string: "https://auth.gog.com/token?client_id=x")!))
        // `account/gameDetails` is deliberately off the list (PLAN §14.1).
        #expect(!list.allows(URL(string: "https://embed.gog.com/account/gameDetails/1.json")!))
        #expect(!list.allows(URL(string: "https://evil.example.com/x")!))
        // `check` does NOT throw for an allow-listed URL (a disallowed one is a
        // programming error — it `assertionFailure`s in DEBUG, so it is not exercised here).
        try list.check(URL(string: "https://embed.gog.com/userData.json")!)
    }

    // MARK: - Pacer (ManualClock)

    @Test func pacerSpacesRequestsByMinDelay() async throws {
        let clock = ManualClock(now: 0)
        let pacer = ImportRequestPacer(
            pacing: ImportPolicy.Pacing(minDelay: 1, jitter: 0, budget: 10),
            clock: clock, jitter: { 0 })
        // First request: no wait.
        try await pacer.waitBeforeNextRequest()
        // Second request parks until now + 1.
        let task = Task { try await pacer.waitBeforeNextRequest() }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingCount == 1)
        clock.advance(by: 1)
        try await task.value
        #expect(clock.pendingCount == 0)
    }

    @Test func pacerJitterAddsToDelay() async throws {
        let clock = ManualClock(now: 0)
        let pacer = ImportRequestPacer(
            pacing: ImportPolicy.Pacing(minDelay: 1, jitter: 2, budget: 10),
            clock: clock, jitter: { 1 })   // full jitter → +2s → deadline 3
        try await pacer.waitBeforeNextRequest()
        let task = Task { try await pacer.waitBeforeNextRequest() }
        await clock.waitForSleepers(count: 1)
        clock.advance(by: 2)                // not yet (deadline 3)
        #expect(clock.pendingCount == 1)
        clock.advance(by: 1)                // now at 3
        try await task.value
        #expect(clock.pendingCount == 0)
    }

    // MARK: - Retry policy (the §14.1 rule 3 table)

    @Test func retryPolicyTable() {
        let p = ImportRetryPolicy()
        #expect(p.decide(status: 200, retryAfter: nil, hasRefreshedToken: false, hasWaited429: false) == .proceed)
        #expect(p.decide(status: 401, retryAfter: nil, hasRefreshedToken: false, hasWaited429: false) == .refreshTokenOnce)
        #expect(p.decide(status: 401, retryAfter: nil, hasRefreshedToken: true, hasWaited429: false) == .stop)
        #expect(p.decide(status: 429, retryAfter: 5, hasRefreshedToken: false, hasWaited429: false) == .waitRetryAfterThenEnd(5))
        #expect(p.decide(status: 429, retryAfter: nil, hasRefreshedToken: false, hasWaited429: true) == .stop)
        #expect(p.decide(status: 403, retryAfter: nil, hasRefreshedToken: false, hasWaited429: false) == .stop)
        #expect(p.decide(status: 500, retryAfter: nil, hasRefreshedToken: false, hasWaited429: false) == .stop)
    }

    // MARK: - Redactor

    @Test func redactorScrubsLiteralsAndStructuralPatterns() {
        let r = ImportRedactor(literals: ["synthetic-user-1", "SyntheticPlayer"])
        let input = """
        {"username":"SyntheticPlayer","userId":"synthetic-user-1",\
        "email":"someone@example.com","access_token":"abcDEF1234567890abcDEF1234"}
        """
        let out = r.redact(input)
        #expect(!out.contains("SyntheticPlayer"))
        #expect(!out.contains("synthetic-user-1"))
        #expect(!out.contains("someone@example.com"))
        #expect(!out.contains("abcDEF1234567890abcDEF1234"))
        #expect(out.contains("‹redacted›"))
    }

    @Test func redactorIgnoresTrivialLiterals() {
        // Literals shorter than 3 chars are dropped so a body is not shredded.
        let r = ImportRedactor(literals: ["a", "1"])
        #expect(r.redact("a normal 1 line") == "a normal 1 line")
    }

    // MARK: - Source-agnostic validator gates

    private func raw(_ status: Int, _ json: String, contentType: String = "application/json",
                     headers: [String: String] = [:]) -> ImportRawResponse {
        var h = headers
        h["Content-Type"] = contentType
        return ImportRawResponse(status: status, headers: h, body: Data(json.utf8))
    }

    @Test func transportGates() {
        #expect(ImportResponseChecks.transportReject(raw(200, "{}")) == nil)
        #expect(ImportResponseChecks.transportReject(raw(500, "{}")) == .wrongStatus(500))
        #expect(ImportResponseChecks.transportReject(raw(403, "{}")) == .authChallenge)
        #expect(ImportResponseChecks.transportReject(
            raw(429, "{}", headers: ["Retry-After": "12"])) == .rateLimited(retryAfter: 12))
        #expect(ImportResponseChecks.transportReject(
            raw(200, "<!DOCTYPE html><html></html>", contentType: "text/html")) == .loginPageOrHTML)
        #expect(ImportResponseChecks.transportReject(raw(200, "not json", contentType: "text/plain")) == .notJSON)
        #expect(ImportResponseChecks.transportReject(raw(200, #"{"error":"bad"}"#)) == .errorEnvelope)
    }
}
