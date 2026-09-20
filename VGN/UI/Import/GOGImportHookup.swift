import AppKit
import SwiftUI

// App-level hookup for the GOG import flow (PLAN §14): a presenter the container builds
// once, a view modifier that hosts the progress + review sheets, and the "Import from
// GOG…" command. Mirrors `PhotoScanHookup` so the hot root/container files change by one
// line each.

/// A matcher that never throws: a missing-credentials / transient IGDB error becomes an
/// empty match, so one flaky lookup can't sink a whole sync (the row simply waits under
/// *New* for manual review). Wraps the production ``IGDBImportMatcher``.
struct ResilientImportMatcher: ImportMatcher {
    let base: any ImportMatcher
    func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
        (try? await base.match(request)) ?? ScanMatchOutcome(best: nil, alternatives: [], bucket: .none)
    }
}

/// Owns the presentation state of the GOG sync flow (progress sheet → review sheet). One
/// per window/container. Live only — in sample/seeded/test modes the injected backend is
/// a fake that never touches the network or the Keychain.
@MainActor
@Observable
final class GOGImportPresenter {
    let backend: any ImportBackend
    /// The Settings account model, so a sync's errors surface there and state refreshes.
    weak var account: GOGAccountModel?

    /// Non-nil while the review sheet is up.
    var reviewModel: ImportReviewModel?
    /// The latest progress while a sync runs (nil once the review sheet opens).
    private(set) var progress: ImportProgress?
    private(set) var isSyncing = false

    private let onLibraryChanged: () -> Void
    /// Selects the GOG Vault sidebar row and closes the review sheet ("Show in the Vault",
    /// PLAN §16). Wired in ``AppEnvironment``; a no-op offline.
    @ObservationIgnored var onShowInVault: () -> Void = {}
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(backend: any ImportBackend, onLibraryChanged: @escaping () -> Void = {}) {
        self.backend = backend
        self.onLibraryChanged = onLibraryChanged
    }

    /// File ▸ Import from GOG…: start a sync when signed in, else open Settings ▸ Accounts.
    func importFromSource() {
        if account?.signedIn == true {
            syncNow()
        } else {
            Self.openSettings()
        }
    }

    /// Run one sync and open the review sheet on success (PLAN §14.4). Cache-first, so a
    /// second sync inside the window makes no requests.
    func syncNow() {
        guard reviewModel == nil, !isSyncing else { return }
        isSyncing = true
        progress = ImportProgress(phase: .authenticating)
        let backend = self.backend
        let onLibraryChanged = self.onLibraryChanged
        syncTask = Task {
            do {
                let result = try await backend.runSync(onProgress: { p in
                    Task { @MainActor in self.progress = p }
                })
                if Task.isCancelled { self.reset(); return }
                let review = ImportReviewModel(
                    source: backend.source, sourceLabel: backend.sourceLabel,
                    staging: backend.staging, result: result,
                    showsPlatformPolicy: true,
                    rematchMatcher: backend.rematchMatcher, onLibraryChanged: onLibraryChanged)
                review.onShowInVault = self.onShowInVault
                self.reviewModel = review
                self.progress = nil
                self.isSyncing = false
                await self.account?.refresh()
            } catch {
                self.reset()
                self.account?.present(error: error)
            }
        }
    }

    func cancelSync() { syncTask?.cancel(); reset() }
    func dismissReview() { reviewModel = nil }

    private func reset() { progress = nil; isSyncing = false }

    /// Open the Settings window (Accounts tab) — the sign-in entry point when a sync is
    /// requested while signed out.
    static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - View hookup

private struct GOGImportPresentation: ViewModifier {
    let presenter: GOGImportPresenter?

    func body(content: Content) -> some View {
        if let presenter {
            content
                .sheet(isPresented: Binding(
                    get: { presenter.reviewModel != nil },
                    set: { if !$0 { presenter.dismissReview() } }
                )) {
                    if let model = presenter.reviewModel {
                        ImportReviewSheet(model: model) { presenter.dismissReview() }
                    }
                }
                .sheet(isPresented: Binding(
                    get: { presenter.progress != nil && presenter.reviewModel == nil },
                    set: { _ in }
                )) {
                    GOGSyncProgressSheet(progress: presenter.progress) { presenter.cancelSync() }
                }
                .focusedSceneValue(\.gogImportPresenter, presenter)
        } else {
            content
        }
    }
}

extension View {
    /// Hosts the GOG import progress + review sheets.
    func gogImportPresentation(_ presenter: GOGImportPresenter?) -> some View {
        modifier(GOGImportPresentation(presenter: presenter))
    }
}

/// A small progress sheet with Cancel, shown while a sync runs (PLAN §14.4).
struct GOGSyncProgressSheet: View {
    let progress: ImportProgress?
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(phaseLabel).font(.headline)
            if let detail = progress?.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 320)
    }

    private var phaseLabel: String {
        switch progress?.phase {
        case .authenticating: return "Signing in…"
        case .fetching: return "Fetching your GOG library…"
        case .staging: return "Saving titles…"
        case .matching: return "Matching to IGDB…"
        case .finished, .none: return "Finishing…"
        }
    }
}

// MARK: - Command

struct GOGImportPresenterFocusedValueKey: FocusedValueKey {
    typealias Value = GOGImportPresenter
}

extension FocusedValues {
    var gogImportPresenter: GOGImportPresenter? {
        get { self[GOGImportPresenterFocusedValueKey.self] }
        set { self[GOGImportPresenterFocusedValueKey.self] = newValue }
    }
}

/// File ▸ Import from GOG… (next to Scan Photos…).
struct GOGImportCommands: Commands {
    @FocusedValue(\.gogImportPresenter) private var presenter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import from GOG…") { presenter?.importFromSource() }
                .disabled(presenter == nil)
                .help("Import your owned GOG library. Sign in first in Settings ▸ Accounts.")
        }
    }
}
