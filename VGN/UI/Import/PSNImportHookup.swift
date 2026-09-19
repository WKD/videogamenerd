import AppKit
import SwiftUI

// App-level hookup for the PSN import flow (PLAN §13): a presenter the container builds
// once, a view modifier that hosts the progress + review sheets, and the "Import from
// PlayStation…" command. Mirrors `GOGImportHookup` so the hot root/container files change
// by one line each. `ResilientImportMatcher` is shared with GOG.

/// Owns the presentation state of the PSN sync flow (progress sheet → review sheet). One
/// per window/container. Live only — in sample/seeded/test modes the injected backend is a
/// fake/inert one that never touches the network or the Keychain.
@MainActor
@Observable
final class PSNImportPresenter {
    let backend: any ImportBackend
    /// The Settings account model, so a sync's errors surface there and state refreshes.
    weak var account: PSNAccountModel?

    /// The PlayStation platform slugs offered in the review sheet's per-row platform menu.
    static let platformChoices = ["ps5", "ps4", "ps3", "ps2", "ps1", "vita", "psp"]

    /// Non-nil while the review sheet is up.
    var reviewModel: ImportReviewModel?
    /// The latest progress while a sync runs (nil once the review sheet opens).
    private(set) var progress: ImportProgress?
    private(set) var isSyncing = false

    private let onLibraryChanged: () -> Void
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(backend: any ImportBackend, onLibraryChanged: @escaping () -> Void = {}) {
        self.backend = backend
        self.onLibraryChanged = onLibraryChanged
    }

    /// File ▸ Import from PlayStation…: start a sync when signed in, else open Settings.
    func importFromSource() {
        if account?.signedIn == true {
            syncNow()
        } else {
            Self.openSettings()
        }
    }

    /// Run one sync and open the review sheet on success (PLAN §13.5). Cache-first, so a
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
                self.reviewModel = ImportReviewModel(
                    source: backend.source, sourceLabel: backend.sourceLabel,
                    staging: backend.staging, result: result,
                    productFormat: .digital,
                    platformChoices: Self.platformChoices,
                    onLibraryChanged: onLibraryChanged)
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

    /// Open the Settings window — the sign-in entry point when a sync is requested while
    /// signed out.
    static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - View hookup

private struct PSNImportPresentation: ViewModifier {
    let presenter: PSNImportPresenter?

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
                    PSNSyncProgressSheet(progress: presenter.progress) { presenter.cancelSync() }
                }
                .focusedSceneValue(\.psnImportPresenter, presenter)
        } else {
            content
        }
    }
}

extension View {
    /// Hosts the PSN import progress + review sheets.
    func psnImportPresentation(_ presenter: PSNImportPresenter?) -> some View {
        modifier(PSNImportPresentation(presenter: presenter))
    }
}

/// A small progress sheet with Cancel, shown while a sync runs (PLAN §13.5).
struct PSNSyncProgressSheet: View {
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
        case .fetching: return "Fetching your PlayStation library…"
        case .staging: return "Saving titles…"
        case .matching: return "Matching to IGDB…"
        case .finished, .none: return "Finishing…"
        }
    }
}

// MARK: - Command

struct PSNImportPresenterFocusedValueKey: FocusedValueKey {
    typealias Value = PSNImportPresenter
}

extension FocusedValues {
    var psnImportPresenter: PSNImportPresenter? {
        get { self[PSNImportPresenterFocusedValueKey.self] }
        set { self[PSNImportPresenterFocusedValueKey.self] = newValue }
    }
}

/// File ▸ Import from PlayStation… (next to Import from GOG…). Disabled with a hint when
/// no presenter is available; when signed out it opens Settings ▸ PlayStation.
struct PSNImportCommands: Commands {
    @FocusedValue(\.psnImportPresenter) private var presenter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import from PlayStation…") { presenter?.importFromSource() }
                .disabled(presenter == nil)
                .help("Import your PlayStation library. Sign in first in Settings ▸ PlayStation.")
        }
    }
}
