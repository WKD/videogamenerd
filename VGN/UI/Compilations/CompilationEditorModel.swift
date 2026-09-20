import Foundation
import Observation

/// One row in the member picker: a catalogue hit or a game already in the library
/// (reused, not duplicated — PLAN §5.1).
struct CompilationSearchResult: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable { case catalog, local }
    var id: String
    var title: String
    var year: Int?
    var igdbID: Int64?
    /// Set for a local library game (reuse by id — handles manual, IGDB-less games).
    var gameID: Int64?
    var source: Source
    /// True when this game is already a member of the compilation (greyed out).
    var alreadyMember: Bool
}

/// The "Fill from IGDB bundle" preview: which of the bundle's members are not yet
/// in the compilation (PLAN §5.1 — coverage is imperfect; show a diff).
struct BundleDiff: Sendable, Equatable {
    /// Members present in the IGDB bundle but not yet in this compilation.
    var toAdd: [CompilationMemberDraft]
    /// Members already present (shown greyed, for context).
    var alreadyPresent: [String]
    var isEmpty: Bool { toAdd.isEmpty }
}

/// A pending orphan confirmation when removing a member would leave a game neither
/// owned nor played (PLAN §4 invariant 1).
struct MemberOrphanConfirm: Sendable, Equatable, Identifiable {
    var gameID: Int64
    var id: Int64 { gameID }
    var title: String
}

/// All compilation-editor logic (PLAN §5.1/§8) behind small seams, so the sheet is
/// a thin shell and every flow — add/reuse/remove/reorder/orphan/bundle diff/
/// convert/edit details — is unit-testable with fakes.
@MainActor
@Observable
final class CompilationEditorModel {
    // MARK: Loaded product
    let productID: Int64
    private(set) var members: [CompilationMemberInfo] = []
    private(set) var isLoading = true

    // MARK: Editable product fields
    var titleText: String = ""
    var platformID: String = ""
    var format: ProductFormat = .physical
    var editionText: String = ""
    var regionText: String = ""
    private(set) var igdbID: Int64?

    // MARK: Member picker (same quick-search as Quick Add)
    var query: String = "" {
        didSet { if query != oldValue { onQueryChanged() } }
    }
    private(set) var searchResults: [CompilationSearchResult] = []
    private(set) var isSearching = false

    // MARK: Transient UI
    private(set) var bundleDiff: BundleDiff?
    var orphanConfirm: MemberOrphanConfirm?
    private(set) var errorMessage: String?

    let allPlatforms: [PlatformInfo]

    // MARK: Seams
    private let writer: any CompilationWriting
    private let catalog: any CatalogSearching
    private let localSearch: @Sendable (String) async -> [QuickAddLibraryMatch]
    private let platformIGDBIDs: @Sendable (String) -> [Int]
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    var onSelectGame: (Int64) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// The window's undo manager (set by the sheet from `@Environment(\.undoManager)`),
    /// so removing a member registers a "Remove from Compilation" undo step. Weak +
    /// main-isolated; nil in previews / headless tests that don't wire one.
    weak var undoManager: UndoManager?

    // Search bookkeeping
    private var searchGeneration = 0
    private var catalogResults: [IGDBSearchResult] = []
    private var localMatches: [QuickAddLibraryMatch] = []
    private var localTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?

    init(
        productID: Int64,
        writer: any CompilationWriting,
        catalog: any CatalogSearching,
        localSearch: @escaping @Sendable (String) async -> [QuickAddLibraryMatch],
        platforms: [PlatformInfo] = PlatformLabels.all,
        platformIGDBIDs: @escaping @Sendable (String) -> [Int] = { _ in [] },
        debounce: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.productID = productID
        self.writer = writer
        self.catalog = catalog
        self.localSearch = localSearch
        self.allPlatforms = platforms
        self.platformIGDBIDs = platformIGDBIDs
        self.debounce = debounce
        self.sleep = sleep
    }

    // MARK: - Load

    func load() async {
        guard let product = try? await writer.compilationProduct(id: productID) else {
            isLoading = false
            return
        }
        apply(product)
        isLoading = false
    }

    private func apply(_ product: CompilationProductInfo) {
        members = product.members
        titleText = product.title ?? ""
        platformID = product.platformID
        format = product.format
        editionText = product.edition ?? ""
        regionText = product.region ?? ""
        igdbID = product.igdbID
    }

    private func reload() async {
        if let product = try? await writer.compilationProduct(id: productID) {
            members = product.members
            igdbID = product.igdbID
        }
        rebuildResults()   // refresh "already a member" flags
    }

    // MARK: - Member search (local first, then IGDB — same flow as Quick Add)

    private func onQueryChanged() {
        searchGeneration &+= 1
        let generation = searchGeneration
        let text = query

        localTask?.cancel()
        localTask = Task { [weak self] in
            guard let self else { return }
            let matches = await self.localSearch(text)
            self.applyLocal(matches, generation: generation)
        }

        remoteTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            catalogResults = []
            isSearching = false
            rebuildResults()
            return
        }
        isSearching = true
        remoteTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(self.debounce)
            if Task.isCancelled || generation != self.searchGeneration { return }
            await self.runRemote(text: text, generation: generation)
        }
    }

    private func runRemote(text: String, generation: Int) async {
        let ids = platformIGDBIDs(platformID)
        do {
            let results = try await catalog.search(text, platformIGDBIDs: ids.isEmpty ? nil : ids, limit: 12)
            applyCatalog(results, generation: generation)
        } catch {
            guard generation == searchGeneration else { return }
            isSearching = false
            rebuildResults()
        }
    }

    func applyLocal(_ matches: [QuickAddLibraryMatch], generation: Int) {
        guard generation == searchGeneration else { return }
        localMatches = matches
        rebuildResults()
    }

    func applyCatalog(_ results: [IGDBSearchResult], generation: Int) {
        guard generation == searchGeneration else { return }
        catalogResults = results
        isSearching = false
        rebuildResults()
    }

    private func rebuildResults() {
        searchResults = Self.buildResults(
            catalog: catalogResults, local: localMatches, currentMembers: members)
    }

    /// Merge catalogue + local hits into member-picker rows (pure, unit-tested).
    /// Catalogue rows first (richer), each flagged when a library game already
    /// matches; then any remaining local games as reuse rows. Rows for games
    /// already in the compilation are flagged `alreadyMember`.
    static func buildResults(
        catalog: [IGDBSearchResult], local: [QuickAddLibraryMatch],
        currentMembers: [CompilationMemberInfo]
    ) -> [CompilationSearchResult] {
        let memberIDs = Set(currentMembers.map(\.gameID))
        var out: [CompilationSearchResult] = []
        var usedLocal = Set<Int64>()
        var localByKey: [String: [QuickAddLibraryMatch]] = [:]
        for m in local { localByKey[m.normalizedTitle, default: []].append(m) }

        for r in catalog {
            let key = TitleNormalizer.normalize(r.name, level: .articleless)
            let match = localByKey[key]?.first { !usedLocal.contains($0.gameID) }
            if let match { usedLocal.insert(match.gameID) }
            out.append(CompilationSearchResult(
                id: "igdb:\(r.id)", title: r.name, year: r.releaseYear,
                igdbID: r.id, gameID: match?.gameID, source: .catalog,
                alreadyMember: match.map { memberIDs.contains($0.gameID) } ?? false))
        }
        for m in local where !usedLocal.contains(m.gameID) {
            out.append(CompilationSearchResult(
                id: "local:\(m.gameID)", title: m.title, year: m.year,
                igdbID: nil, gameID: m.gameID, source: .local,
                alreadyMember: memberIDs.contains(m.gameID)))
        }
        return out
    }

    // MARK: - Add a member (reuse existing library game where possible)

    func addMember(_ result: CompilationSearchResult) async {
        guard !result.alreadyMember else { return }
        let position = members.count
        do {
            if let gameID = result.gameID {
                // Reuse an existing library game by id (no duplicate).
                try await writer.addExistingGameToCompilation(
                    productID: productID, gameID: gameID, position: position)
            } else {
                _ = try await writer.addCompilationMember(
                    productID: productID,
                    CompilationMemberDraft(title: result.title, igdbID: result.igdbID,
                                           year: result.year, position: position))
            }
            query = ""
            await reload()
        } catch {
            errorMessage = "Couldn't add \u{201C}\(result.title)\u{201D}."
        }
    }

    // MARK: - Remove a member (orphan-aware)

    func removeMember(_ gameID: Int64) async {
        do {
            let (outcome, undo) = try await writer.removeCompilationMemberCapturingUndo(
                productID: productID, gameID: gameID, confirmOrphanDelete: false)
            switch outcome {
            case .ok:
                registerRemoveUndo(undo)
                await reload()
            case .wouldOrphan(let ids):
                let title = members.first { ids.contains($0.gameID) }?.title
                    ?? members.first { $0.gameID == gameID }?.title ?? "This game"
                orphanConfirm = MemberOrphanConfirm(gameID: gameID, title: title)
            }
        } catch {
            errorMessage = "Couldn't remove the game."
        }
    }

    /// Confirmed orphan removal (the member is deleted from the library).
    func confirmOrphanRemoval() async {
        guard let confirm = orphanConfirm else { return }
        orphanConfirm = nil
        if let (_, undo) = try? await writer.removeCompilationMemberCapturingUndo(
            productID: productID, gameID: confirm.gameID, confirmOrphanDelete: true) {
            registerRemoveUndo(undo)
        }
        await reload()
    }

    func cancelOrphanRemoval() { orphanConfirm = nil }

    /// Register one undo step for a member removal (owner: "Remove from Compilation").
    /// `UndoManager.undo()` hangs headless, so the restore is driven directly in tests.
    private func registerRemoveUndo(_ undo: ReconcileUndo?) {
        guard let undo, let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.undoRemoveMember(undo) }
        }
        um.setActionName(undo.actionName)
    }

    /// Restore a member-removal snapshot (undo). `internal` so a test drives it directly.
    func undoRemoveMember(_ undo: ReconcileUndo) async {
        do { try await writer.restoreReconcile(undo); await reload() }
        catch { errorMessage = "Couldn't undo." }
    }

    // MARK: - Reorder

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        members.move(fromOffsets: source, toOffset: destination)
        let ordered = members.map(\.gameID)
        Task { try? await writer.reorderCompilationMembers(productID: productID, orderedGameIDs: ordered) }
    }

    // MARK: - Fill from IGDB bundle

    /// Re-fetch the IGDB bundle's members and preview which ones are missing
    /// (PLAN §5.1). Requires the product's IGDB bundle id.
    func fillFromBundle() async {
        guard let igdbID else {
            errorMessage = "This compilation has no IGDB bundle to fill from."
            return
        }
        let expansion = (try? await catalog.bundleMembers(bundleIGDBID: igdbID)) ?? BundleMemberResult()
        bundleDiff = Self.computeBundleDiff(bundleMembers: expansion.members, currentMembers: members)
        if bundleDiff?.isEmpty == true {
            errorMessage = "The IGDB bundle adds nothing new."
        }
    }

    /// Pure diff: bundle members whose IGDB id is not already a member (unit-tested).
    static func computeBundleDiff(
        bundleMembers: [IGDBSearchResult], currentMembers: [CompilationMemberInfo]
    ) -> BundleDiff {
        // We can only compare on IGDB id; members carry no igdb id in the read, so
        // dedupe on normalised title as a fallback.
        let presentTitles = Set(currentMembers.map { TitleNormalizer.normalize($0.title, level: .articleless) })
        var toAdd: [CompilationMemberDraft] = []
        var already: [String] = []
        let base = currentMembers.count
        for (i, m) in bundleMembers.enumerated() {
            let key = TitleNormalizer.normalize(m.name, level: .articleless)
            if presentTitles.contains(key) {
                already.append(m.name)
            } else {
                toAdd.append(CompilationMemberDraft(
                    title: m.name, igdbID: m.id, year: m.releaseYear,
                    altTitles: m.alternativeNames, position: base + toAdd.count))
                _ = i
            }
        }
        return BundleDiff(toAdd: toAdd, alreadyPresent: already)
    }

    func applyBundleDiff() async {
        guard let diff = bundleDiff, !diff.isEmpty else { bundleDiff = nil; return }
        for draft in diff.toAdd {
            _ = try? await writer.addCompilationMember(productID: productID, draft)
        }
        bundleDiff = nil
        await reload()
    }

    func cancelBundleDiff() { bundleDiff = nil }

    // MARK: - Save descriptive fields

    func saveDetails() async {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let edition = editionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = regionText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await writer.renameProduct(productID: productID, title: title.isEmpty ? nil : title)
            try await writer.updateProductDetails(
                productID: productID, platformID: platformID, format: format,
                edition: .some(edition.isEmpty ? nil : edition),
                region: .some(region.isEmpty ? nil : region))
            await reload()
        } catch {
            errorMessage = "Couldn't save the compilation."
        }
    }

    func dismissError() { errorMessage = nil }

    /// The compilation converts single ↔ compilation automatically at the store
    /// level (member count 1 ↔ n). This flag drives the sheet's heading.
    var isCompilation: Bool { members.count > 1 }
}
