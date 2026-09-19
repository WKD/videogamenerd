import Testing
@testable import VGN

/// The Top reorder insertion-line feature (PLAN §7, wave 7 lane F). Two layers:
/// the pure `TheTopDropGeometry` (upper/lower half, first/last of a tier, around
/// dividers, no-op positions next to the dragged game) and the model glue
/// (`beginDrag` / `updateDropTarget` / `applyDrop`), driven against the scripted
/// backend — no database.
@Suite(.timeLimit(.minutes(1)))
struct TheTopDropGeometryTests {
    typealias Slot = TheTopDropGeometry.Slot

    // A chart: S has 3 placed (g1,g2,g3), A has 2 placed (g4,g5) + 1 unplaced (g6).
    private let sTier: Int64 = 100
    private let aTier: Int64 = 200
    private func chart() -> [Slot] {
        [.divider(id: "d100", tierID: sTier),
         .game(id: "g1", gameID: 1, tierID: sTier, placedIndex: 0),
         .game(id: "g2", gameID: 2, tierID: sTier, placedIndex: 1),
         .game(id: "g3", gameID: 3, tierID: sTier, placedIndex: 2),
         .divider(id: "d200", tierID: aTier),
         .game(id: "g4", gameID: 4, tierID: aTier, placedIndex: 0),
         .game(id: "g5", gameID: 5, tierID: aTier, placedIndex: 1),
         .game(id: "g6", gameID: 6, tierID: aTier, placedIndex: nil)]
    }

    // MARK: edge()

    @Test func edgeSplitsAtMidpoint() {
        #expect(TheTopDropGeometry.edge(locationY: 5, rowHeight: 40) == .above)
        #expect(TheTopDropGeometry.edge(locationY: 20, rowHeight: 40) == .below)  // == midpoint ⇒ below
        #expect(TheTopDropGeometry.edge(locationY: 39, rowHeight: 40) == .below)
        #expect(TheTopDropGeometry.edge(locationY: 5, rowHeight: 0) == .above)    // unmeasured
    }

    // MARK: within a tier

    @Test func upperHalfInsertsAboveHoveredGame() {
        // Drag g3 over g1's upper half ⇒ before g1 (gap 0, tier S), a real move.
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 1, edge: .above, draggedID: 3)
        #expect(t?.toTier == sTier)
        #expect(t?.gap == 0)
        #expect(t?.anchorID == "g1")
        #expect(t?.edge == .above)
        #expect(t?.crossesTier == false)
    }

    @Test func lowerHalfInsertsBelowHoveredGame() {
        // Drag g1 over g3's lower half ⇒ after g3 (gap 3 = end of S placed).
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 3, edge: .below, draggedID: 1)
        #expect(t?.toTier == sTier)
        #expect(t?.gap == 3)
        #expect(t?.crossesTier == false)
    }

    // MARK: no-op positions next to the dragged game

    @Test func droppingImmediatelyAboveSelfIsNoOp() {
        #expect(TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 2, edge: .above, draggedID: 2) == nil)
    }

    @Test func droppingImmediatelyBelowSelfIsNoOp() {
        #expect(TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 2, edge: .below, draggedID: 2) == nil)
    }

    @Test func hoveringNeighbourGapOnEitherSideIsNoOp() {
        // g2's own slot is gap 1..2 in S. Lower half of g1 = gap 1 (before g2) = no-op.
        #expect(TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 1, edge: .below, draggedID: 2) == nil)
        // Upper half of g3 = gap 2 (after g2) = no-op.
        #expect(TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 3, edge: .above, draggedID: 2) == nil)
    }

    // MARK: around dividers — above = last of upper, below = first of lower

    @Test func aboveDividerIsLastOfUpperTier() {
        // Drag g1 over A-divider (index 4) upper half ⇒ end of S (gap 3, tier S).
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 4, edge: .above, draggedID: 1)
        #expect(t?.toTier == sTier)
        #expect(t?.gap == 3)
        #expect(t?.crossesTier == false)  // g1 already in S
    }

    @Test func belowDividerIsFirstOfLowerTier() {
        // Drag g1 over A-divider lower half ⇒ first of A (gap 0, tier A) — crosses.
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 4, edge: .below, draggedID: 1)
        #expect(t?.toTier == aTier)
        #expect(t?.gap == 0)
        #expect(t?.crossesTier == true)
        #expect(t?.destinationTierID == aTier)
    }

    @Test func lastGameLowerHalfMatchesAboveDivider() {
        // Lower half of g3 (last of S) resolves to the same gap as above the divider.
        let viaGame = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 3, edge: .below, draggedID: 1)
        let viaDivider = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 4, edge: .above, draggedID: 1)
        #expect(viaGame?.toTier == viaDivider?.toTier)
        #expect(viaGame?.gap == viaDivider?.gap)
    }

    @Test func firstGameUpperHalfMatchesBelowDivider() {
        let viaDivider = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 4, edge: .below, draggedID: 1)
        let viaGame = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 5, edge: .above, draggedID: 1)
        #expect(viaGame?.toTier == viaDivider?.toTier)
        #expect(viaGame?.gap == viaDivider?.gap)
    }

    // MARK: first / last of the whole list

    @Test func topOfListIsFirstOfFirstTier() {
        // Upper half of the S divider (index 0) ⇒ first of S.
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 0, edge: .above, draggedID: 5)
        #expect(t?.toTier == sTier)
        #expect(t?.gap == 0)
        #expect(t?.crossesTier == true)  // g5 is in A
    }

    @Test func endOfListIsAfterLastPlaced() {
        // Lower half of the last (unplaced) A game ⇒ end of A placed (gap 2).
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 7, edge: .below, draggedID: 1)
        #expect(t?.toTier == aTier)
        #expect(t?.gap == 2)
        #expect(t?.crossesTier == true)
    }

    // MARK: crossing into a different tier flags the hint

    @Test func crossTierMoveIsFlagged() {
        // Drag g4 (in A) above g1 (in S) ⇒ into S, crosses.
        let t = TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 1, edge: .above, draggedID: 4)
        #expect(t?.toTier == sTier)
        #expect(t?.crossesTier == true)
        #expect(t?.destinationTierID == sTier)
    }

    @Test func outOfRangeIndexIsNil() {
        #expect(TheTopDropGeometry.resolve(slots: chart(), hoveredIndex: 99, edge: .above, draggedID: 1) == nil)
    }

    @Test func placedCountCountsOnlyPlaced() {
        #expect(TheTopDropGeometry.placedCount(chart(), aTier) == 2)  // g6 unplaced excluded
        #expect(TheTopDropGeometry.placedCount(chart(), sTier) == 3)
    }
}

/// Model glue for the insertion line: target set/cleared, filter disables it, drop
/// applies the same index the line showed, cross-divider drop changes the tier.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TheTopDropModelTests {
    private let sTier = TierInfo.defaults[0]
    private let aTier = TierInfo.defaults[1]

    private func topRow(_ id: Int64, tier: TierInfo, global: Int?) -> TopRow {
        let game = GameSummary(id: id, title: "G\(id)", year: 2000 + Int(id),
                               tierID: tier.id, tierLetter: tier.letter, tierColorHex: tier.colorHex,
                               rankKey: global == nil ? nil : RankKey(id * 1000),
                               played: true, owned: true, platformIDs: ["ps2"])
        return TopRow(game: game, globalPosition: global, derivedPosition: global)
    }

    /// S: g1,g2,g3 placed. A: g4 placed.
    private func backend() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        b.tierList = TierInfo.defaults
        b.topRows = [topRow(1, tier: sTier, global: 1), topRow(2, tier: sTier, global: 2),
                     topRow(3, tier: sTier, global: 3), topRow(4, tier: aTier, global: 4)]
        return b
    }

    /// Flat items order for the S/A chart above:
    /// 0 d(S) · 1 g1 · 2 g2 · 3 g3 · 4 d(A) · 5 g4
    private func started() async -> TheTopModel {
        let m = TheTopModel(backend: backend())
        await m.start()
        return m
    }

    @Test func beginDragCapturesID() async {
        let m = await started()
        m.beginDrag(gameID: 3, sourceTierID: sTier.id)
        #expect(m.draggingID == 3)
    }

    @Test func updateSetsTargetAndInsertionEdge() async {
        let m = await started()
        m.beginDrag(gameID: 3, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 1, edge: .above)   // above g1
        #expect(m.dropTarget?.anchorID == "g1")
        #expect(m.insertionEdge(for: "g1") == .above)
        #expect(m.insertionEdge(for: "g2") == nil)
    }

    @Test func noLineWhileFiltered() async {
        let b = backend()
        let m = TheTopModel(backend: b, filter: LibraryFilter(scope: .platform("ps2")))
        await m.start()
        m.beginDrag(gameID: 3, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 1, edge: .above)
        #expect(m.dropTarget == nil)
    }

    @Test func noLineAtNoOpPosition() async {
        let m = await started()
        m.beginDrag(gameID: 2, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 2, edge: .above)   // directly above itself
        #expect(m.dropTarget == nil)
    }

    @Test func clearOnlyOwningAnchor() async {
        let m = await started()
        m.beginDrag(gameID: 3, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 1, edge: .above)   // anchor g1
        m.clearDropTarget(ownedBy: "g2")                 // different anchor ⇒ keep
        #expect(m.dropTarget?.anchorID == "g1")
        m.clearDropTarget(ownedBy: "g1")                 // owner ⇒ clear
        #expect(m.dropTarget == nil)
    }

    @Test func dropAppliesTheSameIndexTheLineShowed() async {
        let b = backend()
        let m = TheTopModel(backend: b)
        await m.start()
        // Drag g1 to below g3 (end of S). Line = below g3.
        m.beginDrag(gameID: 1, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 3, edge: .below)
        #expect(m.dropTarget?.toTier == sTier.id)
        #expect(m.dropTarget?.gap == 3)
        await m.applyDrop()
        // gap 3 with source removed (was index 0) ⇒ atIndex 2 (planDrop's correction).
        #expect(b.moves.count == 1)
        #expect(b.moves.first?.gameID == 1)
        #expect(b.moves.first?.toTier == sTier.id)
        #expect(b.moves.first?.atIndex == 2)
        #expect(m.draggingID == nil)      // drag ended
        #expect(m.dropTarget == nil)
    }

    @Test func crossDividerDropChangesTier() async {
        let b = backend()
        let m = TheTopModel(backend: b)
        await m.start()
        // Drag g1 (S) below the A divider ⇒ first of A.
        m.beginDrag(gameID: 1, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 4, edge: .below)
        #expect(m.dropTarget?.toTier == aTier.id)
        #expect(m.dropTarget?.crossesTier == true)
        await m.applyDrop()
        #expect(b.moves.first?.toTier == aTier.id)
        #expect(b.moves.first?.atIndex == 0)
    }

    @Test func dropRefusedWhenFiltered() async {
        let b = backend()
        let m = TheTopModel(backend: b, filter: LibraryFilter(scope: .platform("ps2")))
        await m.start()
        m.beginDrag(gameID: 1, sourceTierID: sTier.id)
        // Even if a target were somehow set, applyDrop no-ops when filtered.
        let applied = await m.applyDrop()
        #expect(applied == false)
        #expect(b.moves.isEmpty)
    }

    @Test func crossTierLineTakesDestinationColour() async {
        let m = await started()
        m.beginDrag(gameID: 1, sourceTierID: sTier.id)
        m.updateDropTarget(flatIndex: 4, edge: .below)   // into A
        #expect(m.dropLineColorHex == aTier.colorHex)
        #expect(m.dropLineTierLetter == aTier.letter)
        // Same-tier move ⇒ no colour hint (plain accent line).
        m.updateDropTarget(flatIndex: 3, edge: .below)   // end of S
        #expect(m.dropLineColorHex == nil)
        #expect(m.dropLineTierLetter == nil)
    }
}
