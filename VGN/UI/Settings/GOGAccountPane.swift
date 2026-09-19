import SwiftUI

/// Configuration the login sheet needs (nil ⇒ sign-in unavailable, e.g. sample/test
/// mode where nothing GOG touches the network or the Keychain).
struct GOGLoginConfig: Sendable {
    var authorizationURL: URL
    var policy: GOGLoginNavigationPolicy
}

/// A pending Force-refresh confirmation (PLAN §14.2 — state the request cost and the
/// cached data's age before spending requests).
struct ForceRefreshConfirmation: Identifiable, Equatable, Sendable {
    var dataSet: ImportDataSet
    var costText: String
    var ageText: String
    var id: String { dataSet.id }
    var message: String { "Re-fetching \(dataSet.title) makes \(costText) to GOG. The cached copy is \(ageText)." }
}

/// A clear, specific error surface for a stopped/failed sync (PLAN §14.5). Built from an
/// ``ImportError`` so the reject reason, the "stopped, made no further requests" sentence
/// and the redacted excerpt all reach the UI.
struct ImportErrorSurface: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var message: String
    var stoppedNote: String?
    var excerpt: String?

    static func make(from error: Error, sourceLabel: String) -> ImportErrorSurface {
        let stopped = "VGN stopped and made no further requests."
        if let importError = error as? ImportError {
            switch importError {
            case .rejected(let reject):
                return ImportErrorSurface(
                    title: "\(sourceLabel) sync stopped", message: reject.reason.message,
                    stoppedNote: stopped,
                    excerpt: reject.redactedExcerpt.isEmpty ? nil : reject.redactedExcerpt)
            case .budgetExceeded(let limit):
                return ImportErrorSurface(
                    title: "\(sourceLabel) sync stopped",
                    message: "The request budget (\(limit)) was reached before the sync finished.",
                    stoppedNote: stopped, excerpt: nil)
            case .notAuthenticated:
                return ImportErrorSurface(
                    title: "Signed out of \(sourceLabel)",
                    message: "Sign in to \(sourceLabel) again to sync.", stoppedNote: nil, excerpt: nil)
            case .disallowedURL(let url):
                return ImportErrorSurface(
                    title: "\(sourceLabel) sync stopped",
                    message: "A request to an unexpected address was blocked.",
                    stoppedNote: stopped, excerpt: url)
            }
        }
        return ImportErrorSurface(
            title: "\(sourceLabel) sync failed",
            message: (error as NSError).localizedDescription, stoppedNote: nil, excerpt: nil)
    }
}

/// State behind Settings ▸ Accounts ▸ GOG (PLAN §14.2). Drives sign-in / sign-out,
/// cache age per data set, Force refresh (with a cost+age confirmation) and Sync Now.
/// The sync + review sheet are run by the presenter (`onSyncRequested`); this model owns
/// the account state and the error/confirmation surfaces so it is fully testable with a
/// ``FakeImportBackend``.
@MainActor
@Observable
final class GOGAccountModel {
    let backend: any ImportBackend
    let login: GOGLoginConfig?

    private(set) var signedIn = false
    private(set) var username: String?
    private(set) var cacheAges: [ImportCacheAge] = []
    private(set) var lastSync: Date?
    private(set) var isBusy = false

    var showLogin = false
    var forceRefreshConfirmation: ForceRefreshConfirmation?
    var signOutConfirming = false
    var signOutAlsoWipeCache = false
    var pendingError: ImportErrorSurface?

    /// Wired by the presenter: run one sync and present the review sheet.
    var onSyncRequested: () -> Void = {}

    /// Injected in tests for deterministic ages/relative strings.
    var now: () -> Date = { Date() }

    var dataSets: [ImportDataSet] { backend.dataSets }
    var sourceLabel: String { backend.sourceLabel }
    var canSignIn: Bool { login != nil }

    init(backend: any ImportBackend, login: GOGLoginConfig?) {
        self.backend = backend
        self.login = login
    }

    /// Reload account state (on appear / after a sign-in or sync).
    func refresh() async {
        signedIn = await backend.hasSession()
        username = signedIn ? await backend.username() : nil
        cacheAges = await backend.cacheAges()
        lastSync = cacheAges.map(\.fetchedAt).max()
    }

    // MARK: Sign in / out

    func beginSignIn() { guard canSignIn else { return }; showLogin = true }

    func completeSignIn(code: String) {
        showLogin = false
        isBusy = true
        Task {
            do { try await backend.completeSignIn(code: code) }
            catch { pendingError = ImportErrorSurface.make(from: error, sourceLabel: sourceLabel) }
            await refresh()
            isBusy = false
        }
    }

    func cancelSignIn() { showLogin = false }
    func loginFailed(_ reason: String) {
        showLogin = false
        pendingError = ImportErrorSurface(title: "\(sourceLabel) sign-in failed", message: reason)
    }

    func requestSignOut() { signOutConfirming = true }
    func confirmSignOut() {
        signOutConfirming = false
        let wipe = signOutAlsoWipeCache
        Task {
            try? await backend.signOut(alsoWipeCache: wipe)
            await refresh()
        }
    }

    // MARK: Sync / force refresh

    func syncNow() { onSyncRequested() }

    /// Build the Force-refresh confirmation for a data set, stating cost + cached age.
    func requestForceRefresh(_ dataSet: ImportDataSet) {
        forceRefreshConfirmation = ForceRefreshConfirmation(
            dataSet: dataSet,
            costText: costText(for: dataSet),
            ageText: ageText(for: dataSet))
    }

    func confirmForceRefresh() {
        guard let dataSet = forceRefreshConfirmation?.dataSet else { return }
        forceRefreshConfirmation = nil
        Task {
            do {
                try await backend.forceRefresh(dataSetID: dataSet.id)
                onSyncRequested()
            } catch {
                pendingError = ImportErrorSurface.make(from: error, sourceLabel: sourceLabel)
            }
        }
    }

    /// Surface an error thrown by a sync (called by the presenter). Pure mapping.
    func present(error: Error) {
        pendingError = ImportErrorSurface.make(from: error, sourceLabel: sourceLabel)
    }

    // MARK: Text helpers

    func costText(for dataSet: ImportDataSet) -> String {
        let n = max(1, dataSet.estimatedRequests)
        return n == 1 ? "1 request" : "up to \(n) requests"
    }

    func ageText(for dataSet: ImportDataSet) -> String {
        guard let fetched = cacheAges.filter({ $0.endpoint == dataSet.id }).map(\.fetchedAt).max() else {
            return "not cached yet"
        }
        return Self.ageString(from: fetched, now: now())
    }

    /// A short "N days/hours old" string (deterministic; no wall-clock reads in a body).
    static func ageString(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let days = Int(seconds / 86_400)
        if days >= 1 { return days == 1 ? "1 day old" : "\(days) days old" }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return hours == 1 ? "1 hour old" : "\(hours) hours old" }
        let minutes = Int(seconds / 60)
        if minutes >= 1 { return minutes == 1 ? "1 minute old" : "\(minutes) minutes old" }
        return "just now"
    }

    func ageString(for age: ImportCacheAge) -> String { Self.ageString(from: age.fetchedAt, now: now()) }
}

// MARK: - Pane

/// Settings ▸ Accounts ▸ GOG (PLAN §14.2).
struct GOGAccountPane: View {
    @Bindable var model: GOGAccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.signedIn {
                signedIn
            } else {
                signedOut
            }
            if let error = model.pendingError {
                errorSurface(error)
            }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $model.showLogin) {
            if let login = model.login {
                GOGLoginSheet(
                    authorizationURL: login.authorizationURL,
                    policy: login.policy,
                    completeSignIn: { code in model.completeSignIn(code: code) },
                    onCancel: { model.cancelSignIn() })
            }
        }
        .confirmationDialog(
            model.forceRefreshConfirmation?.message ?? "",
            isPresented: Binding(get: { model.forceRefreshConfirmation != nil },
                                 set: { if !$0 { model.forceRefreshConfirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Force Refresh") { model.confirmForceRefresh() }
            Button("Cancel", role: .cancel) { model.forceRefreshConfirmation = nil }
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not signed in.").foregroundStyle(.secondary)
            Button("Sign In to GOG…") { model.beginSignIn() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSignIn)
                .help(model.canSignIn ? "Sign in on GOG's own page in a private window."
                      : "Sign-in is available in the running app.")
            Text("VGN opens GOG's own login page in a private window and only ever keeps the sign-in tokens — never your password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.username ?? "Signed in", systemImage: "person.crop.circle.fill.badge.checkmark")
                Spacer()
                if let last = model.lastSync {
                    Text("Last sync \(GOGAccountModel.ageString(from: last, now: model.now()))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Never synced").font(.caption).foregroundStyle(.secondary)
                }
            }

            dataSetRows

            HStack {
                Button("Sync Now") { model.syncNow() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Sign Out…", role: .destructive) { model.requestSignOut() }
            }
            if model.signOutConfirming {
                signOutRow
            }
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var dataSetRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.dataSets) { dataSet in
                HStack {
                    Text(dataSet.title)
                    Spacer()
                    Text(model.ageText(for: dataSet)).font(.caption).foregroundStyle(.secondary)
                    Button("Force Refresh…") { model.requestForceRefresh(dataSet) }
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var signOutRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Also delete cached GOG responses", isOn: $model.signOutAlsoWipeCache)
            HStack {
                Button("Sign Out", role: .destructive) { model.confirmSignOut() }
                Button("Keep signed in") { model.signOutConfirming = false }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Error

    private func errorSurface(_ error: ImportErrorSurface) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.message).font(.callout)
            if let note = error.stoppedNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let excerpt = error.excerpt {
                DisclosureGroup("Response excerpt") {
                    Text(excerpt).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            Button("Dismiss") { model.pendingError = nil }.controlSize(.small)
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

#if DEBUG
extension GOGAccountModel {
    /// A signed-in preview/test model over a fake backend (no network / Keychain).
    static func preview(signedIn: Bool = true, error: ImportErrorSurface? = nil) -> GOGAccountModel {
        let db = try! AppDatabase.inMemory()
        let backend = FakeImportBackend(
            dataSets: [
                ImportDataSet(id: GOGEndpoint.userData, title: "Account", estimatedRequests: 1),
                ImportDataSet(id: GOGEndpoint.ownedGames, title: "Owned games", estimatedRequests: 1),
                ImportDataSet(id: GOGEndpoint.filteredProducts, title: "Library", estimatedRequests: 5),
            ],
            staging: ImportStagingStore(db),
            session: signedIn, username: signedIn ? "gog_gamer" : nil)
        let model = GOGAccountModel(backend: backend, login: nil)
        model.pendingError = error
        return model
    }
}
#endif
