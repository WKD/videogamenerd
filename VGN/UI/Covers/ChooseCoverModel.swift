import Foundation
import CoreGraphics
import Observation

/// The seam the "Choose Cover…" sheet drives (PLAN §5.2 step 4). Mirrors the
/// `CoverLoading` pattern: defined in the UI lane, implemented in Services by
/// `ChooseCoverService` (which owns the `CoverStore` + `LibraryStore` and centralises
/// the "manual cover is user-edited" write). A UI-lane `CoverLoading` that does not
/// also conform (previews, `NoopCoverLoader`) simply means no "Choose Cover…" — the
/// inspector disables the entry point.
protocol ChooseCoverProviding: Sendable {
    /// Every browsable candidate across every provider for a game. `[]` when the
    /// providers can't be reached (offline / sample mode) — the sheet shows its
    /// empty state and the "Choose File…" fallback still works.
    func coverCandidates(forGameID id: Int64) async -> [CoverCandidate]

    /// A decoded, in-memory preview of a candidate at `maxPixel` (longest edge).
    /// Never files the image to disk. `nil` on any failure (the tile shows a
    /// placeholder).
    func candidateThumbnail(for candidate: CoverCandidate, maxPixel: Int) async -> sending CGImage?

    /// Download and permanently file a chosen candidate as the game's cover, marking
    /// it user-edited so enrichment never replaces it (reuses the drag-drop write
    /// path).
    func chooseCandidate(_ candidate: CoverCandidate, forGameID id: Int64) async throws

    /// File a user-picked local image (the "Choose File…" alternative) as the game's
    /// cover, marked user-edited. Same end state as choosing a candidate.
    func importCoverFile(_ url: URL, forGameID id: Int64) async throws
}

/// Drives the ``ChooseCoverSheet`` (PLAN §5.2 step 4). `@MainActor @Observable`; all
/// state is mutated from `async` methods invoked by `.task` / button actions, never
/// from a view `body` (the 100 %-CPU render-loop rule).
@MainActor
@Observable
final class ChooseCoverModel: Identifiable {
    nonisolated let id: Int64
    let title: String
    /// The game's current cover file (a local `covers/` name), shown as the "Current"
    /// tile so the user sees what they're replacing. Not itself a candidate.
    let currentCoverFile: String?

    enum LoadState {
        case loading
        case loaded([CoverCandidate])
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    /// The picked candidate's id, or `nil` (nothing picked yet → "Use This Cover"
    /// disabled).
    var selection: CoverCandidate.ID?
    /// True while a chosen cover / file is downloading + saving (buttons disabled).
    private(set) var isSaving = false

    /// Called once the cover is saved (or the sheet should close). Set by the presenter.
    var onFinished: () -> Void = {}

    private let backend: any ChooseCoverProviding

    init(gameID: Int64, title: String, currentCoverFile: String?, backend: any ChooseCoverProviding) {
        self.id = gameID
        self.title = title
        self.currentCoverFile = currentCoverFile
        self.backend = backend
    }

    /// All loaded candidates (empty until `load()` completes / on failure).
    var candidates: [CoverCandidate] {
        if case let .loaded(c) = state { return c }
        return []
    }

    /// Candidates grouped by provider, in first-appearance order, for the sheet's
    /// per-provider sections.
    var groups: [ProviderGroup] {
        var order: [String] = []
        var byProvider: [String: [CoverCandidate]] = [:]
        for c in candidates {
            if byProvider[c.providerID] == nil { order.append(c.providerID) }
            byProvider[c.providerID, default: []].append(c)
        }
        return order.map { ProviderGroup(providerID: $0, candidates: byProvider[$0] ?? []) }
    }

    struct ProviderGroup: Identifiable {
        let providerID: String
        let candidates: [CoverCandidate]
        var id: String { providerID }
        /// Pretty section title ("libretro", "IGDB").
        var title: String {
            switch providerID {
            case "igdb": return "IGDB"
            case "libretro": return "libretro"
            default: return providerID.capitalized
            }
        }
    }

    /// Fetch the candidate list. Safe to call once from `.task`.
    func load() async {
        state = .loading
        selection = nil
        let found = await backend.coverCandidates(forGameID: id)
        state = .loaded(found)
    }

    /// A decoded preview for a candidate tile (called from the tile's `.task`).
    func preview(for candidate: CoverCandidate, maxPixel: Int) async -> CGImage? {
        await backend.candidateThumbnail(for: candidate, maxPixel: maxPixel)
    }

    /// Save the currently-selected candidate as the cover, then finish.
    func useSelected() async {
        guard let selection, let candidate = candidates.first(where: { $0.id == selection }) else { return }
        await save { try await self.backend.chooseCandidate(candidate, forGameID: self.id) }
    }

    /// Save a chosen candidate immediately (double-click).
    func use(_ candidate: CoverCandidate) async {
        selection = candidate.id
        await save { try await self.backend.chooseCandidate(candidate, forGameID: self.id) }
    }

    /// Save a user-picked local image file as the cover, then finish.
    func useFile(_ url: URL) async {
        await save { try await self.backend.importCoverFile(url, forGameID: self.id) }
    }

    private func save(_ work: @escaping () async throws -> Void) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await work()
            onFinished()
        } catch {
            state = .failed("Couldn't set the cover. \(error.localizedDescription)")
        }
    }
}
