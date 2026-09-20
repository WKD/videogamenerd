import Foundation
import Testing
@testable import VGN

/// The PS Plus deadline wiring (PLAN §16): the Settings picker state (persist / clear / past
/// hint), and the deadline + pace threading into both scorers' options — the regular picks
/// (``PlayNextModel``) and "From the vault" (``DiscoverModel``). All model tests; no click on a
/// menu-style picker (they are model-tested here).
@MainActor
@Suite(.serialized)
struct VaultDeadlineTests {

    private func ephemeral() -> UserDefaults {
        UserDefaults(suiteName: "vault.deadline.\(UUID().uuidString)")!
    }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14

    private func psnModel(_ defaults: UserDefaults) throws -> PSNAccountModel {
        let db = try AppDatabase.inMemory()
        let backend = FakeImportBackend(
            source: ImportSourceID.psn, sourceLabel: "PlayStation",
            dataSets: [], staging: ImportStagingStore(db), session: false)
        let model = PSNAccountModel(backend: backend, login: nil,
                                    deadline: PSPlusDeadlinePreferences(defaults: defaults))
        model.now = { self.now }
        return model
    }

    // MARK: - Settings picker

    @Test func deadlineDefaultsOffAndPersistsWhenEnabled() throws {
        let defaults = ephemeral()
        let model = try psnModel(defaults)
        #expect(!model.planningToLeavePSPlus)
        #expect(PSPlusDeadlinePreferences(defaults: defaults).picked == nil)

        model.planningToLeavePSPlus = true
        model.deadlineYear = 2027
        model.deadlineMonth = 6
        let picked = PSPlusDeadlinePreferences(defaults: defaults).picked
        #expect(picked?.year == 2027)
        #expect(picked?.month == 6)

        // A fresh model seeds its pickers from the stored date.
        let reopened = try psnModel(defaults)
        #expect(reopened.planningToLeavePSPlus)
        #expect(reopened.deadlineYear == 2027)
        #expect(reopened.deadlineMonth == 6)
    }

    @Test func clearingRemovesEveryEffect() throws {
        let defaults = ephemeral()
        let model = try psnModel(defaults)
        model.planningToLeavePSPlus = true
        model.deadlineYear = 2027
        model.deadlineMonth = 6
        #expect(PSPlusDeadlinePreferences(defaults: defaults).picked != nil)

        model.clearDeadline()
        #expect(!model.planningToLeavePSPlus)
        #expect(PSPlusDeadlinePreferences(defaults: defaults).picked == nil)
        #expect(PSPlusDeadlinePreferences(defaults: defaults).monthsLeft(now: now) == nil)
    }

    @Test func pastDateShowsHintAndFallsBackForScoring() throws {
        let defaults = ephemeral()
        let model = try psnModel(defaults)
        model.planningToLeavePSPlus = true
        model.deadlineYear = 2020            // well before `now` (2023)
        model.deadlineMonth = 1
        #expect(model.deadlinePastHint != nil)
        // A past date scores as "no active deadline" (nil ⇒ constant fallback), not a ramp.
        #expect(PSPlusDeadlinePreferences(defaults: defaults).monthsLeft(now: now) == nil)

        // A future date is active.
        model.deadlineYear = 2027
        #expect(model.deadlinePastHint == nil)
        #expect((PSPlusDeadlinePreferences(defaults: defaults).monthsLeft(now: now) ?? 0) > 0)
    }

    // MARK: - Play Next options threading

    @Test func playNextOptionsCarryDeadlineAndPace() {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let pace = PlayPace(hoursPerWeek: 10)
        let model = PlayNextModel(
            backend: backend, secondOpinion: StubSecondOpinionProvider(),
            defaults: ephemeral(), pace: pace,
            deadlineMonthsLeft: { 5 }, recomputeDebounce: .milliseconds(1))
        #expect(model.options.psPlusMonthsLeft == 5)
        #expect(model.options.psPlusPace == pace)
        // "Prioritise PS Plus games" is on by default in the UI.
        #expect(model.preferExpiringSubscription)
        #expect(model.options.preferExpiringSubscription)
    }

    @Test func playNextNoDateLeavesRampUnset() {
        let model = PlayNextModel(
            backend: ScriptedPlayNextBackend(result: PlayNextSamples.richResult()),
            secondOpinion: StubSecondOpinionProvider(), defaults: ephemeral(),
            deadlineMonthsLeft: { nil }, recomputeDebounce: .milliseconds(1))
        #expect(model.options.psPlusMonthsLeft == nil)
    }

    // MARK: - "From the vault" options threading

    @Test(.timeLimit(.minutes(1)))
    func vaultRowThreadsDeadlineIntoReasons() async {
        var matched = RomCatalogEntry.makePSNVault(externalID: "ent:1", platform: "ps5",
                                                   name: "Bloodborne", coverURL: nil, membership: "ps_plus")
        matched.id = 100
        matched.matchState = .matched
        matched.traitsJSON = RomCatalogEntry.encodeTraits([GameTrait(kind: .genre, value: "Platform")])
        let ranked = (1...10).map { RankedGame(id: Int64($0), score: 0.8,
                                               traits: [GameTrait(kind: .genre, value: "Platform")]) }
        let backend = FakeDiscoverBackend(ranked: ranked, pool: [matched])
        let model = DiscoverModel(backend: backend, cardCount: 10,
                                  prioritisePSPlus: true, deadlineMonthsLeft: { 2 })
        model.load()
        await waitUntil { model.hasLoaded && !model.items.isEmpty }
        let item = model.items.first { $0.entry.name == "Bloodborne" }
        #expect(item != nil)
        // The deadline reason ("~2 months left") threaded through to the card.
        #expect(item?.sentences.contains { $0.contains("months left") } == true)
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async {
        let start = ContinuousClock.now
        while !cond() {
            if ContinuousClock.now - start > timeout { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
