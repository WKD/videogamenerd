import Foundation

/// Invariant checking over a snapshot, and contradiction (cycle) detection over
/// the comparison log. Output is small and deterministic.
enum Consistency {

    // MARK: - Invariants

    struct Violation: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case nonIncreasingKeys   // keys not strictly increasing within a tier
            case duplicateKey        // two placed games share a key in a tier
            case duplicateGame       // a game appears more than once
        }
        var kind: Kind
        var tier: TierID?
        var games: [GameID]
    }

    /// Check the structural invariants of a snapshot:
    /// - within each tier, placed keys strictly increase (no duplicates, ordered);
    /// - no game appears twice (across placed + unplaced, and across tiers).
    ///
    /// A game with a tier but no key is *unplaced*, which is legal (it lives in the
    /// tail); "no key without tier" holds by construction of the snapshot types.
    static func checkInvariants(_ snapshot: RankSnapshot) -> [Violation] {
        var violations: [Violation] = []
        var seen: [GameID: Int] = [:] // id → count

        for slice in snapshot.orderedTiers {
            // Strictly increasing keys + duplicate keys.
            for i in 1..<max(1, slice.placed.count) where slice.placed.count >= 2 {
                let prev = slice.placed[i - 1]
                let cur = slice.placed[i]
                if cur.key == prev.key {
                    violations.append(Violation(kind: .duplicateKey, tier: slice.tier, games: [prev.id, cur.id]))
                } else if cur.key < prev.key {
                    violations.append(Violation(kind: .nonIncreasingKeys, tier: slice.tier, games: [prev.id, cur.id]))
                }
            }
            for item in slice.placed { seen[item.id, default: 0] += 1 }
            for id in slice.unplaced { seen[id, default: 0] += 1 }
        }

        for (id, count) in seen where count > 1 {
            violations.append(Violation(kind: .duplicateGame, tier: nil, games: [id]))
        }
        // Deterministic order.
        return violations.sorted { lhs, rhs in
            if lhs.games != rhs.games { return (lhs.games.first ?? 0) < (rhs.games.first ?? 0) }
            return String(describing: lhs.kind) < String(describing: rhs.kind)
        }
    }

    // MARK: - Contradiction detection (cycles)

    /// A set of games caught in a preference cycle (A>B>C>A). `games` is the whole
    /// strongly-connected component (sorted); `cycle` is one concrete offending
    /// loop for display (canonicalised to start at its smallest id).
    struct Dispute: Equatable, Sendable {
        var games: [GameID]
        var cycle: [GameID]
    }

    /// Find preference cycles in the comparison log. Only the *latest* comparison
    /// of each unordered pair counts (superseded results are ignored). Uses Tarjan
    /// SCCs; every component with more than one node is a dispute.
    static func detectContradictions(_ log: [Comparison]) -> [Dispute] {
        // Build the directed graph winner → loser from latest-per-pair edges.
        var adjacency: [GameID: [GameID]] = [:]
        var nodes: Set<GameID> = []
        for (_, c) in log.latestPerPair() {
            adjacency[c.winner, default: []].append(c.loser)
            nodes.insert(c.winner)
            nodes.insert(c.loser)
        }
        // Deterministic adjacency order.
        for k in adjacency.keys { adjacency[k]?.sort() }

        let sccs = tarjanSCCs(nodes: nodes.sorted(), adjacency: adjacency)
        var disputes: [Dispute] = []
        for scc in sccs where scc.count > 1 {
            let members = scc.sorted()
            let cycle = findCycle(in: Set(scc), adjacency: adjacency) ?? members
            disputes.append(Dispute(games: members, cycle: cycle))
        }
        // Deterministic order of disputes.
        return disputes.sorted { ($0.games.first ?? 0) < ($1.games.first ?? 0) }
    }

    // MARK: - Tarjan

    private static func tarjanSCCs(nodes: [GameID], adjacency: [GameID: [GameID]]) -> [[GameID]] {
        var index: [GameID: Int] = [:]
        var lowlink: [GameID: Int] = [:]
        var onStack: Set<GameID> = []
        var stack: [GameID] = []
        var counter = 0
        var result: [[GameID]] = []

        // Iterative Tarjan to avoid deep recursion on large logs.
        func strongConnect(_ start: GameID) {
            var callStack: [(node: GameID, neighbours: [GameID], i: Int)] = []
            index[start] = counter; lowlink[start] = counter; counter += 1
            stack.append(start); onStack.insert(start)
            callStack.append((start, adjacency[start] ?? [], 0))

            while var frame = callStack.popLast() {
                var progressed = false
                while frame.i < frame.neighbours.count {
                    let w = frame.neighbours[frame.i]
                    frame.i += 1
                    if index[w] == nil {
                        index[w] = counter; lowlink[w] = counter; counter += 1
                        stack.append(w); onStack.insert(w)
                        callStack.append((frame.node, frame.neighbours, frame.i))
                        callStack.append((w, adjacency[w] ?? [], 0))
                        progressed = true
                        break
                    } else if onStack.contains(w) {
                        lowlink[frame.node] = min(lowlink[frame.node]!, index[w]!)
                    }
                }
                if progressed { continue }

                // Done with this node's neighbours.
                if lowlink[frame.node] == index[frame.node] {
                    var comp: [GameID] = []
                    while let top = stack.popLast() {
                        onStack.remove(top)
                        comp.append(top)
                        if top == frame.node { break }
                    }
                    result.append(comp)
                }
                // Propagate lowlink to the parent frame, if any.
                if let parent = callStack.last {
                    let updated = min(lowlink[parent.node]!, lowlink[frame.node]!)
                    lowlink[parent.node] = updated
                }
            }
        }

        for n in nodes where index[n] == nil {
            strongConnect(n)
        }
        return result
    }

    /// Find one concrete cycle within an SCC via DFS, canonicalised to start at the
    /// smallest node in the loop.
    private static func findCycle(in scc: Set<GameID>, adjacency: [GameID: [GameID]]) -> [GameID]? {
        guard let start = scc.min() else { return nil }
        var path: [GameID] = []
        var inPath: Set<GameID> = []
        var found: [GameID]?

        func dfs(_ node: GameID) {
            if found != nil { return }
            path.append(node); inPath.insert(node)
            for next in (adjacency[node] ?? []) where scc.contains(next) {
                if found != nil { return }
                if inPath.contains(next) {
                    // Cycle: from `next` in the path back to `node`.
                    if let idx = path.firstIndex(of: next) {
                        found = Array(path[idx...])
                        return
                    }
                } else {
                    dfs(next)
                }
            }
            path.removeLast(); inPath.remove(node)
        }

        dfs(start)
        guard var cycle = found, !cycle.isEmpty else { return nil }
        // Canonicalise: rotate so the smallest id is first (stable output).
        if let minIdx = cycle.indices.min(by: { cycle[$0] < cycle[$1] }) {
            cycle = Array(cycle[minIdx...] + cycle[..<minIdx])
        }
        return cycle
    }
}
