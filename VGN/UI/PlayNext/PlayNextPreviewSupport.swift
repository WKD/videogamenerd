#if DEBUG
import Foundation

/// A hand-driven ``PlayNextBackend`` for SwiftUI previews **and** the model unit
/// tests: every output is settable, every call recorded, and a delay + per-call
/// handler let a test exercise latest-wins recompute — all with no database.
///
/// `@unchecked Sendable`: only ever touched from the `@MainActor` model / test.
final class ScriptedPlayNextBackend: PlayNextBackend, @unchecked Sendable {
    var result: PlayNextResult
    var backtestResult = TasteBacktestResult(spearman: 0.62, sampleCount: 47, verdict: .good)
    var exemplars: [Int64: ExemplarInfo] = [:]
    var signature = RecommendationInputsSignature(ranked: 47, owned: 30, traits: 120,
                                                  feedback: 0, latestUpdate: 0)
    /// Signatures the live stream will emit (default: none, so it finishes at once).
    var signals: [RecommendationInputsSignature] = []
    /// Artificial delay before `recommend` returns (for latest-wins tests).
    var recommendDelay: Duration = .zero
    /// Overrides `result` per call; receives the bracket + options.
    var recommendHandler: ((TimeBracket, RecommendationOptions) -> PlayNextResult)?
    var secondOpinionRequestValue: SecondOpinionRequest?

    private(set) var recommendCalls: [(bracket: TimeBracket, options: RecommendationOptions)] = []
    private(set) var snoozed: [Int64] = []
    private(set) var nevered: [Int64] = []
    private(set) var startedPlaying: [Int64] = []
    private(set) var undone: [StartPlayingUndo] = []
    private(set) var backtestCalls = 0
    /// The outcome `undoStartPlaying` reports (default: a clean restore).
    var undoOutcome: StartPlayingUndoOutcome = .restored
    private var nextFeedbackID: Int64 = 1

    init(result: PlayNextResult) { self.result = result }

    func recommend(bracket: TimeBracket, options: RecommendationOptions) async throws -> PlayNextResult {
        if recommendDelay > .zero { try? await Task.sleep(for: recommendDelay) }
        recommendCalls.append((bracket, options))
        return recommendHandler?(bracket, options) ?? result
    }
    func backtest() async throws -> TasteBacktestResult { backtestCalls += 1; return backtestResult }
    func snooze(gameID: Int64) async throws { snoozed.append(gameID) }
    func never(gameID: Int64) async throws { nevered.append(gameID) }
    func startPlaying(gameID: Int64) async throws -> StartPlayingUndo {
        startedPlaying.append(gameID)
        defer { nextFeedbackID += 1 }
        return StartPlayingUndo(gameID: gameID, previousStatus: nil, previousPlayed: false,
                                previousRevisit: false, previousUpdatedAt: nil,
                                pickedFeedbackID: nextFeedbackID)
    }
    func undoStartPlaying(_ undo: StartPlayingUndo) async throws -> StartPlayingUndoOutcome {
        undone.append(undo)
        return undoOutcome
    }
    func secondOpinionRequest(for result: PlayNextResult) async throws -> SecondOpinionRequest {
        secondOpinionRequestValue ?? PlayNextSamples.request(for: result)
    }
    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo] {
        exemplars.filter { ids.contains($0.key) }
    }
    func inputsSignatureOnce() async throws -> RecommendationInputsSignature { signature }
    func inputsChangedStream() -> AsyncStream<RecommendationInputsSignature> {
        let signals = self.signals
        return AsyncStream { continuation in
            for s in signals { continuation.yield(s) }
            continuation.finish()
        }
    }
}

// MARK: - Sample data

/// Sample results + models for the Play Next previews and tests.
enum PlayNextSamples {

    static func suggestion(
        _ id: Int64, _ title: String, year: Int? = 2022,
        platforms: [String] = ["ps5"], formats: [ProductFormat] = [.digital],
        status: PlayStatus? = nil, estimate: Int? = 190_800, full: Int? = nil,
        score: Double = 0.8, strength: MatchStrength = .strong,
        reasons: [PlayNextReason], hasMetadata: Bool = true, igdbID: Int64? = nil
    ) -> PlayNextSuggestion {
        PlayNextSuggestion(
            id: id, title: title, year: year, coverFile: nil,
            platformIDs: platforms, formats: formats, status: status,
            estimateSeconds: estimate, fullEstimateSeconds: full ?? estimate,
            score: score, matchStrength: strength, reasons: reasons, hasMetadata: hasMetadata,
            igdbID: igdbID)
    }

    static let exemplars: [Int64: ExemplarInfo] = [
        1: ExemplarInfo(title: "Bloodborne", tierLetter: "S"),
        2: ExemplarInfo(title: "The Last of Us", tierLetter: "A"),
    ]

    /// A rich long-haul result: hero + four alternatives + an unknown-length lane.
    static func richResult() -> PlayNextResult {
        let hero = suggestion(200, "Elden Ring", platforms: ["ps5"], formats: [.digital],
                              estimate: 190_800, score: 0.94, strength: .strong,
                              reasons: [.sameDeveloper(name: "FromSoftware", exemplar: 1),
                                        .similarTo(1),
                                        .fitsBracket(estimateSeconds: 190_800, bracket: TimeBracket(shelf: .epic))])
        let alts = [
            suggestion(201, "Hollow Knight", year: 2017, platforms: ["pc"], formats: [.digital],
                       estimate: 162_000, score: 0.72, strength: .fair,
                       reasons: [.traitAffinity(kind: .genre, value: "Metroidvania", lift: 0.31),
                                 .crowdRated(rating: 90, count: 5200)]),
            suggestion(202, "Sekiro", year: 2019, platforms: ["ps4"], formats: [.physical],
                       status: .playing, estimate: 43_200, full: 129_600, score: 0.68, strength: .fair,
                       reasons: [.remainingTime(remainingSeconds: 43_200),
                                 .sameDeveloper(name: "FromSoftware", exemplar: 1)]),
            suggestion(203, "Chrono Trigger", year: 1995, platforms: ["snes"], formats: [.rom],
                       estimate: 90_000, score: 0.55, strength: .weak,
                       reasons: [.crowdRated(rating: 92, count: 800), .weakEvidence]),
            suggestion(204, "Obscure Homebrew", year: nil, platforms: ["pc"], formats: [.rom],
                       estimate: 21_600, score: 0.4, strength: .weak,
                       reasons: [.noMetadata], hasMetadata: false),
        ]
        let unknown = [
            suggestion(205, "Some Roguelike", year: 2020, platforms: ["pc"], formats: [.digital],
                       estimate: nil, score: 0.5, strength: .fair,
                       reasons: [.traitAffinity(kind: .genre, value: "Roguelike", lift: 0.2)]),
        ]
        var exclusions = RecommendationExclusions()
        exclusions.byTime = 12
        exclusions.byFeedback = 3
        exclusions.unknownLength = 1
        return PlayNextResult(hero: hero, alternatives: alts, unknownLength: unknown,
                              exclusions: exclusions, bracket: TimeBracket(shelf: .epic))
    }

    /// Nothing fits the chosen bracket (all excluded by time).
    static func nothingFitsResult() -> PlayNextResult {
        var exclusions = RecommendationExclusions()
        exclusions.byTime = 8
        return PlayNextResult(hero: nil, alternatives: [], unknownLength: [],
                              exclusions: exclusions, bracket: TimeBracket(shelf: .evening))
    }

    /// No owned, unfinished games at all.
    static func emptyResult() -> PlayNextResult {
        PlayNextResult(hero: nil, alternatives: [], unknownLength: [],
                       exclusions: RecommendationExclusions(), bracket: TimeBracket(shelf: .weekend))
    }

    static func request(for result: PlayNextResult) -> SecondOpinionRequest {
        SecondOpinionRequest(
            bracket: result.bracket.label,
            completionist: result.bracket.completionist,
            topRanked: [.init(title: "Bloodborne", tier: "S", globalPosition: 1),
                        .init(title: "The Last of Us", tier: "A", globalPosition: 2)],
            didntClick: [.init(title: "Heavy Rain", tier: "F")],
            shortlist: result.shortlist.enumerated().map { i, s in
                .init(id: s.id, title: s.title, platform: s.platformIDs.first,
                      format: s.formats.first?.rawValue,
                      estimateHours: s.estimateSeconds.map { Double($0) / 3600 },
                      status: s.status?.rawValue, engineRank: i + 1)
            },
            engineOrdering: result.shortlist.map(\.id))
    }

    // MARK: - Preview model builders

    /// An ephemeral defaults suite so previews don't touch the real preferences.
    static func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "playnext.preview.\(UUID().uuidString)") ?? .standard
    }

    static func backend(_ result: PlayNextResult, exemplars: [Int64: ExemplarInfo] = exemplars) -> ScriptedPlayNextBackend {
        let b = ScriptedPlayNextBackend(result: result)
        b.exemplars = exemplars
        return b
    }

    @MainActor
    static func model(
        result: PlayNextResult,
        backtest: TasteBacktestResult = TasteBacktestResult(spearman: 0.62, sampleCount: 47, verdict: .good),
        ranked: Int = 47,
        secondOpinion: any SecondOpinionProviding = StubSecondOpinionProvider()
    ) -> PlayNextModel {
        let b = backend(result)
        b.backtestResult = backtest
        b.signature = RecommendationInputsSignature(ranked: ranked, owned: 30, traits: 120,
                                                    feedback: 0, latestUpdate: 0)
        return PlayNextModel(backend: b, secondOpinion: secondOpinion,
                             defaults: ephemeralDefaults(), recomputeDebounce: .milliseconds(1))
    }
}
#endif
