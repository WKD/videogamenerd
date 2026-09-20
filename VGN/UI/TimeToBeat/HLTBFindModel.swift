import Foundation
import Observation

/// The manual "Find on HowLongToBeat…" search model (PLAN §5.3, D5) — modelled on the
/// Quick Add / Link-to-IGDB search sheets, but against the frail HLTB endpoint, so it is
/// deliberately **polite**: no per-keystroke requests (search fires on Return or after an
/// 800 ms typing pause), a 3-character minimum, identical queries served from an in-session
/// cache (zero extra requests), a visible per-session request counter with a hard cap, and
/// a clean **stop** on the first unexpected response (the existing reject path). In sample /
/// seeded / test modes the searcher is inert and the sheet says so.
///
/// `@MainActor @Observable`. Nothing here writes library state or queries the DB from a
/// `body`: the Link actions call back to the presenter, which performs the (undoable) write.
@MainActor
@Observable
final class HLTBFindModel: Identifiable {
    enum Phase: Equatable { case idle, searching, results, empty, stopped, inert }

    /// Which link action the owner chose.
    enum LinkKind: Equatable { case linkAndUse, linkOnly }

    nonisolated var id: Int64 { gameID }
    let gameID: Int64
    let title: String
    let year: Int?
    let librarySlugs: [String]

    /// The editable search field, prefilled with the D3-cleaned title.
    var query: String {
        didSet { if query != oldValue { onQueryChanged() } }
    }
    private(set) var results: [HLTBCandidate] = []
    private(set) var phase: Phase
    /// The game's current link (nil when unlinked). Updated as the owner links / unlinks.
    private(set) var linkedID: Int64?
    /// Live count of searches that actually consulted HowLongToBeat this session (D5).
    private(set) var requestCount = 0
    private(set) var stopMessage: String?

    let minChars = 3
    let requestCap: Int

    // Seams
    private let search: any HLTBSearching
    private let isInert: Bool
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// In-session cache: an identical query is served without a new request (D5).
    private var seen: [String: [HLTBCandidate]] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Called when the owner links a candidate (the presenter does the undoable write).
    var onLink: (HLTBCandidate, LinkKind) -> Void = { _, _ in }
    /// Called when the owner unlinks (clears the stored id; times stay).
    var onUnlink: () -> Void = {}
    var onCancel: () -> Void = {}

    init(gameID: Int64, title: String, year: Int?, librarySlugs: [String],
         linkedID: Int64?, prefill: String,
         search: any HLTBSearching, isInert: Bool,
         requestCap: Int = ImportPolicy.hltb.budget,
         debounce: Duration = .milliseconds(800),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.gameID = gameID
        self.title = title
        self.year = year
        self.librarySlugs = librarySlugs
        self.linkedID = linkedID
        self.query = prefill
        self.search = search
        self.isInert = isInert
        self.requestCap = requestCap
        self.debounce = debounce
        self.sleep = sleep
        self.phase = isInert ? .inert : .idle
    }

    var sheetTitle: String { "Find on HowLongToBeat" }
    var libraryPlatformLabel: String {
        librarySlugs.map { PlatformLabels.short($0) }.joined(separator: ", ")
    }
    var isLinked: Bool { linkedID != nil }
    /// "3 requests this session" — the visible politeness counter (D5).
    var requestCountLabel: String { "^[\(requestCount) request](inflect: true) this session" }
    var reachedCap: Bool { requestCount >= requestCap }

    /// Kick the initial search from `.task` (once). Idempotent.
    func start() { onQueryChanged() }

    /// Search immediately (Return key) — skips the debounce, still honours min length / cap / cache.
    func searchNow() { onQueryChanged(immediate: true) }

    private func onQueryChanged(immediate: Bool = false) {
        guard !isInert, phase != .stopped else { return }
        task?.cancel()
        generation &+= 1
        let generation = generation
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minChars else { results = []; phase = .idle; return }

        // Served from the in-session cache → zero requests.
        if let cached = seen[cacheKey(text)] {
            results = cached
            phase = cached.isEmpty ? .empty : .results
            return
        }
        guard !reachedCap else { return }   // hold at the cap until the owner edits within it

        phase = .searching
        task = Task { [weak self] in
            guard let self else { return }
            if !immediate { try? await self.sleep(self.debounce) }
            if Task.isCancelled || generation != self.generation { return }
            await self.run(text: text, generation: generation)
        }
    }

    private func run(text: String, generation: Int) async {
        guard !reachedCap else { return }
        requestCount += 1
        do {
            let raw = try await search.search(title: text)
            guard generation == self.generation else { return }
            let ranked = HLTBMatcher.scored(title: text, year: year,
                                            candidates: raw, librarySlugs: Set(librarySlugs))
                .map(\.candidate)
            seen[cacheKey(text)] = ranked
            results = ranked
            phase = ranked.isEmpty ? .empty : .results
        } catch is CancellationError {
            // superseded
        } catch let error as ImportError {
            phase = .stopped
            stopMessage = Self.stopMessage(error)
        } catch {
            phase = .stopped
            stopMessage = "Couldn't reach HowLongToBeat. VGN made no further requests."
        }
    }

    // MARK: - Actions

    func linkAndUse(_ candidate: HLTBCandidate) {
        linkedID = candidate.id
        onLink(candidate, .linkAndUse)
    }

    func linkOnly(_ candidate: HLTBCandidate) {
        linkedID = candidate.id
        onLink(candidate, .linkOnly)
    }

    func unlink() {
        linkedID = nil
        onUnlink()
    }

    func cancel() { task?.cancel(); onCancel() }

    private func cacheKey(_ text: String) -> String {
        TitleNormalizer.normalize(text, level: .canonical)
    }

    static func stopMessage(_ error: ImportError) -> String {
        if case .rejected(let reject) = error {
            return "\(reject.reason.message) VGN stopped and made no further requests."
        }
        return "HowLongToBeat request stopped. VGN made no further requests."
    }
}
