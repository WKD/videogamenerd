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

    /// Whether the live-PSN safety latch was armed at launch (PLAN §13.5). When false the
    /// live objects were never built (the backend is inert), so File ▸ Import from
    /// PlayStation… is disabled with a "turn it on in Settings" hint.
    let liveEnabled: Bool

    /// The PlayStation platform slugs offered in the review sheet's per-row platform menu.
    static let platformChoices = ["ps5", "ps4", "ps3", "ps2", "ps1", "vita", "psp"]

    /// Select the PS Plus Vault sidebar row ("Show in the Vault" in the review sheet, PLAN §16).
    /// Wired by the composition root to the library view model.
    @ObservationIgnored var onShowInVault: () -> Void = {}

    /// Non-nil while the review sheet is up.
    var reviewModel: ImportReviewModel?
    /// The latest progress while a sync runs (nil once the review sheet opens).
    private(set) var progress: ImportProgress?
    private(set) var isSyncing = false

    private let onLibraryChanged: () -> Void
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(backend: any ImportBackend, liveEnabled: Bool = false,
         onLibraryChanged: @escaping () -> Void = {}) {
        self.backend = backend
        self.liveEnabled = liveEnabled
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

    /// In DEBUG live builds the normal sync refuses until the build-steps panel has run
    /// every probe and full fetch once for the current account label (PLAN §13.5 D10).
    /// Release is unchanged — the client's own probe-before-full guard still applies.
    /// Returns true when the sync may proceed; false surfaces the "run the build steps" note.
    private func passesBuildStepsGate() -> Bool {
        #if DEBUG
        guard liveEnabled else { return true }
        // The build-steps panel and this gate share the persisted account label, so read it
        // from the preference rather than the (possibly stale) account model copy.
        let label = AppPreferences.defaults.string(forKey: PSNAccountModel.accountLabelKey) ?? "test"
        guard PSNBuildStepsGate.hasPassedAll(label: label) else {
            account?.presentBuildStepsGate()
            return false
        }
        #endif
        return true
    }

    /// Run one sync and open the review sheet on success (PLAN §13.5). Cache-first, so a
    /// second sync inside the window makes no requests.
    func syncNow() {
        guard reviewModel == nil, !isSyncing else { return }
        guard passesBuildStepsGate() else { return }
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
                // The Vault (PLAN §16): upsert the PS Plus claims this sync vaulted, and remove
                // any that vanished or crossed the 10-minute gate. A separate shelf — never the
                // library. Belt-and-braces guard: only when this sync actually vaulted claims.
                if backend.source == ImportSourceID.psn, !result.vaultPresentIDs.isEmpty {
                    _ = try? await RomCatalogStore(backend.staging.database)
                        .syncPSNVault(entries: result.vaultEntries,
                                      presentExternalIDs: result.vaultPresentIDs)
                    // Fill the freshly-vaulted claims with IGDB traits in the background so they
                    // can be suggested in "From the vault" (PLAN §16). Capped, one run at a time.
                    self.account?.vaultMatch?.refreshAndRun()
                }
                let review = ImportReviewModel(
                    source: backend.source, sourceLabel: backend.sourceLabel,
                    staging: backend.staging, result: result,
                    productFormat: .digital,
                    platformChoices: Self.platformChoices,
                    onLibraryChanged: onLibraryChanged)
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

/// A small progress sheet with Cancel, shown while a sync runs (PLAN §13.5). During the
/// matching phase it shows a determinate bar, "Matching N of M · Title" and an estimated time
/// remaining once the rate settles (coordinator 2026-09-20).
struct PSNSyncProgressSheet: View {
    let progress: ImportProgress?
    var onCancel: () -> Void = {}
    /// Injected for deterministic previews/tests; the app uses the wall clock.
    var now: () -> Date = { Date() }

    @State private var matchingStart: Date?

    var body: some View {
        VStack(spacing: 14) {
            if progress?.phase == .matching {
                matchingBody
            } else {
                ProgressView().controlSize(.large)
                Text(phaseLabel).font(.headline)
                if let detail = progress?.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("psn.sync.cancel")
        }
        .padding(28)
        .frame(minWidth: 340)
        .onChange(of: progress?.phase) { _, phase in
            if phase == .matching, matchingStart == nil { matchingStart = now() }
        }
    }

    @ViewBuilder
    private var matchingBody: some View {
        let completed = progress?.completed ?? 0
        let total = progress?.total
        let fraction = ImportMatchProgress.fraction(completed: completed, total: total)
        if let fraction {
            ProgressView(value: fraction).controlSize(.large).frame(width: 240)
        } else {
            ProgressView().controlSize(.large)
        }
        Text(ImportMatchProgress.label(completed: completed, total: total, title: progress?.detail ?? ""))
            .font(.headline).lineLimit(1)
        if let start = matchingStart,
           let eta = ImportMatchProgress.etaText(completed: completed, total: total,
                                                 elapsedSeconds: now().timeIntervalSince(start)) {
            Text(eta).font(.caption).foregroundStyle(.secondary)
        }
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
                .disabled(presenter == nil || presenter?.liveEnabled != true)
                .help(presenter?.liveEnabled == true
                      ? "Import your PlayStation library. Sign in first in Settings ▸ PlayStation."
                      : "Enable it in Settings ▸ PlayStation")
        }
    }
}
