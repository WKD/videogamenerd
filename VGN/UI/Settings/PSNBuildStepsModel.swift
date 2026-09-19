#if DEBUG
import Foundation

/// Drives the DEBUG-only "PSN build steps" panel (PLAN §13.5): one button per gated live
/// step, run one at a time, WITH the owner. `@MainActor @Observable`, fully testable over a
/// ``ScriptedPSNBuildRunner`` (no network, no Keychain). It never talks to Sony itself — it
/// only asks the injected ``PSNBuildRunner`` to make the exact request of the step the owner
/// clicked, records the redacted outcome, and **locks on any reject** until the owner
/// acknowledges. The correctness of the enable/disable and lock logic is a safety matter.
@MainActor
@Observable
final class PSNBuildStepsModel {
    /// One panel row's state.
    struct StepRow: Identifiable, Equatable, Sendable {
        let kind: PSNBuildStepKind
        var status: Status = .idle
        var outcome: PSNBuildStepOutcome?
        /// A one-line redacted summary ("HTTP 200 · 8 items · from network · 1.2 KB · 0.04s").
        var summary: String?
        /// The redacted stop excerpt when this step failed.
        var rejectExcerpt: String?
        var id: String { kind.id }
    }
    enum Status: Sendable, Equatable { case idle, running, passed, failed }

    /// A pending confirmation (a single dialog drives all four).
    enum Confirm: Equatable, Sendable {
        case fullFetch(PSNBuildStepKind)       // "up to N requests — continue?"
        case realFullFetch(PSNBuildStepKind)   // the real-account second confirmation
        case retry(PSNBuildStepKind)           // "Try this step again"
        case wipe
    }

    private let runner: any PSNBuildRunner
    let budgetLimit: Int

    private(set) var rows: [StepRow]
    private(set) var signedIn = false
    private(set) var onlineID: String?
    private(set) var requestsUsed = 0
    private(set) var isRunning = false

    /// Non-nil ⇒ the panel is **locked**: a reject stopped everything and every button is
    /// disabled until ``acknowledge()`` (PLAN §13.5). Carries the stop message.
    private(set) var rejectMessage: String?
    /// The step that failed (needs an explicit "Try this step again" after acknowledging).
    private(set) var failedStep: PSNBuildStepKind?

    var pendingConfirm: Confirm?

    /// `test` / `real`, persisted (shared key with ``PSNAccountModel``). Switching it resets
    /// the panel to what is recorded for THAT label (PLAN §13.3).
    var accountLabel: String {
        didSet {
            guard accountLabel != oldValue else { return }
            AppPreferences.defaults.set(accountLabel, forKey: PSNAccountModel.accountLabelKey)
            reloadForLabel()
        }
    }

    var isRealAccount: Bool { accountLabel == "real" }

    init(runner: any PSNBuildRunner, accountLabel: String? = nil) {
        self.runner = runner
        self.budgetLimit = runner.budgetLimit
        let label = accountLabel
            ?? AppPreferences.defaults.string(forKey: PSNAccountModel.accountLabelKey) ?? "test"
        self.accountLabel = label
        self.rows = PSNBuildStepKind.allCases.map { kind in
            StepRow(kind: kind, status: PSNBuildStepsGate.hasPassed(label: label, kind: kind) ? .passed : .idle)
        }
    }

    // MARK: - Refresh / label switch

    func refresh() async {
        signedIn = await runner.hasSession()
        onlineID = await runner.onlineID()
        requestsUsed = await runner.requestsUsed(label: accountLabel)
    }

    private func reloadForLabel() {
        rejectMessage = nil
        failedStep = nil
        pendingConfirm = nil
        rows = PSNBuildStepKind.allCases.map { kind in
            StepRow(kind: kind, status: PSNBuildStepsGate.hasPassed(label: accountLabel, kind: kind) ? .passed : .idle)
        }
        Task { requestsUsed = await runner.requestsUsed(label: accountLabel) }
    }

    // MARK: - Enable / disable (unit-tested as a matrix)

    /// Whether `kind`'s prerequisites have all passed for the current label.
    func passed(_ kind: PSNBuildStepKind) -> Bool {
        PSNBuildStepsGate.hasPassed(label: accountLabel, kind: kind)
    }

    /// Whether the normal run button for `kind` is enabled (PLAN §13.5): not while another
    /// step runs, not while locked, not before sign-in, only when every prerequisite has
    /// passed for this label, and never the failed step (that shows a Retry affordance).
    func isEnabled(_ kind: PSNBuildStepKind) -> Bool {
        guard !isRunning, rejectMessage == nil, signedIn else { return false }
        guard failedStep != kind else { return false }
        return kind.prerequisites.allSatisfy { passed($0) }
    }

    /// The failed step, after acknowledging, offers an explicit "Try this step again".
    func needsRetry(_ kind: PSNBuildStepKind) -> Bool {
        !isRunning && rejectMessage == nil && failedStep == kind
    }

    var canWipe: Bool { !isRunning && rejectMessage == nil }
    var canCopyReport: Bool { true }

    // MARK: - Button actions

    /// The button tap. Probes run immediately; a full fetch confirms ("up to N — continue?",
    /// plus a second confirmation on the real account) first.
    func activate(_ kind: PSNBuildStepKind) {
        guard isEnabled(kind) else { return }
        if kind.isFullFetch {
            pendingConfirm = .fullFetch(kind)
        } else {
            perform(kind)
        }
    }

    func requestRetry(_ kind: PSNBuildStepKind) {
        guard needsRetry(kind) else { return }
        pendingConfirm = .retry(kind)
    }

    func requestWipe() { guard canWipe else { return }; pendingConfirm = .wipe }

    func confirmPending() {
        guard let confirm = pendingConfirm else { return }
        pendingConfirm = nil
        switch confirm {
        case .fullFetch(let kind):
            if isRealAccount { pendingConfirm = .realFullFetch(kind) } else { perform(kind) }
        case .realFullFetch(let kind):
            perform(kind)
        case .retry(let kind):
            perform(kind)
        case .wipe:
            performWipe()
        }
    }

    func cancelPending() { pendingConfirm = nil }

    /// Clear the reject lock. Re-enables only steps whose prerequisites still hold (the
    /// failed step's flag was never set, so its dependents stay disabled); the failed step
    /// itself needs the explicit Retry (PLAN §13.5).
    func acknowledge() {
        rejectMessage = nil
    }

    // MARK: - Execution

    private func perform(_ kind: PSNBuildStepKind) {
        guard !isRunning else { return }
        isRunning = true
        if failedStep == kind { failedStep = nil }
        setStatus(kind, .running)
        setExcerpt(kind, nil)
        let label = accountLabel
        Task { [runner] in
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let outcome = try await runner.run(kind, label: label)
                let elapsed = start.duration(to: clock.now)
                markSuccess(kind, outcome: outcome, elapsed: elapsed, label: label)
            } catch {
                markFailure(kind, error: error)
            }
            requestsUsed = await runner.requestsUsed(label: label)
            isRunning = false
        }
    }

    private func performWipe() {
        let label = accountLabel
        Task { [runner] in await runner.wipeDevCache(label: label) }
    }

    private func markSuccess(_ kind: PSNBuildStepKind, outcome: PSNBuildStepOutcome,
                             elapsed: Duration, label: String) {
        setStatus(kind, .passed)
        mutate(kind) { row in
            row.outcome = outcome
            row.summary = Self.summary(outcome, elapsed: elapsed)
            row.rejectExcerpt = nil
        }
        PSNBuildStepsGate.setPassed(label: label, kind: kind, true)
    }

    private func markFailure(_ kind: PSNBuildStepKind, error: Error) {
        setStatus(kind, .failed)
        failedStep = kind
        rejectMessage = "VGN stopped and made no further requests."
        setExcerpt(kind, Self.redactedExcerpt(error))
    }

    // MARK: - Row helpers

    private func mutate(_ kind: PSNBuildStepKind, _ transform: (inout StepRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.kind == kind }) else { return }
        transform(&rows[index])
    }
    private func setStatus(_ kind: PSNBuildStepKind, _ status: Status) {
        mutate(kind) { $0.status = status }
    }
    private func setExcerpt(_ kind: PSNBuildStepKind, _ excerpt: String?) {
        mutate(kind) { $0.rejectExcerpt = excerpt }
    }
    func row(_ kind: PSNBuildStepKind) -> StepRow? { rows.first { $0.kind == kind } }

    // MARK: - Text (redacted only)

    /// "requests this session: k / 40".
    var requestsText: String { "requests this session: \(requestsUsed) / \(budgetLimit)" }

    static func summary(_ outcome: PSNBuildStepOutcome, elapsed: Duration) -> String {
        var bits: [String] = []
        if let status = outcome.httpStatus { bits.append("HTTP \(status)") }
        let items = outcome.totalItemCount.map { "\(outcome.itemCount)/\($0) items" }
            ?? "\(outcome.itemCount) item\(outcome.itemCount == 1 ? "" : "s")"
        bits.append(items)
        bits.append(outcome.fromCache ? "from cache" : "from network")
        bits.append(byteString(outcome.bytes))
        bits.append(elapsedString(elapsed))
        return bits.joined(separator: " · ")
    }

    static func byteString(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
        return "\(bytes) B"
    }

    static func elapsedString(_ d: Duration) -> String {
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }

    /// A redacted stop excerpt for a thrown error. Built only from typed, already-redacted
    /// fields — never `localizedDescription`, so no token/NPSSO/account id can leak.
    static func redactedExcerpt(_ error: Error) -> String {
        switch error {
        case ImportError.rejected(let reject):
            let head = reject.reason.message
            return reject.redactedExcerpt.isEmpty ? head : "\(head)\n\(reject.redactedExcerpt)"
        case ImportError.budgetExceeded(let limit):
            return "Request budget of \(limit) reached — the sync ended."
        case ImportError.notAuthenticated:
            return "Not signed in, or the session expired. Sign in again."
        case ImportError.disallowedURL:
            return "A request outside the allow-list was blocked (a bug)."
        case PSNClient.ClientError.probeRequired(let marker):
            return "A full fetch was attempted before its probe (\(marker))."
        default:
            return "The step stopped with an unexpected error."
        }
    }

    /// A redacted plain-text report of every row for the pasteboard (PLAN §13.5). Built ONLY
    /// from redacted fields (status/counts/cache/bytes/path/summary/excerpt + the label and
    /// the request total) — no token, NPSSO or account id can appear.
    func reportText() -> String {
        var lines: [String] = []
        lines.append("PSN build steps — account: \(accountLabel) · \(requestsText)")
        if let rejectMessage { lines.append("STOPPED: \(rejectMessage)") }
        for row in rows {
            let word: String
            switch row.status {
            case .idle: word = "—"
            case .running: word = "running"
            case .passed: word = "ok"
            case .failed: word = "FAILED"
            }
            var line = "\(row.kind.title): \(word)"
            if let summary = row.summary { line += " — \(summary)" }
            if let path = row.outcome?.devCachePath { line += " · \(path)" }
            if let excerpt = row.rejectExcerpt {
                line += " · reject: \(excerpt.replacingOccurrences(of: "\n", with: " "))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Confirmation copy

    var confirmTitle: String {
        switch pendingConfirm {
        case .fullFetch(let k), .realFullFetch(let k):
            return "Fetch “\(k.title)”?"
        case .retry(let k): return "Try “\(k.title)” again?"
        case .wipe: return "Wipe the dev cache for ‘\(accountLabel)’?"
        case .none: return ""
        }
    }
    var confirmMessage: String {
        switch pendingConfirm {
        case .fullFetch(let k):
            return "This makes up to \(k.estimatedRequests) request\(k.estimatedRequests == 1 ? "" : "s") to PlayStation."
        case .realFullFetch(let k):
            return "REAL ACCOUNT. Confirm again: up to \(k.estimatedRequests) request\(k.estimatedRequests == 1 ? "" : "s") to PlayStation, on your real account."
        case .retry:
            return "This is one new request. It ran once and stopped; run it again only if you understand why."
        case .wipe:
            return "Deletes this account's recorded bodies from the on-disk dev cache. It holds no tokens. Re-running a step will fetch again."
        case .none:
            return ""
        }
    }
    var confirmButtonTitle: String {
        switch pendingConfirm {
        case .wipe: return "Wipe"
        default: return "Continue"
        }
    }
}
#endif
