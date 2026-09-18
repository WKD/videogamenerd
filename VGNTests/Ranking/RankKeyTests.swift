import Testing
@testable import VGN

struct RankKeyTests {

    @Test("Empty tier places at the centred initial key")
    func emptyInitial() {
        #expect(RankKeySpace.placement(inserting: 0, into: []) == .key(RankKeySpace.initial))
    }

    @Test("Append and prepend step by the default gap")
    func appendPrepend() {
        let keys: [RankKey] = [1000]
        // append
        if case .key(let k) = RankKeySpace.placement(inserting: 1, into: keys) {
            #expect(k == 1000 + RankKeySpace.step)
        } else { Issue.record("expected key") }
        // prepend
        if case .key(let k) = RankKeySpace.placement(inserting: 0, into: keys) {
            #expect(k == 1000 - RankKeySpace.step)
        } else { Issue.record("expected key") }
    }

    @Test("Between returns the integer midpoint")
    func midpoint() {
        #expect(RankKeySpace.between(0, 100) == 50)
        #expect(RankKeySpace.between(0, 2) == 1)
        #expect(RankKeySpace.between(0, 1) == nil)      // no gap
        #expect(RankKeySpace.between(5, 5) == nil)      // equal
        #expect(RankKeySpace.between(10, 5) == nil)     // out of order
    }

    @Test("Midpoint is overflow safe at the extremes")
    func overflowSafe() {
        #expect(RankKeySpace.between(RankKey.min, RankKey.max) != nil)
        let mid = RankKeySpace.between(RankKey.min, RankKey.max)!
        #expect(mid > RankKey.min && mid < RankKey.max)
        #expect(RankKeySpace.after(RankKey.max) == nil)
        #expect(RankKeySpace.before(RankKey.min) == nil)
    }

    @Test("Renumber keys are strictly increasing, evenly spaced, count-correct")
    func renumber() {
        for n in 0...20 {
            let keys = RankKeySpace.renumberKeys(count: n)
            #expect(keys.count == n)
            if n >= 2 {
                for i in 1..<n { #expect(keys[i] > keys[i - 1]) }
                let gap = keys[1] - keys[0]
                for i in 1..<n { #expect(keys[i] - keys[i - 1] == gap) }
            }
        }
    }

    @Test("Insertion into a zero-gap neighbourhood forces a renumber")
    func exhaustion() {
        // Two adjacent integers: no midpoint → renumber the full 3-item order.
        let keys: [RankKey] = [10, 11]
        let placement = RankKeySpace.placement(inserting: 1, into: keys)
        guard case .renumber(let newKeys) = placement else {
            Issue.record("expected renumber, got \(placement)"); return
        }
        #expect(newKeys.count == 3)
        #expect(newKeys[0] < newKeys[1] && newKeys[1] < newKeys[2])
    }

    @Test("Repeated midpoint insertions eventually renumber, never break ordering")
    func repeatedMidpoint() {
        // Start with a tiny window and keep inserting in the middle. Each step
        // either finds a midpoint or renumbers; ordering must always hold.
        var keys: [RankKey] = [0, 4]
        var renumbered = false
        for _ in 0..<10 {
            switch RankKeySpace.placement(inserting: 1, into: keys) {
            case .key(let k):
                #expect(k > keys[0] && k < keys[1])
                keys = [keys[0], k, keys[1]]
                // Keep squeezing the left gap.
                keys = [keys[0], keys[1]]
            case .renumber(let nk):
                renumbered = true
                keys = [nk[0], nk[1]]
            }
        }
        #expect(renumbered) // a tiny window must have forced a renumber
    }

    @Test("needsRenumber flags packed or disordered keys")
    func needsRenumber() {
        #expect(RankKeySpace.needsRenumber([]) == false)
        #expect(RankKeySpace.needsRenumber([100]) == false)
        #expect(RankKeySpace.needsRenumber([10, 20, 30]) == false)
        #expect(RankKeySpace.needsRenumber([10, 11, 30]) == true)   // packed pair
        #expect(RankKeySpace.needsRenumber([10, 10]) == true)       // duplicate
    }
}
