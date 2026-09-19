#if DEBUG
import Foundation
import Testing
@testable import VGN

/// The DEBUG-only PSN safety latch, the build-steps model (enable/disable matrix, one-at-a-
/// time, reject lock + acknowledge + retry, account-label switch, redacted report, wipe) and
/// the normal-Sync DEBUG gate (PLAN §13.5). All over a ``ScriptedPSNBuildRunner`` — no
/// network, no Keychain. `AppPreferences.defaults` is a throw-away suite under the test host,
/// but shared across the process, so every test clears the keys it touches.
@MainActor
@Suite(.serialized)
struct PSNBuildStepsTests {

    private func clearPrefs() {
        for label in ["test", "real"] {
            for kind in PSNBuildStepKind.allCases {
                AppPreferences.defaults.removeObject(forKey: PSNBuildStepsGate.key(label: label, kind: kind))
            }
        }
        AppPreferences.defaults.removeObject(forKey: PSNAccountModel.accountLabelKey)
        AppPreferences.defaults.removeObject(forKey: PSNImportBuilder.liveEnabledKey)
    }

    private func makeAccount(session: Bool = false) throws -> (PSNAccountModel, FakeImportBackend) {
        let db = try AppDatabase.inMemory()
        let backend = FakeImportBackend(
            source: ImportSourceID.psn, sourceLabel: "PlayStation",
            dataSets: [], staging: ImportStagingStore(db), session: session)
        return (PSNAccountModel(backend: backend, login: nil), backend)
    }

    // MARK: - Deliverable 1: the safety latch as a visible switch

    @Test(.timeLimit(.minutes(1)))
    func latchEnableWritesPreferenceAndFlagsRelaunch() throws {
        clearPrefs(); defer { clearPrefs() }
        let (model, _) = try makeAccount()
        #expect(model.liveEnabled == false)

        model.requestEnableLive()
        #expect(model.enableConfirming)
        model.confirmEnableLive()
        #expect(model.liveEnabled)
        #expect(model.latchChanged)
        #expect(AppPreferences.defaults.bool(forKey: PSNImportBuilder.liveEnabledKey))
    }

    @Test(.timeLimit(.minutes(1)))
    func latchDisableClearsPreference() throws {
        clearPrefs(); defer { clearPrefs() }
        AppPreferences.defaults.set(true, forKey: PSNImportBuilder.liveEnabledKey)
        let (model, _) = try makeAccount()
        #expect(model.liveEnabled)
        model.requestDisableLive()
        #expect(model.disableConfirming)
        model.confirmDisableLive()
        #expect(!model.liveEnabled)
        #expect(!AppPreferences.defaults.bool(forKey: PSNImportBuilder.liveEnabledKey))
    }

    // MARK: - Deliverable 2: enable/disable matrix (table test)

    private func makeModel(session: Bool = true, label: String = "test") async -> (PSNBuildStepsModel, ScriptedPSNBuildRunner) {
        let runner = ScriptedPSNBuildRunner(session: session, onlineID: "test_nerd")
        let model = PSNBuildStepsModel(runner: runner, accountLabel: label)
        await model.refresh()
        return (model, runner)
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingIsEnabledBeforeSignIn() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, _) = await makeModel(session: false)
        for kind in PSNBuildStepKind.allCases {
            #expect(model.isEnabled(kind) == false, "\(kind) must be disabled when signed out")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func enableMatrixFollowsPrerequisites() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, _) = await makeModel()

        // Signed in, no probe recorded: only the profile probe is enabled.
        #expect(model.isEnabled(.probeProfile))
        for kind in [PSNBuildStepKind.probeTrophyTitles, .probeGameList, .probePurchases,
                     .fetchTrophyTitles, .fetchGameList, .fetchPurchases] {
            #expect(model.isEnabled(kind) == false, "\(kind) needs its prerequisites")
        }

        // Profile probe passed → the three data-set probes unlock; full fetches stay locked.
        PSNBuildStepsGate.setPassed(label: "test", kind: .probeProfile, true)
        for kind in [PSNBuildStepKind.probeTrophyTitles, .probeGameList, .probePurchases] {
            #expect(model.isEnabled(kind), "\(kind) unlocks after S2")
        }
        for kind in [PSNBuildStepKind.fetchTrophyTitles, .fetchGameList, .fetchPurchases] {
            #expect(model.isEnabled(kind) == false, "\(kind) needs its own probe")
        }

        // Each full fetch needs ITS probe (trophy titles is one list now).
        PSNBuildStepsGate.setPassed(label: "test", kind: .probeTrophyTitles, true)
        #expect(model.isEnabled(.fetchTrophyTitles))

        PSNBuildStepsGate.setPassed(label: "test", kind: .probeGameList, true)
        #expect(model.isEnabled(.fetchGameList))
        PSNBuildStepsGate.setPassed(label: "test", kind: .probePurchases, true)
        #expect(model.isEnabled(.fetchPurchases))
    }

    // MARK: - Deliverable 2: run a step, record success, persist per label

    @Test(.timeLimit(.minutes(1)))
    func probeRunsRecordsAndPersistsForTheLabel() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel()
        model.activate(.probeProfile)
        await poll(until: { !model.isRunning && model.row(.probeProfile)?.status == .passed })
        #expect(runner.calls == [.probeProfile])
        #expect(PSNBuildStepsGate.hasPassed(label: "test", kind: .probeProfile))
        #expect(model.row(.probeProfile)?.summary?.contains("from network") == true)
        #expect(model.requestsUsed >= 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func fullFetchAsksForConfirmationFirst() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel()
        for kind in [PSNBuildStepKind.probeProfile, .probeTrophyTitles] {
            PSNBuildStepsGate.setPassed(label: "test", kind: kind, true)
        }
        model.activate(.fetchTrophyTitles)
        #expect(model.pendingConfirm == .fullFetch(.fetchTrophyTitles))
        #expect(runner.calls.isEmpty, "a full fetch must not run before the confirmation")
        model.confirmPending()
        await poll(until: { !model.isRunning && model.row(.fetchTrophyTitles)?.status == .passed })
        #expect(runner.calls == [.fetchTrophyTitles])
    }

    /// The 2026-09-20 bug: on the real account a full fetch used to want a SECOND confirmation,
    /// requested while the first dialog was dismissing — which macOS silently dropped, so the
    /// fetch never ran. There is now exactly ONE confirmation per full fetch, on every label.
    @Test(.timeLimit(.minutes(1)))
    func oneConfirmRunsEachFullFetch() async {
        for label in ["test", "real"] {
            for full in [PSNBuildStepKind.fetchTrophyTitles, .fetchGameList, .fetchPurchases] {
                clearPrefs()
                let (model, runner) = await makeModel(label: label)
                for prereq in [PSNBuildStepKind.probeProfile] + full.prerequisites {
                    PSNBuildStepsGate.setPassed(label: label, kind: prereq, true)
                }
                model.activate(full)
                #expect(model.pendingConfirm == .fullFetch(full), "\(label)/\(full): one confirm expected")
                #expect(model.isConfirming(full))
                #expect(runner.calls.isEmpty, "\(label)/\(full): must not run before the single confirm")
                model.confirmPending()   // ONE confirm → runs
                #expect(model.pendingConfirm == nil, "\(label)/\(full): no chained second dialog")
                await poll(until: { !model.isRunning && model.row(full)?.status == .passed })
                #expect(runner.calls == [full], "\(label)/\(full): exactly one runner call after one confirm")
                clearPrefs()
            }
        }
    }

    /// The real account gets a single, STRONGER confirm (title + wording), not a chained one.
    @Test(.timeLimit(.minutes(1)))
    func realAccountConfirmIsStrongerButStillSingle() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel(label: "real")
        for kind in [PSNBuildStepKind.probeProfile, .probeGameList] {
            PSNBuildStepsGate.setPassed(label: "real", kind: kind, true)
        }
        model.activate(.fetchGameList)
        #expect(model.confirmTitle.contains("REAL ACCOUNT"))
        #expect(model.confirmMessage.contains("your real account"))
        #expect(model.confirmMessage.contains("used this session"))
        #expect(model.confirmButtonTitle == "Fetch (2 requests)")
        model.confirmPending()
        await poll(until: { !model.isRunning && model.row(.fetchGameList)?.status == .passed })
        #expect(runner.calls == [.fetchGameList], "one confirm on real → exactly one call")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAConfirmRunsNothing() async {
        clearPrefs(); defer { clearPrefs() }
        for label in ["test", "real"] {
            let (model, runner) = await makeModel(label: label)
            for kind in [PSNBuildStepKind.probeProfile, .probeTrophyTitles] {
                PSNBuildStepsGate.setPassed(label: label, kind: kind, true)
            }
            model.activate(.fetchTrophyTitles)
            #expect(model.isConfirming(.fetchTrophyTitles))
            model.cancelPending()
            #expect(model.pendingConfirm == nil)
            #expect(runner.calls.isEmpty, "\(label): cancel must run nothing")
            #expect(model.isEnabled(.fetchTrophyTitles), "\(label): cancel re-enables the button")
        }
    }

    /// A confirm whose step can no longer start must SAY why in the row, never do nothing.
    @Test(.timeLimit(.minutes(1)))
    func aBlockedConfirmYieldsAVisibleNote() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel()
        for kind in [PSNBuildStepKind.probeProfile, .probeTrophyTitles] {
            PSNBuildStepsGate.setPassed(label: "test", kind: kind, true)
        }
        model.activate(.fetchTrophyTitles)
        #expect(model.isConfirming(.fetchTrophyTitles))
        // The prerequisite is revoked between showing the confirm and pressing Fetch.
        PSNBuildStepsGate.setPassed(label: "test", kind: .probeTrophyTitles, false)
        model.confirmPending()
        #expect(runner.calls.isEmpty, "a blocked confirm must not run")
        #expect(model.row(.fetchTrophyTitles)?.status != .running)
        let note = model.actionNote(for: .fetchTrophyTitles)
        #expect(note != nil, "a blocked start must leave a visible note")
        #expect(note?.contains("first") == true)
    }

    /// Clicking a disabled/blocked run (via the model's guarded entry) leaves a note too.
    @Test(.timeLimit(.minutes(1)))
    func activatingABlockedStepLeavesANote() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel()   // signed in, nothing probed
        model.activate(.fetchTrophyTitles)         // prereqs missing
        #expect(model.pendingConfirm == nil)
        #expect(runner.calls.isEmpty)
        #expect(model.actionNote(for: .fetchTrophyTitles)?.contains("first") == true)
    }

    // MARK: - Deliverable 2: reject lock → acknowledge → retry

    struct FakeReject: Error {}

    @Test(.timeLimit(.minutes(1)))
    func aRejectLocksEveryButtonUntilAcknowledged() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel()
        let reject = ImportReject(source: ImportSourceID.psn, endpoint: PSNEndpoint.profile,
                                  status: 403, reason: .authChallenge, redactedExcerpt: "‹redacted›")
        runner.scriptError(ImportError.rejected(reject), for: .probeProfile)

        model.activate(.probeProfile)
        await poll(until: { !model.isRunning && model.rejectMessage != nil })
        #expect(model.rejectMessage == "VGN stopped and made no further requests.")
        #expect(model.failedStep == .probeProfile)
        #expect(model.row(.probeProfile)?.rejectExcerpt?.contains("authentication challenge") == true)
        // Everything disabled while locked.
        for kind in PSNBuildStepKind.allCases { #expect(model.isEnabled(kind) == false) }

        // Acknowledge re-enables only steps whose prerequisites hold (none here, since the
        // profile probe never passed); the failed step needs an explicit retry.
        model.acknowledge()
        #expect(model.rejectMessage == nil)
        #expect(model.isEnabled(.probeProfile) == false)   // it is the failed step
        #expect(model.needsRetry(.probeProfile))
        #expect(model.isEnabled(.probeTrophyTitles) == false)   // prereq (S2) still not passed

        // Retry is one new decision: confirm, then it can succeed.
        runner.scriptOutcome(PSNBuildStepOutcome(itemCount: 1, requestsUsedTotal: 2), for: .probeProfile)
        model.requestRetry(.probeProfile)
        #expect(model.pendingConfirm == .retry(.probeProfile))
        model.confirmPending()
        await poll(until: { !model.isRunning && model.row(.probeProfile)?.status == .passed })
        #expect(model.failedStep == nil)
        #expect(model.isEnabled(.probeTrophyTitles), "S2 passed on retry unlocks the probes")
    }

    // MARK: - Deliverable 2: account label switch resets shown state

    @Test(.timeLimit(.minutes(1)))
    func switchingLabelShowsThatLabelsRecordedState() async {
        clearPrefs(); defer { clearPrefs() }
        PSNBuildStepsGate.setPassed(label: "real", kind: .probeProfile, true)
        let (model, _) = await makeModel(label: "test")
        #expect(model.row(.probeProfile)?.status == .idle)

        model.accountLabel = "real"
        #expect(model.row(.probeProfile)?.status == .passed)
        #expect(AppPreferences.defaults.string(forKey: PSNAccountModel.accountLabelKey) == "real")

        model.accountLabel = "test"
        #expect(model.row(.probeProfile)?.status == .idle)
    }

    // MARK: - Deliverable 2: redacted report + wipe

    @Test(.timeLimit(.minutes(1)))
    func copyReportContainsNoAccountIdentifier() async {
        clearPrefs(); defer { clearPrefs() }
        let runner = ScriptedPSNBuildRunner(session: true, onlineID: "ACCOUNTID_SENTINEL")
        let model = PSNBuildStepsModel(runner: runner, accountLabel: "test")
        await model.refresh()
        model.activate(.probeProfile)
        await poll(until: { !model.isRunning && model.row(.probeProfile)?.status == .passed })

        let report = model.reportText()
        #expect(report.contains("account: test"))
        #expect(report.contains("S2 · Probe profile"))
        // The online id / account identifier must never reach the report.
        #expect(!report.contains("ACCOUNTID_SENTINEL"))
    }

    @Test(.timeLimit(.minutes(1)))
    func wipeConfirmsThenAsksTheRunner() async {
        clearPrefs(); defer { clearPrefs() }
        let (model, runner) = await makeModel()
        model.requestWipe()
        #expect(model.pendingConfirm == .wipe)
        model.confirmPending()
        await poll(until: { runner.wipedLabels == ["test"] })
        #expect(runner.wipedLabels == ["test"])
    }

    // MARK: - Deliverable 4: DEBUG normal-Sync gate

    @Test(.timeLimit(.minutes(1)))
    func debugSyncRefusesUntilBuildStepsPass() async throws {
        clearPrefs(); defer { clearPrefs() }
        let db = try AppDatabase.inMemory()
        let backend = FakeImportBackend(
            source: ImportSourceID.psn, sourceLabel: "PlayStation",
            dataSets: [], staging: ImportStagingStore(db), session: true)
        let account = PSNAccountModel(backend: backend, login: nil)
        await account.refresh()
        let presenter = PSNImportPresenter(backend: backend, liveEnabled: true)
        presenter.account = account

        // No build steps passed → the sync refuses and surfaces the gate message.
        presenter.syncNow()
        await poll(until: { account.pendingError != nil })
        #expect(backend.syncCount == 0)
        #expect(account.pendingError?.title == "Run the PSN build steps first")

        // All steps passed for the current label → the sync proceeds.
        account.pendingError = nil
        for kind in PSNBuildStepKind.allCases {
            PSNBuildStepsGate.setPassed(label: "test", kind: kind, true)
        }
        presenter.syncNow()
        await poll(until: { backend.syncCount == 1 })
        #expect(backend.syncCount == 1)
    }
}
#endif
