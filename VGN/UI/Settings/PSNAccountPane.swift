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

    // MARK: Safety latch (PLAN §13.5)

    /// The live-PSN safety latch (`psn.liveEnabled`). Read **at launch** by
    /// ``PSNImportBuilder`` to decide whether to build the real PSN objects; this pane only
    /// reads and writes the preference and then asks the owner to relaunch — it never
    /// hot-swaps the wiring, because the sign-in/importer/coordinator are composed once at
    /// launch. Default false = inert everywhere (no stray click can reach Sony).
    private(set) var liveEnabled: Bool
    /// The "Enable PlayStation sync" confirmation is up.
    var enableConfirming = false
    /// The "Turn off PlayStation sync" confirmation is up.
    var disableConfirming = false
    /// The latch was flipped this run, so the effective wiring is stale until relaunch.
    private(set) var latchChanged = false

    /// Preference key of the live-PSN safety latch (shared with ``PSNImportBuilder``).
    static var liveEnabledKey: String { PSNImportBuilder.liveEnabledKey }

    func requestEnableLive() { enableConfirming = true }
    func confirmEnableLive() {
        enableConfirming = false
        AppPreferences.defaults.set(true, forKey: Self.liveEnabledKey)
        liveEnabled = true
        latchChanged = true
    }
    func cancelEnableLive() { enableConfirming = false }

    func requestDisableLive() { disableConfirming = true }
    /// Turn the latch off. Tokens are left untouched (Sign Out clears those); this only
    /// stops the live objects from being built on the next launch.
    func confirmDisableLive() {
        disableConfirming = false
        AppPreferences.defaults.set(false, forKey: Self.liveEnabledKey)
        liveEnabled = false
        latchChanged = true
    }
    func cancelDisableLive() { disableConfirming = false }
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

    #if DEBUG
    /// The DEBUG-only build-steps panel model (PLAN §13.5), attached by ``PSNImportBuilder``
    /// in DEBUG live mode when the latch is armed. nil elsewhere (no panel).
    @ObservationIgnored var buildSteps: PSNBuildStepsModel?
    /// The build-steps sheet is up.
    var showBuildSteps = false
    #endif

    /// The Vault IGDB trait-matching pass (PLAN §16), attached by ``PSNImportBuilder`` in live
    /// mode when IGDB is configured. nil elsewhere (no matching, no status line).
    @ObservationIgnored var vaultMatch: VaultTraitMatchModel?

    /// The optional "I plan to leave PS Plus around" cancellation date (PLAN §16). Persisted in
    /// ``AppPreferences/defaults``; both Play Next scorers read it. Editable directly here.
    @ObservationIgnored let deadline: PSPlusDeadlinePreferences

    /// The deadline picker bindings (PLAN §16). Writing any of them persists the date (or clears
    /// it when the plan is off) and posts the change so an open Play Next recomputes.
    var planningToLeavePSPlus: Bool { didSet { persistDeadline() } }
    var deadlineMonth: Int { didSet { persistDeadline() } }
    var deadlineYear: Int { didSet { persistDeadline() } }

    /// Year choices for the picker: this year through six years out.
    var deadlineYearChoices: [Int] {
        let year = Calendar(identifier: .gregorian).component(.year, from: now())
        return Array(year...(year + 6))
    }
    /// A gentle hint when the picked date is already in the past (PLAN §16).
    var deadlinePastHint: String? {
        guard planningToLeavePSPlus, deadline.isPast(now: now()) else { return nil }
        return "That date is in the past — pick a later month or clear it."
    }

    private func persistDeadline() {
        deadline.picked = planningToLeavePSPlus ? (deadlineYear, deadlineMonth) : nil
    }

    func clearDeadline() { planningToLeavePSPlus = false }

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

    init(backend: any ImportBackend, login: PSNLoginConfig?,
         deadline: PSPlusDeadlinePreferences = PSPlusDeadlinePreferences()) {
        self.backend = backend
        self.login = login
        self.accountLabel = AppPreferences.defaults.string(forKey: Self.accountLabelKey) ?? "test"
        self.liveEnabled = AppPreferences.defaults.bool(forKey: PSNImportBuilder.liveEnabledKey)
        self.deadline = deadline
        // Seed the picker from the stored date, else a sensible near-future default (this month,
        // this year) that is only persisted once the plan is switched on.
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month], from: Date())
        if let picked = deadline.picked {
            self.planningToLeavePSPlus = true
            self.deadlineYear = picked.year
            self.deadlineMonth = picked.month
        } else {
            self.planningToLeavePSPlus = false
            self.deadlineYear = comps.year ?? 2026
            self.deadlineMonth = comps.month ?? 1
        }
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

    /// Surface the DEBUG "run the build steps first" gate message (PLAN §13.5 D10).
    func presentBuildStepsGate() {
        pendingError = ImportErrorSurface(
            title: "Run the PSN build steps first",
            message: "In this development build, sync is gated until every probe and full fetch has succeeded once for the ‘\(accountLabel)’ account. Open Settings ▸ PlayStation ▸ PSN build steps.")
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
            if !model.liveEnabled {
                latchOff
            } else {
                if model.latchChanged { relaunchNote }
                if model.signedIn {
                    signedIn
                } else {
                    signedOut
                }
                vaultSection
                deadlineSection
                turnOffRow
                #if DEBUG
                buildStepsButton
                #endif
            }
            if let error = model.pendingError {
                errorSurface(error)
            }
        }
        .task { await model.refresh() }
        .task { await model.vaultMatch?.refresh() }
        #if DEBUG
        .sheet(isPresented: $model.showBuildSteps) {
            if let steps = model.buildSteps {
                VStack(spacing: 0) {
                    PSNBuildStepsPanel(model: steps)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { model.showBuildSteps = false }.keyboardShortcut(.defaultAction)
                    }.padding(12)
                }
                .frame(minWidth: 480, minHeight: 520)
            }
        }
        #endif
        .confirmationDialog(
            "Enable PlayStation sync?",
            isPresented: $model.enableConfirming, titleVisibility: .visible
        ) {
            Button("Enable") { model.confirmEnableLive() }
            Button("Cancel", role: .cancel) { model.cancelEnableLive() }
        } message: {
            Text("This turns on VGN's use of Sony's unofficial, read-only account API. It runs only when you ask and stops at the first odd response. You'll need to relaunch VGN, then sign in.")
        }
        .confirmationDialog(
            "Turn off PlayStation sync?",
            isPresented: $model.disableConfirming, titleVisibility: .visible
        ) {
            Button("Turn Off", role: .destructive) { model.confirmDisableLive() }
            Button("Cancel", role: .cancel) { model.cancelDisableLive() }
        } message: {
            Text("VGN will make no PlayStation requests until you turn it back on and relaunch. Your sign-in tokens are kept until you Sign Out.")
        }
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

    // MARK: Safety latch (off / turn-off / relaunch)

    /// Shown when the latch is off (all builds): the sync is inert, and enabling it needs a
    /// confirmation + a relaunch (the wiring is composed at launch, never hot-swapped).
    private var latchOff: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PlayStation sync is off").font(.headline)
            riskNote
            Button("Enable PlayStation sync (unofficial API)…") { model.requestEnableLive() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("psn.latch.enable")
            if model.latchChanged { relaunchNote }
        }
    }

    /// A prominent "relaunch to apply" note shown after the latch is flipped this run.
    private var relaunchNote: some View {
        Label("Relaunch VGN to apply.", systemImage: "arrow.clockwise.circle")
            .font(.callout).foregroundStyle(.orange)
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The "Turn off…" action shown while the latch is on (clears the latch; tokens are
    /// left untouched until Sign Out).
    private var turnOffRow: some View {
        Button("Turn off PlayStation sync…") { model.requestDisableLive() }
            .controlSize(.small)
            .accessibilityIdentifier("psn.latch.disable")
    }

    #if DEBUG
    /// Opens the DEBUG build-steps panel (only present in DEBUG live builds with the latch
    /// armed) in a sheet, so this pane keeps its `settingsPane()` sizing.
    @ViewBuilder
    private var buildStepsButton: some View {
        if model.buildSteps != nil {
            Divider()
            Button("PSN build steps…") { model.showBuildSteps = true }
                .controlSize(.small)
                .accessibilityIdentifier("psn.buildSteps.open")
                .help("Run the gated live steps (S2–S6) one request at a time.")
        }
    }
    #endif

    // MARK: The Vault (PLAN §16)

    /// The Vault trait-matching status ("Vault: N of M matched") + "Match more now", shown once
    /// there are PS Plus entries to match. Hidden entirely otherwise (no PS Plus in the Vault, or
    /// IGDB not configured so no matcher was built).
    @ViewBuilder
    private var vaultSection: some View {
        if let vault = model.vaultMatch, vault.hasEntries {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("The Vault", systemImage: "archivebox").font(.callout).bold()
                HStack(spacing: 8) {
                    if vault.isRunning { ProgressView().controlSize(.small) }
                    Text(vault.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Match more now") { vault.matchMoreNow() }
                        .controlSize(.small)
                        .disabled(!vault.canMatchMore)
                        .accessibilityIdentifier("psn.vault.matchMore")
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: PS Plus deadline (PLAN §16)

    private static let monthSymbols = Calendar(identifier: .gregorian).monthSymbols

    /// "I plan to leave PS Plus around [month] [year]" (PLAN §16): an optional date that ramps a
    /// boost for PS Plus games as it approaches. Menu-style pickers (never in click tests).
    private var deadlineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Toggle("I plan to leave PS Plus around a date", isOn: $model.planningToLeavePSPlus)
                .accessibilityIdentifier("psn.deadline.toggle")
            if model.planningToLeavePSPlus {
                HStack(spacing: 8) {
                    Picker("Month", selection: $model.deadlineMonth) {
                        ForEach(1...12, id: \.self) { m in
                            Text(Self.monthSymbols[m - 1]).tag(m)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("psn.deadline.month")
                    Picker("Year", selection: $model.deadlineYear) {
                        ForEach(model.deadlineYearChoices, id: \.self) { y in
                            Text(String(y)).tag(y)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("psn.deadline.year")
                    Button("Clear") { model.clearDeadline() }
                        .controlSize(.small)
                        .accessibilityIdentifier("psn.deadline.clear")
                }
                if let hint = model.deadlinePastHint {
                    Label(hint, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("PS Plus games (and Vault entries) get a gentle nudge that grows as the date nears, scaled by whether you can still finish them in time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
