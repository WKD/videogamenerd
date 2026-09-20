import Foundation
import Testing
@testable import VGN

/// The manual "Find on HowLongToBeat…" model (PLAN §5.3, D5): debounce (no per-keystroke
/// requests), the 3-char minimum, the in-session cache, the per-session request counter +
/// cap, and the stop-on-reject path. No network (``FakeHLTBSearch``), no real sleeps.
@MainActor
@Suite struct HLTBFindModelTests {

    /// A sleeper that suspends until `release()` — lets a test prove the debounce holds a
    /// request and coalesces rapid keystrokes to one.
    final class ManualSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        func release() { lock.withLock { released = true } }
        func sleep(_ d: Duration) async throws {
            while !lock.withLock({ released }) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    private func model(_ fake: FakeHLTBSearch, cap: Int = 250, prefill: String = "",
                       sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> HLTBFindModel {
        HLTBFindModel(gameID: 1, title: "Bloodborne", year: 2015, librarySlugs: ["ps4"],
                      linkedID: nil, prefill: prefill, search: fake, isInert: false,
                      requestCap: cap, debounce: .milliseconds(800), sleep: sleep)
    }

    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<4000 where !predicate() { await Task.yield() }
    }

    @Test func belowMinLengthNeverSearches() async throws {
        let fake = FakeHLTBSearch(byTitle: ["ab": [HLTBCandidate(id: 1, name: "ab")]])
        let m = model(fake)
        m.query = "ab"
        m.searchNow()
        await Task.yield()
        #expect(m.phase == .idle)
        #expect(fake.calls.isEmpty)
        #expect(m.requestCount == 0)
    }

    @Test func searchNowReturnsResultsAndCountsOneRequest() async throws {
        let fake = FakeHLTBSearch(byTitle: ["Bloodborne": [HLTBCandidate(id: 21262, name: "Bloodborne")]])
        let m = model(fake)
        m.query = "Bloodborne"
        m.searchNow()
        await settle { m.phase == .results }
        #expect(m.results.first?.id == 21262)
        #expect(m.requestCount == 1)
    }

    @Test func identicalQueryIsServedFromCacheWithoutAnotherRequest() async throws {
        let fake = FakeHLTBSearch(byTitle: ["Bloodborne": [HLTBCandidate(id: 21262, name: "Bloodborne")]])
        let m = model(fake)
        m.query = "Bloodborne"; m.searchNow()
        await settle { m.phase == .results }
        m.query = "Bloodbornex"; m.searchNow()          // a different query
        await settle { m.phase == .empty }
        m.query = "Bloodborne"; m.searchNow()           // back to the first — cached
        await settle { m.phase == .results }
        #expect(m.requestCount == 2)                     // not 3 — the repeat was cached
        #expect(fake.calls.filter { $0 == "Bloodborne" }.count == 1)
    }

    @Test func requestCapHoldsFurtherSearches() async throws {
        let fake = FakeHLTBSearch(byTitle: [
            "Alpha": [HLTBCandidate(id: 1, name: "Alpha")],
            "Bravo": [HLTBCandidate(id: 2, name: "Bravo")],
        ])
        let m = model(fake, cap: 1)
        m.query = "Alpha"; m.searchNow()
        await settle { m.phase == .results }
        #expect(m.requestCount == 1)
        #expect(m.reachedCap)
        m.query = "Bravo"; m.searchNow()                 // over the cap → held
        await Task.yield(); await Task.yield()
        #expect(m.requestCount == 1)
        #expect(!fake.calls.contains("Bravo"))
    }

    @Test func rejectStopsAndReportsAndBlocksFurtherSearches() async throws {
        let fake = FakeHLTBSearch(byTitle: [:], rejectTitles: ["Boom"])
        let m = model(fake)
        m.query = "Boom"; m.searchNow()
        await settle { m.phase == .stopped }
        #expect(m.stopMessage != nil)
        m.query = "Later"; m.searchNow()                 // stopped → no further requests
        await Task.yield()
        #expect(!fake.calls.contains("Later"))
    }

    @Test func debounceHoldsRequestsAndCoalescesRapidTypingToOne() async throws {
        let fake = FakeHLTBSearch(byTitle: ["abcd": [HLTBCandidate(id: 9, name: "abcd")]])
        let sleeper = ManualSleeper()
        let m = model(fake, sleep: { try await sleeper.sleep($0) })
        m.query = "abc"      // one keystroke — task waits on the sleeper
        m.query = "abcd"     // a second keystroke supersedes it
        await Task.yield()
        #expect(fake.calls.isEmpty)      // nothing fired during the pause
        sleeper.release()
        await settle { m.phase == .results }
        #expect(fake.calls == ["abcd"])  // exactly one request, for the final text
        #expect(m.requestCount == 1)
    }

    @Test func linkActionsUpdateLinkedIDAndCallBack() async throws {
        let fake = FakeHLTBSearch(byTitle: [:])
        let m = model(fake)
        var linked: (Int64, HLTBFindModel.LinkKind)?
        m.onLink = { c, k in linked = (c.id, k) }
        m.linkAndUse(HLTBCandidate(id: 55, name: "X"))
        #expect(m.linkedID == 55)
        #expect(linked?.0 == 55 && linked?.1 == .linkAndUse)

        var unlinked = false
        m.onUnlink = { unlinked = true }
        m.unlink()
        #expect(m.linkedID == nil)
        #expect(unlinked)
    }
}
