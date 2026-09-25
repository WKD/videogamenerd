import Foundation

/// Whether a HowLongToBeat run **fills gaps** (only empty `ttb_*` fields, PLAN §5.3
/// "Fetch Missing Time Estimates…") or **replaces** all three times when HLTB has the
/// game (PLAN §5.3 "Refresh Time Estimates from HowLongToBeat…", the suspicious-estimate
/// repair). One code path, two write methods — the client, pacing, cap, matcher and
/// stop-on-first-unexpected-response are shared.
enum HLTBWriteMode: Sendable, Equatable {
    case fillGaps
    case replace
}

/// A game the bulk run could not match confidently — offered for a one-by-one pick
/// after the pass (PLAN §5.3). Carries the game's effective platforms so the picker can
/// emphasise the overlapping candidate platforms (D2b/D6).
struct HLTBAmbiguousGame: Sendable, Hashable, Identifiable {
    var gameID: Int64
    var title: String
    var year: Int?
    var candidates: [HLTBCandidate]
    var librarySlugs: [String] = []
    var id: Int64 { gameID }
}

/// A single-game pick request — the inspector's "Fetch from HowLongToBeat" produced
/// several plausible matches, so the user chooses one (PLAN §5.3).
struct HLTBPickerRequest: Identifiable, Sendable {
    let id = UUID()
    var gameID: Int64
    var title: String
    var year: Int?
    var candidates: [HLTBCandidate]
    /// Whether accepting the pick fills gaps or replaces the three times.
    var mode: HLTBWriteMode = .fillGaps
    /// The game's effective platforms (D2b — emphasise matching candidate platforms).
    var librarySlugs: [String] = []
}

/// The bulk "Fetch Missing Time Estimates…" / "Refresh Time Estimates…" run (PLAN §5.3):
/// serial, progress + Cancel, a live summary, an ambiguous list to resolve one-by-one
/// afterwards, and a hard stop on the first unexpected response — "VGN stopped and made
/// no further requests." In `.replace` mode it first asks for confirmation (the count +
/// "values will be replaced") and every replaced game's previous times are collected so
/// the caller can register **one** Undo step for the whole batch.
///
/// `@MainActor @Observable`. Everything already cached is served without requests; a
/// re-run only queries what is still missing and not negatively cached (the search
/// client's DB cache does that transparently). Nothing here is written from a `body`.
@MainActor
@Observable
final class HLTBBulkFetchModel {
    enum Phase: Sendable, Equatable { case confirm, running, finished, stopped }

    let sourceLabel = "HowLongToBeat"
    let mode: HLTBWriteMode

    private let store: LibraryStore
    private let makeSearch: @Sendable () -> any HLTBSearching

    private(set) var phase: Phase = .running
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var currentTitle = ""
    private(set) var filled = 0
    /// No plausible HowLongToBeat entry came back from any ladder rung (wave 21 D2c) —
    /// distinct from ``ambiguous`` ("needs your pick").
    private(set) var notFound = 0
    /// Matched an entry, but nothing was written (HLTB had no times, or every gap was
    /// already filled).
    private(set) var unchanged = 0
    /// Written games whose Main+Extra was missing on HLTB, so the Main Story filled the
    /// main slot (wave 21 D1).
    private(set) var mainStoryUsed = 0
    /// This run's cache / network tallies ("40 from cache · 3 from network").
    private(set) var tally = HLTBRequestTally()
    private(set) var ambiguous: [HLTBAmbiguousGame] = []
    private(set) var stoppedReason: String?
    /// Previous times of every game whose estimates were replaced this run (D4 batch Undo).
    private(set) var replacedSnapshots: [Int64: HLTBTimeSnapshot] = [:]

    /// Called once when a `.replace` run ends (finished or stopped), with the snapshots
    /// gathered so far, so the caller can register a single Undo step and a banner.
    var onReplaceFinished: (@MainActor ([Int64: HLTBTimeSnapshot]) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingIDs: [Int64] = []
    /// The search instance for the current run, reused so a post-run ``pick`` can also
    /// remember the chosen candidate under its id-key (D1).
    @ObservationIgnored private var runSearch: (any HLTBSearching)?
    /// Games whose exact refresh-by-id came back "not found any more" (D4) — surfaced in
    /// the summary so the owner knows to pick again.
    private(set) var lostLinks = 0
    private(set) var linkedByID = 0
    /// Games written by the zero-request cache pass (wave 21 E) — they stay written even
    /// when the network part stops.
    private(set) var updatedFromCache = 0
    /// Whether the run ended on an unexpected response (not a Cancel).
    private(set) var stoppedByReject = false

    init(store: LibraryStore, makeSearch: @escaping @Sendable () -> any HLTBSearching,
         mode: HLTBWriteMode = .fillGaps) {
        self.store = store
        self.makeSearch = makeSearch
        self.mode = mode
    }

    /// Begin the run over `gameIDs` (already the resolved scope). In `.replace` mode this
    /// only stages the run and shows the confirmation; ``confirmAndRun()`` starts it.
    func start(gameIDs: [Int64]) {
        total = gameIDs.count
        pendingIDs = gameIDs
        if mode == .replace {
            phase = gameIDs.isEmpty ? .finished : .confirm
            return
        }
        beginRun()
    }

    /// Confirm a staged `.replace` run (the sheet's "Replace" button).
    func confirmAndRun() {
        guard phase == .confirm else { return }
        beginRun()
    }

    private func beginRun() {
        let gameIDs = pendingIDs
        phase = gameIDs.isEmpty ? .finished : .running
        guard !gameIDs.isEmpty else { return }
        let search = makeSearch()
        runSearch = search
        task = Task { [weak self] in await self?.run(gameIDs: gameIDs, search: search) }
    }

    /// A game the cache pass could not settle — the network pass takes it from there,
    /// reusing what the cache already knew.
    private enum Deferred {
        case plain(HLTBFillService.CachePass)
        case linked(Int64, HLTBFillService.LinkedCachePass)
    }

    /// Two passes (wave 21 E). **Pass 1 — cache only, zero requests:** every game the
    /// cache settles is applied first. **Pass 2 — network:** only the rest go through
    /// discovery / sign-in / search. A reject in pass 2 stops the network part, but what
    /// pass 1 applied stays applied and is reported ("12 updated from cache · stopped: …").
    private func run(gameIDs: [Int64], search: any HLTBSearching) async {
        let facts = (try? await store.timeToBeatFacts(gameIDs: gameIDs)) ?? [:]
        let service = HLTBFillService(search: search)
        // D4: id-linked games first — each is one exact lookup (no ladder), stable order.
        let ordered = gameIDs.filter { facts[$0]?.hltbID != nil }
                    + gameIDs.filter { facts[$0]?.hltbID == nil }

        // Pass 1 — the cache.
        var deferred: [(id: Int64, facts: HLTBGameFacts, pass: Deferred)] = []
        let filledBefore = filled
        for id in ordered {
            if Task.isCancelled {
                await finish(.stopped, reason: "Cancelled.")
                return
            }
            guard let f = facts[id] else { completed += 1; continue }
            currentTitle = f.title
            if let hltbID = f.hltbID {
                let pass = await service.resolveLinkedFromCache(
                    title: f.title, year: f.year, hltbID: hltbID, librarySlugs: f.platformSlugSet)
                guard let outcome = pass.outcome else {
                    deferred.append((id, f, .linked(hltbID, pass)))
                    continue
                }
                await handleLinked(outcome, id: id, facts: f, search: search)
            } else {
                let pass = await service.resolveFromCache(
                    title: f.title, year: f.year, librarySlugs: f.platformSlugSet)
                guard let outcome = pass.outcome else {
                    deferred.append((id, f, .plain(pass)))
                    continue
                }
                await handle(outcome, id: id, facts: f, search: search)
            }
            completed += 1
        }
        updatedFromCache = filled - filledBefore

        // Pass 2 — the network, for what the cache could not settle.
        for item in deferred {
            if Task.isCancelled {
                await finish(.stopped, reason: "Cancelled.")
                return
            }
            let f = item.facts
            currentTitle = f.title
            do {
                switch item.pass {
                case .linked(let hltbID, let cached):
                    let outcome = try await service.resolveLinked(
                        title: f.title, year: f.year, hltbID: hltbID,
                        librarySlugs: f.platformSlugSet, cached: cached)
                    await handleLinked(outcome, id: item.id, facts: f, search: search)
                case .plain(let cached):
                    let outcome = try await service.resolve(
                        title: f.title, year: f.year, librarySlugs: f.platformSlugSet, cached: cached)
                    await handle(outcome, id: item.id, facts: f, search: search)
                }
            } catch is CancellationError {
                await finish(.stopped, reason: "Cancelled.")
                return
            } catch let error as ImportError {
                stoppedByReject = true
                await finish(.stopped, reason: Self.reason(from: error))
                return
            } catch {
                stoppedByReject = true
                await finish(.stopped, reason: "the request failed")
                return
            }
            completed += 1
        }
        await finish(.finished, reason: nil)
    }

    /// Route an exact refresh-by-id outcome (D4).
    private func handleLinked(_ outcome: HLTBFillService.LinkedOutcome, id: Int64,
                              facts f: HLTBGameFacts, search: any HLTBSearching) async {
        switch outcome {
        case .exact(let candidate):
            linkedByID += 1
            await apply(gameID: id, candidate: candidate)
            await search.rememberChosen(candidate)
        case .lost(let outcome):
            lostLinks += 1
            await handle(outcome, id: id, facts: f, search: search)
        }
    }

    /// Route one game's match outcome: apply a confident match (and remember it), list an
    /// ambiguous one for a pick, or count a miss.
    private func handle(_ outcome: HLTBMatchOutcome, id: Int64,
                        facts f: HLTBGameFacts, search: any HLTBSearching) async {
        switch outcome {
        case .confident(let candidate):
            await apply(gameID: id, candidate: candidate)
            await search.rememberChosen(candidate)
        case .ambiguous(let list):
            ambiguous.append(HLTBAmbiguousGame(
                gameID: id, title: f.title, year: f.year, candidates: list, librarySlugs: f.platformSlugs))
        case .notFound:
            notFound += 1
        }
    }

    /// Write one game's estimates in the run's mode, counting the result and (for replace)
    /// collecting its previous times for the batch Undo.
    private func apply(gameID: Int64, candidate: HLTBCandidate) async {
        switch mode {
        case .fillGaps:
            let result = try? await store.applyHLTBTimes(gameID: gameID, candidate: candidate)
            if result?.didWrite == true {
                filled += 1
                if result?.wroteNormally == true, candidate.usedMainStoryForMain { mainStoryUsed += 1 }
            } else { unchanged += 1 }
        case .replace:
            let result = try? await store.replaceHLTBTimes(gameID: gameID, candidate: candidate)
            if let result, result.didWrite {
                filled += 1
                if candidate.usedMainStoryForMain { mainStoryUsed += 1 }
                if replacedSnapshots[gameID] == nil { replacedSnapshots[gameID] = result.previous }
            } else {
                // HLTB has the entry but no times — the game stays as it was (and flagged).
                unchanged += 1
            }
        }
    }

    private func finish(_ phase: Phase, reason: String?) async {
        if let search = runSearch { tally = await search.requestTally() }
        self.phase = phase
        self.stoppedReason = reason
        if mode == .replace { onReplaceFinished?(replacedSnapshots) }
    }

    /// Cancel the run (finishes the item in flight, then stops).
    func cancel() { task?.cancel() }

    /// Resolve one ambiguous game with the user's chosen candidate — also remembers it
    /// under its id-key (D1) so a later refresh is exact and cached.
    func pick(gameID: Int64, candidate: HLTBCandidate) {
        guard ambiguous.contains(where: { $0.gameID == gameID }) else { return }
        ambiguous.removeAll { $0.gameID == gameID }
        let search = runSearch
        Task { [weak self] in
            await self?.apply(gameID: gameID, candidate: candidate)
            await search?.rememberChosen(candidate)
        }
    }

    /// Drop an ambiguous game without filling it.
    func skip(gameID: Int64) { ambiguous.removeAll { $0.gameID == gameID } }

    var isRunning: Bool { phase == .running }
    var needsConfirmation: Bool { phase == .confirm }

    /// The confirmation prompt for a `.replace` run (PLAN §5.3, D4).
    var confirmationMessage: String {
        "^[\(total) game](inflect: true) will have their rushed / main / completionist times "
            + "replaced with HowLongToBeat's, where it has the game. Existing estimates are overwritten."
    }

    /// The sheet title, per mode.
    var sheetTitle: String {
        mode == .replace ? "Refresh Time Estimates" : "Fetch Missing Time Estimates"
    }

    /// "12 filled · 3 need your pick · 4 no HLTB entry · stopped: …" ("replaced" in replace
    /// mode). Wave 21 (D2c) separates "no HLTB entry" (nothing plausible from any rung) from
    /// "needs your pick" (plausible rows came back). Also surfaces games resolved exactly by
    /// their stored id, links HLTB dropped, matched-but-unchanged games, and the cache /
    /// network tallies.
    var summaryLine: String {
        let verb = mode == .replace ? "replaced" : "filled"
        let pick = ambiguous.count
        var parts = "\(filled) \(verb) · \(pick) need\(pick == 1 ? "s" : "") your pick · \(notFound) no HLTB entry"
        if linkedByID > 0 { parts = "\(linkedByID) linked by id · " + parts }
        if unchanged > 0 { parts += " · \(unchanged) unchanged" }
        if lostLinks > 0 { parts += " · \(lostLinks) link\(lostLinks == 1 ? "" : "s") lost" }
        if tally.fromCache + tally.fromNetwork > 0 {
            parts += " · \(tally.fromCache) from cache · \(tally.fromNetwork) from network"
        }
        if let reason = stoppedReason {
            if stoppedByReject {
                // Wave 21 E: the cache pass already ran — say what it kept, and that the
                // stop changed nothing else.
                if updatedFromCache > 0 { parts = "\(updatedFromCache) updated from cache · " + parts }
                parts += " · stopped: \(reason) — nothing else was changed"
            } else {
                parts += " · stopped: \(reason)"
            }
        }
        return parts
    }

    /// "2 games: Main+Extra not on HowLongToBeat — main story used" (wave 21 D1), or nil.
    var mainStoryNote: String? {
        guard mainStoryUsed > 0 else { return nil }
        return "\(mainStoryUsed) game\(mainStoryUsed == 1 ? "" : "s"): Main+Extra not on HowLongToBeat — main story used."
    }

    /// The reassurance line shown when a run stopped on a reject (PLAN §5.3).
    var stoppedNote: String? {
        phase == .stopped && stoppedReason != "Cancelled."
            ? "VGN stopped and made no further requests."
            : nil
    }

    /// The stop reason, in HowLongToBeat terms (wave 21 E): which step refused matters
    /// more to the owner than the transport detail — a sign-in (`/init`) change, the site
    /// itself (endpoint discovery), or the search reply.
    static func reason(from error: ImportError) -> String {
        if case .rejected(let reject) = error {
            let detail = reject.reason.message.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            switch reject.endpoint {
            case HLTBClient.authEndpoint: return "HowLongToBeat changed its sign-in"
            case HLTBClient.discoveryEndpoint: return "HowLongToBeat's site did not answer as expected"
            default: return "HowLongToBeat's search answered unexpectedly (\(detail.lowercasedFirst))"
            }
        }
        if case .budgetExceeded = error { return "the per-run request budget was reached" }
        return "an unexpected response"
    }
}

private extension String {
    /// "The response…" → "the response…" (for embedding a sentence mid-line).
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
