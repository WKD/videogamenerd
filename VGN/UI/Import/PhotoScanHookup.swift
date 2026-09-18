import GRDB
import SwiftUI

// App-level hookup for the photo-scan UI (PLAN §6.2): a presenter the container
// builds once, a view modifier that hosts the sheet + window drop, and the
// "Scan Photos…" command. Kept in this folder so the hot container/root files
// only need one line each.

/// Snapshot of what is already owned, read once before each scan so the review
/// sheet can grey out duplicates without a database round-trip per row.
final class LibraryPresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ownedOnPlatform: Set<String> = []
    private var ownedAnywhere: Set<Int64> = []

    func contains(igdbID: Int64, platform: String?) -> Bool {
        lock.withLock {
            if let platform { return ownedOnPlatform.contains("\(igdbID)|\(platform)") }
            return ownedAnywhere.contains(igdbID)
        }
    }

    func reload(from database: AppDatabase) async {
        let rows: [(Int64, String)] = (try? await database.dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.igdb_id AS igdb_id, p.platform_id AS platform_id
                FROM games g
                JOIN product_games pg ON pg.game_id = g.id
                JOIN products p ON p.id = pg.product_id
                WHERE g.igdb_id IS NOT NULL
                """).map { ($0["igdb_id"] as Int64, $0["platform_id"] as String) }
        }) ?? []
        lock.withLock {
            ownedOnPlatform = Set(rows.map { "\($0.0)|\($0.1)" })
            ownedAnywhere = Set(rows.map(\.0))
        }
    }
}

/// Owns the presentation state of the scan sheet. One per window/container.
@MainActor
@Observable
final class PhotoScanPresenter {
    /// Non-nil while the scan sheet is up. A fresh model per scan.
    var model: PhotoScanModel?

    private let environment: PhotoScanEnvironment
    private let presence: LibraryPresenceCache
    private let database: AppDatabase

    init(services: ServicesFactory.Graph, platformCatalog: PlatformCatalog,
         store: LibraryStore, library: LibraryViewModel) {
        let presence = LibraryPresenceCache()
        self.presence = presence
        self.database = store.database
        self.environment = PhotoScanEnvironment(
            services: services,
            platformCatalog: platformCatalog,
            store: store,
            isInLibrary: { id, platform in presence.contains(igdbID: id, platform: platform) },
            onQuickAdd: { [weak library] title in library?.requestQuickAdd(prefill: title) },
            onShowInLibrary: { [weak library] id in
                library?.select(.all)
                library?.selectOnly(id)
                library?.showInspector()
            }
        )
    }

    /// Opens the scan sheet, optionally with photos already queued (window drop).
    func present(urls: [URL] = []) {
        guard model == nil else {
            if !urls.isEmpty { model?.enqueue(urls) }
            return
        }
        Task {
            await presence.reload(from: database)
            let fresh = environment.makeModel()
            if !urls.isEmpty { fresh.enqueue(urls) }
            model = fresh
        }
    }

    func dismiss() { model = nil }
}

// MARK: - View hookup

private struct PhotoScanPresentation: ViewModifier {
    let presenter: PhotoScanPresenter?

    func body(content: Content) -> some View {
        if let presenter {
            content
                .sheet(isPresented: Binding(
                    get: { presenter.model != nil },
                    set: { if !$0 { presenter.dismiss() } }
                )) {
                    if let model = presenter.model {
                        PhotoScanView(model: model) { presenter.dismiss() }
                            .frame(minWidth: 760, minHeight: 560)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let images = urls.filter(PhotoScanPresentation.isImage)
                    guard !images.isEmpty else { return false }
                    presenter.present(urls: images)
                    return true
                }
                .focusedSceneValue(\.photoScanPresenter, presenter)
        } else {
            content
        }
    }

    private static func isImage(_ url: URL) -> Bool {
        ["heic", "heif", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }
}

extension View {
    /// Hosts the photo-scan sheet and accepts image files dropped on the window.
    func photoScanPresentation(_ presenter: PhotoScanPresenter?) -> some View {
        modifier(PhotoScanPresentation(presenter: presenter))
    }
}

// MARK: - Command

struct PhotoScanPresenterFocusedValueKey: FocusedValueKey {
    typealias Value = PhotoScanPresenter
}

extension FocusedValues {
    var photoScanPresenter: PhotoScanPresenter? {
        get { self[PhotoScanPresenterFocusedValueKey.self] }
        set { self[PhotoScanPresenterFocusedValueKey.self] = newValue }
    }
}

/// File ▸ Scan Photos… (⇧⌘O).
struct PhotoScanCommands: Commands {
    @FocusedValue(\.photoScanPresenter) private var presenter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Scan Photos…") { presenter?.present() }
                .keyboardShortcut("o", modifiers: [.shift, .command])
                .disabled(presenter == nil)
        }
    }
}
