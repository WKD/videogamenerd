import Foundation
import Testing
@testable import VGN

/// "Ask Claude" for "From the vault" (PLAN §7b, scheduled 2026-09-25): the request builder and
/// the vault prompt variant. Pure — no process, no network; the provider test uses the in-memory
/// ``FakeClaudeRunner`` (never the real `claude` CLI).
@Suite struct SecondOpinionVaultPromptTests {

    private static let taste = SecondOpinionTaste(
        topRanked: [.init(title: "Bloodborne", tier: "S", globalPosition: 1),
                    .init(title: "Super Metroid", tier: "A", globalPosition: 2)],
        didntClick: [.init(title: "Heavy Rain", tier: "F")])

    /// A matched PS Plus claim, an unmatched Batocera ROM, an owned GOG game.
    private static func shortlist() -> [RomCatalogEntry] {
        var claim = RomCatalogEntry.makePSNVault(externalID: "ent:1", platform: "ps5",
                                                 name: "Returnal", coverURL: nil, membership: "ps_plus")
        claim.id = 40
        claim.igdbID = 111
        claim.matchState = .matched
        claim.releaseYear = 2021
        claim.igdbRating = 86.4
        claim.lengthMainSeconds = 20 * 3600
        claim.lengthCompleteSeconds = 40 * 3600
        claim.traitsJSON = RomCatalogEntry.encodeTraits([
            GameTrait(kind: .genre, value: "Shooter"), GameTrait(kind: .theme, value: "Science fiction"),
            GameTrait(kind: .keyword, value: "roguelite")])
        let rom = RomCatalogEntry(id: 12, source: "batocera", system: "snes", platformID: "snes",
                                  relativePath: "./Chrono Trigger (USA).zip", name: "Chrono Trigger",
                                  genre: "RPG", releaseYear: 1995)
        var gog = RomCatalogEntry(id: 77, source: "gog", system: "pc", platformID: "pc",
                                  relativePath: "gog:9", name: "Owlboy")
        gog.owned = true
        gog.igdbID = 222
        gog.matchState = .matched
        return [rom, claim, gog]
    }

    private static let bracket = TimeBracket(shelf: .weekend)

    @Test func builderSendsCatalogueFactsOnlyForMatchedEntries() {
        let req = DiscoverSecondOpinion.request(
            shortlist: Self.shortlist(), taste: Self.taste, bracket: Self.bracket,
            playStyle: .default, psPlusMonthsLeft: 3.6)
        #expect(req.kind == .vault)
        #expect(req.engineOrdering == [12, 40, 77])
        #expect(req.topRanked == Self.taste.topRanked)
        #expect(req.didntClick == Self.taste.didntClick)
        #expect(req.bracket == Self.bracket.label)

        let rom = req.shortlist[0]
        #expect(rom.known == false)                 // unmatched ROM: title + system only
        #expect(rom.title == "Chrono Trigger")
        #expect(rom.platform == "SNES" || rom.platform == PlatformLabels.short("snes"))
        #expect(rom.genres == nil && rom.year == nil && rom.estimateHours == nil && rom.vaultSource == nil)

        let claim = req.shortlist[1]
        #expect(claim.known == true)
        #expect(claim.vaultSource == "PS Plus claim")
        #expect(claim.genres == ["Shooter"])
        #expect(claim.themes == ["Science fiction"])
        #expect(claim.year == 2021)
        #expect(claim.rating == 86.4)
        #expect(claim.leavesPSPlusInMonths == 4)
        #expect(claim.estimateHours != nil)
        #expect(claim.engineRank == 2)

        let gog = req.shortlist[2]
        #expect(gog.vaultSource == "owned, not in backlog")
        #expect(gog.leavesPSPlusInMonths == nil)    // owned, never a claim
    }

    @Test func vaultPromptSaysWhatIsSentAndNothingMore() {
        let req = DiscoverSecondOpinion.request(
            shortlist: Self.shortlist(), taste: Self.taste, bracket: Self.bracket,
            playStyle: .default, psPlusMonthsLeft: 3.6)
        let prompt = SecondOpinionPrompt.build(for: req)
        #expect(prompt.contains("vault"))
        #expect(prompt.contains("NEVER add ids"))
        #expect(prompt.contains("If you do not recognise one of those games"))
        #expect(prompt.contains("1. Bloodborne [S]"))
        #expect(prompt.contains("- Heavy Rain [F]"))
        #expect(prompt.contains("TIME BUDGET: \(Self.bracket.label)"))
        #expect(prompt.contains("id 12: Chrono Trigger — \(PlatformLabels.short("snes")) (title and system only) (engine rank 1)"))
        #expect(prompt.contains("id 40: Returnal — \(PlatformLabels.short("ps5")), PS Plus claim, leaves with PS Plus in 4 months, 2021, genres: Shooter, themes: Science fiction, IGDB rating 86"))
        #expect(prompt.contains("id 77: Owlboy — \(PlatformLabels.short("pc")), owned, not in backlog"))
        // The unmatched ROM's gamelist genre / year never leave the app.
        #expect(!prompt.contains("RPG"))
        #expect(!prompt.contains("1995"))
        // Keywords are not listed (genres/themes only).
        #expect(!prompt.contains("roguelite"))
        #expect(prompt.contains("The engine's current order (best first) is: 12, 40, 77."))
    }

    @Test func noUnknownInstructionWhenEverythingIsMatched() {
        let matched = Array(Self.shortlist().dropFirst())
        let req = DiscoverSecondOpinion.request(
            shortlist: matched, taste: .empty, bracket: nil, playStyle: .default, psPlusMonthsLeft: nil)
        let prompt = SecondOpinionPrompt.build(for: req)
        #expect(!prompt.contains("If you do not recognise"))
        #expect(!prompt.contains("leaves with PS Plus"))   // no date set
        #expect(prompt.contains("TIME BUDGET: Any length"))
    }

    /// The regular prompt is untouched by the vault variant (no vault fields leak in).
    @Test func regularPromptUnchanged() {
        let req = SecondOpinionRequest(
            bracket: "A Weekend", completionist: false,
            topRanked: [.init(title: "Bloodborne", tier: "S", globalPosition: 1)], didntClick: [],
            shortlist: [.init(id: 5, title: "Hades", platform: "pc", format: "digital",
                              estimateHours: 20, status: nil, engineRank: 1)],
            engineOrdering: [5])
        let prompt = SecondOpinionPrompt.build(for: req)
        #expect(prompt.hasPrefix("You are helping a player decide which game from their own backlog"))
        #expect(prompt.contains("  id 5: Hades — pc, ≈ 20 h (engine rank 1)"))
        #expect(!prompt.contains("vault"))
    }

    /// Same response schema; ids outside the vault shortlist are discarded; no tools.
    @Test func providerDiscardsIDsOutsideTheVaultShortlist() async throws {
        let runner = FakeClaudeRunner()
        runner.structuredJSON = """
        {"picks":[{"id":999,"reason":"Invented."},{"id":40,"reason":"Tight runs.","caveat":"Hard"},
                  {"id":12,"reason":"I know this one."}]}
        """
        let provider = ClaudeSecondOpinionProvider(runner: runner)
        let req = DiscoverSecondOpinion.request(
            shortlist: Self.shortlist(), taste: Self.taste, bracket: Self.bracket,
            playStyle: .default, psPlusMonthsLeft: nil)
        let opinion = try await provider.secondOpinion(for: req)
        #expect(opinion.picks.map(\.gameID) == [40, 12])
        #expect(opinion.picks.first?.caveat == "Hard")
        #expect(runner.lastSchema == SecondOpinionPrompt.schema)
        #expect(runner.lastAllowedTools.isEmpty)
        #expect(runner.lastPrompt?.contains("VAULT CANDIDATES") == true)
    }
}
