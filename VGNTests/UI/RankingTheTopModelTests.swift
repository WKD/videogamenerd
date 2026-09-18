import Testing
@testable import VGN

/// The Top model tests (PLAN §7): sectioning (dividers, podium buckets, unplaced
/// placement), derived vs global numbering under a filter, drag-disabled-when-
/// filtered, cross-divider move changes tier, and CSV escaping + content. Driven
/// against ``ScriptedRankingBackend`` — no database.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RankingTheTopModelTests {

    private let sTier = TierInfo.defaults[0]
    private let aTier = TierInfo.defaults[1]

    private func topRow(_ id: Int64, tier: TierInfo, global: Int?, derived: Int?) -> TopRow {
        let game = GameSummary(id: id, title: "G\(id)", year: 2000 + Int(id),
                               tierID: tier.id, tierLetter: tier.letter, tierColorHex: tier.colorHex,
                               rankKey: global == nil ? nil : RankKey(id * 1000),
                               played: true, owned: true, platformIDs: ["ps2"])
        return TopRow(game: game, globalPosition: global, derivedPosition: derived)
    }

    /// 12 placed in S, 1 placed + 1 unplaced in A.
    private func unfilteredBackend() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        b.tierList = TierInfo.defaults
        var rows: [TopRow] = []
        for i in 1...12 { rows.append(topRow(Int64(i), tier: sTier, global: i, derived: i)) }
        rows.append(topRow(13, tier: aTier, global: 13, derived: 13))
        rows.append(topRow(14, tier: aTier, global: nil, derived: nil))   // unplaced tail
        b.topRows = rows
        return b
    }

    // MARK: Sectioning

    @Test func dividersOpenEachTierAndPodiumBucketsAreAssigned() async {
        let m = TheTopModel(backend: unfilteredBackend())
        await m.start()
        let items = m.items

        // First item is the S divider with 12 placed games.
        guard case let .divider(sDiv) = items.first else { Issue.record("missing S divider"); return }
        #expect(sDiv.tier.id == sTier.id)
        #expect(sDiv.placedCount == 12)

        // Podium buckets by global sequence: 1–3 top3, 4–10 top10, 11+ compact.
        func bucket(ofGame id: Int64) -> PodiumBucket? {
            for case let .game(row) in items where row.id == id { return row.bucket }
            return nil
        }
        #expect(bucket(ofGame: 1) == .top3)
        #expect(bucket(ofGame: 3) == .top3)
        #expect(bucket(ofGame: 4) == .top10)
        #expect(bucket(ofGame: 10) == .top10)
        #expect(bucket(ofGame: 11) == .compact)
        #expect(bucket(ofGame: 14) == .unplaced)

        // The A divider appears before the A games.
        let dividerTiers = items.compactMap { if case let .divider(d) = $0 { return d.tier.id } else { return nil } }
        #expect(dividerTiers == [sTier.id, aTier.id])
    }

    @Test func unplacedRowIsUnnumberedAtTierEnd() async {
        let m = TheTopModel(backend: unfilteredBackend())
        await m.start()
        let unplaced = m.items.compactMap { item -> TopGameRow? in
            if case let .game(row) = item, row.id == 14 { return row }
            return nil
        }.first
        #expect(unplaced?.displayRank == nil)
        #expect(unplaced?.bucket == .unplaced)
    }

    // MARK: Derived vs global numbering under a filter

    @Test func filteredNumberingUsesDerivedWithGlobalSecondary() async {
        let b = ScriptedRankingBackend()
        b.tierList = TierInfo.defaults
        b.topRows = [topRow(3, tier: sTier, global: 3, derived: 1),
                     topRow(7, tier: sTier, global: 7, derived: 2)]
        let m = TheTopModel(backend: b, filter: LibraryFilter(scope: .platform("ps2")))
        await m.start()
        #expect(m.filterActive)
        let rows = m.items.compactMap { if case let .game(r) = $0 { return r } else { return nil } }
        #expect(rows[0].displayRank == 1)          // derived
        #expect(rows[0].overallRank == 3)          // global secondary
        #expect(rows[1].displayRank == 2)
        #expect(rows[1].overallRank == 7)
    }

    @Test func unfilteredNumberingUsesGlobalWithNoSecondary() async {
        let m = TheTopModel(backend: unfilteredBackend())
        await m.start()
        let first = m.items.compactMap { if case let .game(r) = $0 { return r } else { return nil } }.first
        #expect(first?.displayRank == 1)
        #expect(first?.overallRank == nil)
    }

    // MARK: Reorder — disabled when filtered, cross-divider changes tier

    @Test func reorderIsDisabledWhenFiltered() async {
        let b = unfilteredBackend()
        let m = TheTopModel(backend: b, filter: LibraryFilter(scope: .platform("ps2")))
        await m.start()
        await m.reorder(gameID: 1, toTier: aTier.id, gap: 0)
        #expect(b.moves.isEmpty)
    }

    @Test func crossDividerReorderChangesTier() async {
        let b = ScriptedRankingBackend()
        b.tierList = TierInfo.defaults
        b.topRows = [topRow(1, tier: sTier, global: 1, derived: 1),
                     topRow(2, tier: sTier, global: 2, derived: 2),
                     topRow(3, tier: aTier, global: 3, derived: 3)]
        let m = TheTopModel(backend: b)   // unfiltered
        await m.start()
        // Move game 1 into A at the top → its tier changes to A.
        await m.reorder(gameID: 1, toTier: aTier.id, gap: 0)
        #expect(b.moves.count == 1)
        #expect(b.moves.first?.gameID == 1)
        #expect(b.moves.first?.toTier == aTier.id)
        #expect(b.moves.first?.atIndex == 0)
    }

    // MARK: CSV

    @Test func csvEscapesAndFormats() {
        let tricky = GameSummary(id: 1, title: "Zelda: Link, \"Awakening\"", year: 1993,
                                 tierID: sTier.id, tierLetter: "S", tierColorHex: sTier.colorHex,
                                 rankKey: 1000, played: true, owned: true, platformIDs: ["snes", "ps2"])
        let rows = [TopRow(game: tricky, globalPosition: 1, derivedPosition: 1)]
        let scores: [Int64: DerivedScoreValue] = [1: DerivedScoreValue(value: 9.63, isApproximate: false)]
        let csv = TheTopModel.csv(rows: rows, tiers: TierInfo.defaults, scores: scores,
                                  playtime: [1: 3600], filterActive: false)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("\u{FEFF}rank,derived rank,score,title,year,platforms,tier,playtime"))
        // The comma/quote title is wrapped and its quotes doubled.
        #expect(lines[1].contains("\"Zelda: Link, \"\"Awakening\"\"\""))
        #expect(lines[1].contains("9.6"))     // score, dot decimal
        #expect(lines[1].contains("1.0h"))    // 3600s → 1.0h
        #expect(lines[1].contains("SNES PS2"))
    }

    @Test func csvDerivedColumnFollowsFilter() {
        let game = GameSummary(id: 5, title: "Ico", tierID: sTier.id, tierLetter: "S",
                               rankKey: 1000, played: true)
        let rows = [TopRow(game: game, globalPosition: 41, derivedPosition: 3)]
        let filtered = TheTopModel.csv(rows: rows, tiers: TierInfo.defaults, scores: [:],
                                       playtime: [:], filterActive: true)
        #expect(filtered.components(separatedBy: "\r\n")[1].hasPrefix("41,3,"))
        let unfiltered = TheTopModel.csv(rows: rows, tiers: TierInfo.defaults, scores: [:],
                                         playtime: [:], filterActive: false)
        #expect(unfiltered.components(separatedBy: "\r\n")[1].hasPrefix("41,41,"))
    }
}
