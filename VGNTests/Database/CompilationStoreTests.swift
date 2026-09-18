import Foundation
import Testing
import GRDB
@testable import VGN

/// Data-layer tests for the compilation reads/writes the M3 editor builds on
/// (PLAN §5.1/§8). `@MainActor`-free — the store is `Sendable`.
@Suite struct CompilationStoreTests {

    // Build the MGS Legacy Collection (PS3, 9 members) from IGDB-bundle-shaped drafts.
    private static let mgsLegacyTitles = [
        "Metal Gear Solid", "Metal Gear Solid 2: Sons of Liberty",
        "Metal Gear Solid 3: Snake Eater", "Metal Gear Solid 4: Guns of the Patriots",
        "Metal Gear Solid: Peace Walker", "Metal Gear", "Metal Gear 2: Solid Snake",
        "Metal Gear Solid VR Missions", "Metal Gear Solid: Special Missions",
    ]

    private func makeMGSLegacy(_ store: LibraryStore) async throws -> Int64 {
        let members = Self.mgsLegacyTitles.enumerated().map { i, title in
            CompilationMemberDraft(title: title, igdbID: Int64(1000 + i), position: i)
        }
        let (productID, outcomes) = try await store.addCompilation(
            product: ProductDraft(title: "Metal Gear Solid: The Legacy Collection",
                                  platformID: "ps3", igdbID: 42),
            members: members)
        #expect(outcomes.count == 9)
        return productID
    }

    // MARK: - Members read + sibling titles

    @Test func compilationMembersReadInOrder() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        let members = try await store.compilationMembers(productID: productID)
        #expect(members.count == 9)
        #expect(members.map(\.position) == Array(0..<9))
        #expect(members.first?.title == "Metal Gear Solid")
    }

    @Test func membersAppearIndividuallyAndAreCompilationMembers() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        let members = try await store.compilationMembers(productID: productID)
        for m in members {
            let detail = try #require(try await store.gameDetail(id: m.gameID))
            #expect(detail.owned)                         // owned via the compilation
            #expect(detail.isCompilationMember)
            let copy = try #require(detail.copies.first)
            #expect(copy.isCompilation)
            #expect(copy.memberCount == 9)
            // Every affected game is named on the copy (all-or-nothing UX).
            #expect(copy.memberTitles.count == 9)
            #expect(copy.memberIDs.contains(m.gameID))
        }
    }

    // MARK: - Per-member played/tier are independent

    @Test func perMemberPlayedAndTierAreIndependent() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        let members = try await store.compilationMembers(productID: productID)
        let mgs3 = try #require(members.first { $0.title.contains("Snake Eater") })

        _ = try await store.setPlayed([mgs3.gameID], true)
        _ = try await store.setTier([mgs3.gameID], tierID: 1)   // S

        let reloaded = try await store.compilationMembers(productID: productID)
        let played = reloaded.filter(\.played)
        #expect(played.count == 1)
        #expect(played.first?.gameID == mgs3.gameID)
        #expect(reloaded.first { $0.gameID == mgs3.gameID }?.tierLetter == "S")
        // Others untouched.
        #expect(reloaded.filter { $0.tierLetter != nil }.count == 1)
    }

    // MARK: - All-or-nothing ownership

    @Test func removingCompilationUnownsAllMembers() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        let members = try await store.compilationMembers(productID: productID)
        // Un-owning a never-played compilation orphans every member → wouldOrphan.
        let outcome = try await store.removeProduct(productID)
        guard case let .wouldOrphan(ids) = outcome else {
            Issue.record("expected wouldOrphan, got \(outcome)"); return
        }
        #expect(Set(ids) == Set(members.map(\.gameID)))
        // No change was made (transaction rolled back).
        #expect(try await store.compilationMembers(productID: productID).count == 9)
    }

    @Test func memberOwnedStandaloneStaysOwnedWhenCompilationRemoved() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        let members = try await store.compilationMembers(productID: productID)
        let mgs3 = try #require(members.first { $0.title.contains("Snake Eater") })

        // Also own MGS3 standalone on PS2, and mark it played.
        _ = try await store.addCopy(gameID: mgs3.gameID, platformID: "ps2")
        _ = try await store.setPlayed([mgs3.gameID], true)

        // Removing the compilation would orphan the 8 never-played, not-otherwise-owned members.
        let outcome = try await store.removeProduct(productID, confirmOrphanDelete: true)
        #expect(outcome == .ok)

        // MGS3 survives (still owned on PS2, still played).
        let detail = try #require(try await store.gameDetail(id: mgs3.gameID))
        #expect(detail.owned)
        #expect(detail.played)
        #expect(detail.copies.count == 1)
        #expect(detail.copies.first?.platformID == "ps2")
        #expect(!detail.isCompilationMember)
    }

    // MARK: - Editor writes: add / reuse / remove / reorder / convert

    @Test func addMemberReusesExistingLibraryGame() async throws {
        let store = try await TestDB.makeStore()
        // An existing standalone game (played) that we later add to a compilation.
        let existing = try await store.addGame(
            GameDraft(title: "Ico", igdbID: 555, platformIDs: ["ps2"], owned: true, played: true))

        let productID = try await store.groupAsCompilation(
            gameIDs: [], title: "The ICO & Shadow of the Colossus Collection",
            platformID: "ps3", mergeExistingSingles: false)
        // Add SotC as a fresh member and Ico by reusing the existing game (igdb dedupe).
        _ = try await store.addCompilationMember(
            productID: productID,
            CompilationMemberDraft(title: "Shadow of the Colossus", igdbID: 556, position: 0))
        let reuse = try await store.addCompilationMember(
            productID: productID,
            CompilationMemberDraft(title: "Ico", igdbID: 555, position: 1))
        if case .addedCopy = reuse {} else { Issue.record("expected reuse of existing game") }

        let members = try await store.compilationMembers(productID: productID)
        #expect(members.count == 2)
        #expect(members.contains { $0.gameID == existing.gameID })
        // Ico is still played (reused, not duplicated) and now a compilation member.
        let ico = try #require(try await store.gameDetail(id: existing.gameID))
        #expect(ico.played)
        #expect(ico.isCompilationMember)
    }

    @Test func removeMemberOrphanPromptThenReorder() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        let members = try await store.compilationMembers(productID: productID)
        let victim = members[3]

        // Never-played, not-otherwise-owned member → wouldOrphan, no change.
        let outcome = try await store.removeCompilationMember(productID: productID, gameID: victim.gameID)
        #expect(outcome == .wouldOrphan([victim.gameID]))
        #expect(try await store.compilationMembers(productID: productID).count == 9)

        // Confirm removal.
        let confirmed = try await store.removeCompilationMember(
            productID: productID, gameID: victim.gameID, confirmOrphanDelete: true)
        #expect(confirmed == .ok)
        let after = try await store.compilationMembers(productID: productID)
        #expect(after.count == 8)

        // Reorder: reverse the surviving members.
        let reversed = after.map(\.gameID).reversed().map { $0 }
        try await store.reorderCompilationMembers(productID: productID, orderedGameIDs: reversed)
        let reordered = try await store.compilationMembers(productID: productID)
        #expect(reordered.map(\.gameID) == reversed)
    }

    @Test func convertSingleToCompilationAndBack() async throws {
        let store = try await TestDB.makeStore()
        // A plain single copy.
        let game = try await store.addGame(
            GameDraft(title: "Jak and Daxter", igdbID: 700, platformIDs: ["ps2"], owned: true))
        let detail0 = try #require(try await store.gameDetail(id: game.gameID))
        let productID = try #require(detail0.copies.first?.productID)
        #expect(detail0.copies.first?.kind == .single)

        // Adding a second member → converts to a compilation.
        _ = try await store.addCompilationMember(
            productID: productID,
            CompilationMemberDraft(title: "Jak II", igdbID: 701, position: 1))
        let product1 = try #require(try await store.compilationProduct(id: productID))
        #expect(product1.kind == .compilation)
        #expect(product1.members.count == 2)

        // Removing back down to 1 member → converts back to a single.
        let members = product1.members
        let second = try #require(members.first { $0.title == "Jak II" })
        _ = try await store.removeCompilationMember(
            productID: productID, gameID: second.gameID, confirmOrphanDelete: true)
        let product2 = try #require(try await store.compilationProduct(id: productID))
        #expect(product2.kind == .single)
        #expect(product2.members.count == 1)
    }

    // MARK: - Group as compilation from a selection

    @Test func groupAsCompilationMergesExistingSingles() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "Ico", igdbID: 1, platformIDs: ["ps3"], owned: true))
        let b = try await store.addGame(GameDraft(title: "Shadow of the Colossus", igdbID: 2,
                                                  platformIDs: ["ps3"], owned: true))
        // Each currently has its own single product on PS3.
        #expect(try await store.gameDetail(id: a.gameID)?.copies.count == 1)

        let productID = try await store.groupAsCompilation(
            gameIDs: [a.gameID, b.gameID],
            title: "The ICO & Shadow of the Colossus Collection",
            platformID: "ps3", mergeExistingSingles: true)

        let members = try await store.compilationMembers(productID: productID)
        #expect(members.count == 2)
        // Each game now has exactly one copy: the compilation (single merged in).
        for id in [a.gameID, b.gameID] {
            let detail = try #require(try await store.gameDetail(id: id))
            #expect(detail.copies.count == 1)
            #expect(detail.copies.first?.isCompilation == true)
            #expect(detail.owned)
        }
    }

    @Test func groupAsCompilationKeepsSinglesWhenNotMerging() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "Ico", igdbID: 1, platformIDs: ["ps3"], owned: true))
        let b = try await store.addGame(GameDraft(title: "SotC", igdbID: 2, platformIDs: ["ps3"], owned: true))
        let productID = try await store.groupAsCompilation(
            gameIDs: [a.gameID, b.gameID], title: "Collection",
            platformID: "ps3", mergeExistingSingles: false)
        _ = productID
        // Each keeps both the single and the compilation copy.
        #expect(try await store.gameDetail(id: a.gameID)?.copies.count == 2)
    }

    // MARK: - Edit product details

    @Test func updateProductDetailsAppliesPlatformAndFormat() async throws {
        let store = try await TestDB.makeStore()
        let productID = try await makeMGSLegacy(store)
        try await store.updateProductDetails(productID: productID, platformID: "ps2",
                                             format: .digital, edition: .some("Special"))
        let product = try #require(try await store.compilationProduct(id: productID))
        #expect(product.platformID == "ps2")
        #expect(product.format == .digital)
        #expect(product.edition == "Special")
        // Members now count for the new platform.
        for m in product.members {
            let detail = try #require(try await store.gameDetail(id: m.gameID))
            #expect(detail.platformIDs.contains("ps2"))
        }
    }
}
