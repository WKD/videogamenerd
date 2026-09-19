import SwiftUI

/// Configuration the PSN login sheet needs (nil ⇒ sign-in unavailable, e.g. sample/test
/// mode where nothing PSN touches the network or the Keychain). PSN's sign-in reads an
/// **NPSSO** cookie after a web login (route 1), not an OAuth redirect code, so this
/// carries the login URL, the pure navigation policy and the cookie's name/domain.
struct PSNLoginConfig: Sendable {
    var loginURL: URL
    var policy: PSNLoginNavigationPolicy
    var npssoCookieName: String
    var npssoCookieDomain: String
}

/// A pending Force-refresh confirmation for PSN (PLAN §13.5 — state the request cost and
/// the cached data's age before spending requests). PlayStation-worded twin of
/// ``ForceRefreshConfirmation`` (kept separate so the GOG type is untouched).
struct PSNForceRefreshConfirmation: Identifiable, Equatable, Sendable {
    var dataSet: ImportDataSet
    var costText: String
    var ageText: String
    var id: String { dataSet.id }
    var message: String {
        "Re-fetching \(dataSet.title) makes \(costText) to PlayStation. The cached copy is \(ageText)."
    }
}

/// State behind Settings ▸ PlayStation (PLAN §13.1 / §13.5). Drives sign-in (web login or
/// a pasted NPSSO), sign-out, cache age per data set, Force refresh (with a cost+age
/// confirmation) and Sync Now. The sync + review sheet are run by the presenter
/// (`onSyncRequested`); this model owns the account state and the error/confirmation
/// surfaces so it is fully testable with a ``FakeImportBackend`` — no network, no Keychain.
///
/// The pasted/streamed NPSSO is **never** echoed: it lives only in ``npssoInput`` (a
/// SecureField), is cleared after use, and never reaches a log, a label or an error string.
@MainActor
@Observable
final class PSNAccountModel {
    let backend: any ImportBackend
    let login: PSNLoginConfig?

    private(set) var signedIn = false
    /// The signed-in **online id** — never the account id (PLAN §13.1).
    private(set) var onlineID: String?
    private(set) var cacheAges: [ImportCacheAge] = []
    private(set) var lastSync: Date?
    /// When the session must be renewed (refresh-token expiry), for "sign in again after…".
    private(set) var sessionExpiry: Date?
    private(set) var isBusy = false

    var showLogin = false
    /// The "Paste NPSSO instead" disclosure is expanded.
    var pasteExpanded = false
    /// The NPSSO the owner pastes — never echoed anywhere but this SecureField; cleared
    /// the instant it is used.
    var npssoInput = ""
    var forceRefreshConfirmation: PSNForceRefreshConfirmation?
    var signOutConfirming = false
    var signOutAlsoWipeCache = false
    var pendingError: ImportErrorSurface?

    /// The build-steps account label (`test` / `real`, PLAN §13.5), persisted so it
    /// survives relaunch. Used by the DEBUG build-steps panel and by the live sync's
    /// probe scope. Default `test` (never the real account first).
    var accountLabel: String {
        didSet {
            guard accountLabel != oldValue else { return }
            AppPreferences.defaults.set(accountLabel, forKey: Self.accountLabelKey)
        }
    }
    static let accountLabelKey = "psn.buildSteps.accountLabel"

    /// Wired by the presenter: run one sync and present the review sheet.
    var onSyncRequested: () -> Void = {}
    /// Injected in tests for deterministic ages/relative strings.
    var now: () -> Date = { Date() }
    /// Injected by the builder in live mode to read the session-renewal deadline from the
    /// PSN auth actor (nil in inert/test mode).
    var sessionExpiryProvider: @Sendable () async -> Date? = { nil }

    var dataSets: [ImportDataSet] { backend.dataSets }
    var sourceLabel: String { backend.sourceLabel }
    var canSignIn: Bool { login != nil }

    init(backend: any ImportBackend, login: PSNLoginConfig?) {
        self.backend = backend
        self.login = login
        self.accountLabel = AppPreferences.defaults.string(forKey: Self.accountLabelKey) ?? "test"
    }

    /// Reload account state (on appear / after a sign-in or sync).
    func refresh() async {
        signedIn = await backend.hasSession()
        onlineID = signedIn ? await backend.username() : nil
        cacheAges = await backend.cacheAges()
        lastSync = cacheAges.map(\.fetchedAt).max()
        sessionExpiry = signedIn ? await sessionExpiryProvider() : nil
    }

    // MARK: Sign in / out

    func beginSignIn() { guard canSignIn else { return }; showLogin = true }

    /// Complete a web-login (the sheet passes the NPSSO it read from the cookie store).
    func completeSignIn(npsso: String) {
        showLogin = false
        exchange(npsso: npsso)
    }

    /// The "Paste NPSSO instead" route: validate the shape (never echoing the value), then
    /// exchange it and clear the field.
    func submitPastedNPSSO() {
        let trimmed = npssoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PSNAuth.isPlausibleNPSSO(trimmed) else {
            pendingError = ImportErrorSurface(
                title: "That NPSSO doesn't look right",
                message: "An NPSSO is a long string of letters and numbers. Copy it again from the npsso cookie.")
            return
        }
        npssoInput = ""
        pasteExpanded = false
        exchange(npsso: trimmed)
    }

    private func exchange(npsso: String) {
        isBusy = true
        Task {
            do { try await backend.completeSignIn(code: npsso) }
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

    func requestForceRefresh(_ dataSet: ImportDataSet) {
        forceRefreshConfirmation = PSNForceRefreshConfirmation(
            dataSet: dataSet, costText: costText(for: dataSet), ageText: ageText(for: dataSet))
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

/// Settings ▸ PlayStation (PLAN §13.1 / §13.5).
struct PSNAccountPane: View {
    @Bindable var model: PSNAccountModel

    private static let expiryFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

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
                PSNLoginSheet(
                    config: login,
                    completeSignIn: { npsso in model.completeSignIn(npsso: npsso) },
                    onCancel: { model.cancelSignIn() },
                    onFailed: { reason in model.loginFailed(reason) })
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Not signed in.").foregroundStyle(.secondary)
            Button("Sign In to PlayStation…") { model.beginSignIn() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSignIn)
                .help(model.canSignIn ? "Sign in on Sony's own page in a private window."
                      : "Sign-in is available in the running app.")

            DisclosureGroup("Paste NPSSO instead", isExpanded: $model.pasteExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("npsso", text: $model.npssoInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("psn.npsso.field")
                    Button("Use NPSSO") { model.submitPastedNPSSO() }
                        .disabled(model.npssoInput.isEmpty || !model.canSignIn)
                    Text("Paste the value of the npsso cookie from a browser already signed in to PlayStation. It is used once and never stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.callout)

            riskNote
        }
    }

    /// The plain-language risk note (PLAN §13.1, three lines).
    private var riskNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VGN uses Sony's **unofficial** account API — there is no public one.")
            Text("It is **read-only** and runs only when you ask; it stops at the first odd response.")
            Text("VGN keeps only the sign-in tokens, in your Keychain — never your password or NPSSO.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Signed in

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.onlineID ?? "Signed in", systemImage: "person.crop.circle.fill.badge.checkmark")
                Spacer()
                if let last = model.lastSync {
                    Text("Last sync \(PSNAccountModel.ageString(from: last, now: model.now()))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Never synced").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let expiry = model.sessionExpiry {
                Text("Sign in again after \(Self.expiryFormatter.string(from: expiry))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            dataSetRows

            HStack {
                Button("Sync Now") { model.syncNow() }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Sign Out…", role: .destructive) { model.requestSignOut() }
            }
            if model.signOutConfirming { signOutRow }
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
            Toggle("Also delete cached PlayStation responses", isOn: $model.signOutAlsoWipeCache)
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
extension PSNAccountModel {
    /// A preview/test model over a fake backend (no network / Keychain).
    static func preview(signedIn: Bool = true, error: ImportErrorSurface? = nil) -> PSNAccountModel {
        let db = try! AppDatabase.inMemory()
        let backend = FakeImportBackend(
            source: ImportSourceID.psn, sourceLabel: "PlayStation",
            dataSets: [
                ImportDataSet(id: PSNEndpoint.profile, title: "Profile", estimatedRequests: 1),
                ImportDataSet(id: PSNEndpoint.trophyTitles, title: "Trophy titles", estimatedRequests: 4),
                ImportDataSet(id: PSNEndpoint.gameList, title: "Game list", estimatedRequests: 3),
                ImportDataSet(id: PSNEndpoint.purchases, title: "Purchases", estimatedRequests: 4),
            ],
            staging: ImportStagingStore(db),
            session: signedIn, username: signedIn ? "nerd_ps" : nil)
        let model = PSNAccountModel(backend: backend, login: nil)
        model.pendingError = error
        return model
    }
}
#endif
