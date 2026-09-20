import Foundation

/// One system row in the catalogue's system picker (folder / platform + present-entry count).
struct RomCatalogueSystemCount: Identifiable, Sendable, Equatable {
    var system: String
    var count: Int
    /// A friendly label, precomputed per source (PLAN §16): a PS Plus row's `system` is already a
    /// VGN platform slug; a Batocera row's is a folder name mapped through ``BatoceraSystems``.
    var label: String
    var id: String { system }

    init(system: String, count: Int, source: VaultSource) {
        self.system = system
        self.count = count
        switch source {
        case .batocera:
            self.label = BatoceraSystems.platformSlug(for: system).map(PlatformLabels.short) ?? system
        case .psn, .gog, .delicious:
            // Every non-Batocera Vault source stores a VGN platform slug as its `system`.
            self.label = PlatformLabels.short(system)
        }
    }
}

/// Drives the ROM Catalogue browser (PLAN §15 sidebar destination). Paged, filtered, sorted,
/// FTS-searched reads of `rom_catalog` — **never** the library grid, counts, stats, ranking or
/// exports. `@MainActor @Observable`; built directly over a ``RomCatalogStore`` (tests use an
/// in-memory DB).
@MainActor
@Observable
final class RomCatalogueModel {
    private let catalog: RomCatalogStore
    /// The Vault source this browser is scoped to (PLAN §16).
    let source: VaultSource
    let thumbnails: BatoceraThumbnailLoader?
    let pageSize: Int

    private(set) var systems: [RomCatalogueSystemCount] = []
    private(set) var totalAll = 0

    /// nil ⇒ All systems.
    var selectedSystem: String? { didSet { if selectedSystem != oldValue { reload() } } }
    var sort: RomCatalogStore.BrowseSort = .title { didSet { if sort != oldValue { reload() } } }
    var filter: RomCatalogStore.BrowseFilter = .all { didSet { if filter != oldValue { reload() } } }
    var searchText: String = "" { didSet { if searchText != oldValue { scheduleSearchReload() } } }

    private(set) var entries: [RomCatalogEntry] = []
    private(set) var matchCount = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Multi-selection of catalogue ids (for a batch "Add to Library…").
    var selection = Set<Int64>()
    /// The presented "Find match…" search sheet (PS Plus, PLAN §16), or nil.
    var findMatchModel: IGDBLinkModel?

    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadedOffset = 0

    init(catalog: RomCatalogStore, source: VaultSource = .batocera,
         thumbnails: BatoceraThumbnailLoader? = nil, pageSize: Int = 100) {
        self.catalog = catalog
        self.source = source
        self.thumbnails = thumbnails
        self.pageSize = pageSize
    }

    var hasMore: Bool { entries.count < matchCount }

    /// Load the system list + the first page. Idempotent.
    func start() {
        guard !hasLoaded || systems.isEmpty else { return }
        Task { await loadSystems() }
        reload()
    }

    func loadSystems() async {
        let perSystem = (try? await catalog.countsPerSystem(source: source.storage)) ?? [:]
        let src = source
        systems = perSystem.map { RomCatalogueSystemCount(system: $0.key, count: $0.value, source: src) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.system < $1.system }
        totalAll = perSystem.values.reduce(0, +)
    }

    // MARK: PS Plus actions (PLAN §16)

    /// Add PS Plus entries to the library as owned-via-subscription copies, then reload the row
    /// so it shows "In Library". Library counts refresh through the library's own observation.
    func addPSPlusToLibrary(ids: [Int64]) {
        let promoter = VaultLibraryPromoter(staging: ImportStagingStore(catalog.database), catalog: catalog)
        Task { [weak self] in
            try? await promoter.addToLibrary(ids: ids)
            self?.reload()
        }
    }

    /// Reload the first page for the current system / filter / sort / search.
    func reload() {
        pageTask?.cancel()
        isLoading = true
        loadedOffset = 0
        let (system, filter, sort, search, pageSize) = (selectedSystem, filter, sort, searchText, pageSize)
        let catalog = self.catalog
        let src = source.storage
        pageTask = Task { [weak self] in
            let rows = (try? await catalog.browse(source: src, system: system, filter: filter, sort: sort,
                                                  search: search, limit: pageSize, offset: 0)) ?? []
            let count = (try? await catalog.browseCount(source: src, system: system, filter: filter,
                                                        search: search)) ?? rows.count
            guard let self, !Task.isCancelled else { return }
            self.entries = rows
            self.matchCount = count
            self.loadedOffset = rows.count
            self.isLoading = false
            self.hasLoaded = true
            self.selection = self.selection.intersection(Set(rows.map(\.id)))
        }
    }

    /// Load the next page (called when the grid nears its end).
    func loadMore() {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let (system, filter, sort, search, pageSize, offset) =
            (selectedSystem, filter, sort, searchText, pageSize, loadedOffset)
        let catalog = self.catalog
        let src = source.storage
        pageTask = Task { [weak self] in
            let rows = (try? await catalog.browse(source: src, system: system, filter: filter, sort: sort,
                                                  search: search, limit: pageSize, offset: offset)) ?? []
            guard let self, !Task.isCancelled else { return }
            self.entries.append(contentsOf: rows)
            self.loadedOffset += rows.count
            self.isLoading = false
        }
    }

    private func scheduleSearchReload() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.reload()
        }
    }

    // MARK: Selection

    func toggle(_ id: Int64) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    func selectOnly(_ id: Int64) { selection = [id] }
    func clearSelection() { selection.removeAll() }
    /// The ids to act on: the multi-selection, or a single row when nothing is selected.
    func actionIDs(for id: Int64) -> [Int64] {
        selection.contains(id) && selection.count > 1 ? Array(selection) : [id]
    }
}
