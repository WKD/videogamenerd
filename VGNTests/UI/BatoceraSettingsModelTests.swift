import Foundation
import Testing
@testable import VGN

/// Settings ▸ Batocera model (PLAN §15): folder choice, the auto-sync flag, editable skip
/// list, and a "Sync Now" run through the fake backend that surfaces the review banner.
@MainActor
@Suite(.serialized)
struct BatoceraSettingsModelTests {

    private func freshModel(isLive: Bool = true,
                            summary: BatoceraSyncSummary = BatoceraSyncSummary()) -> (BatoceraSettingsModel, FakeBatoceraBackend) {
        // Clean the isolated (per-test-run) preferences so each test starts fresh.
        BatoceraPreferences.shareFolderPath = nil
        BatoceraPreferences.skipListOverride = nil
        AppPreferences.defaults.removeObject(forKey: BatoceraPreferences.autoSyncKey)
        let backend = FakeBatoceraBackend(isLive: isLive, summary: summary)
        return (BatoceraSettingsModel(backend: backend), backend)
    }

    @Test func defaultsAndSkipListEdits() {
        let (model, _) = freshModel()
        #expect(model.shareFolderPath == nil)
        #expect(model.isConfigured == false)
        #expect(model.autoSyncEnabled == true)                 // default ON
        #expect(model.skipList == BatoceraSystems.defaultSkipList)

        model.newSkipEntry = "myarcade"
        model.addSkip()
        #expect(model.skipList.contains("myarcade"))
        #expect(BatoceraPreferences.skipListOverride?.contains("myarcade") == true)

        model.removeSkip("steam")
        #expect(!model.skipList.contains("steam"))

        model.resetSkip()
        #expect(model.skipList == BatoceraSystems.defaultSkipList)
        #expect(BatoceraPreferences.skipListOverride == nil)
    }

    @Test func autoSyncFlagPersists() {
        let (model, _) = freshModel()
        model.setAutoSync(false)
        #expect(model.autoSyncEnabled == false)
        #expect(BatoceraPreferences.autoSyncAtLaunch == false)
    }

    @Test func chooseFolderStoresThePath() {
        let (model, _) = freshModel()
        model.chooseFolder = { URL(fileURLWithPath: "/tmp/vgn-fake-share") }
        model.pickShareFolder()
        #expect(model.shareFolderPath == "/tmp/vgn-fake-share")
        #expect(model.isConfigured)
        #expect(BatoceraPreferences.shareFolderPath == "/tmp/vgn-fake-share")
    }

    @Test(.timeLimit(.minutes(1)))
    func syncNowRunsAndReportsCandidatesThroughTheBannerCallback() async throws {
        var summary = BatoceraSyncSummary()
        summary.systemsRead = 3
        summary.entriesAdded = 42
        summary.candidateCount = 7
        let (model, backend) = freshModel(summary: summary)
        model.chooseFolder = { URL(fileURLWithPath: "/tmp/vgn-fake-share") }
        model.pickShareFolder()

        var bannerSummary: BatoceraSyncSummary?
        model.onSyncFinished = { bannerSummary = $0 }
        model.newSkipEntry = "extra"; model.addSkip()

        model.syncNow()
        // Wait on every post-condition asserted below (the banner callback and the
        // timestamp land just after `lastSummary`; asserting early raced under load).
        await waitUntil { !model.isSyncing && model.lastSummary != nil && bannerSummary != nil && model.lastSyncAt != nil }

        #expect(backend.calls.count == 1)
        #expect(backend.calls.first?.skip.contains("extra") == true)   // the edited skip list is passed
        #expect(model.lastSummary?.candidateCount == 7)
        #expect(model.lastSyncAt != nil)
        #expect(bannerSummary?.candidateCount == 7)
    }

    @Test(.timeLimit(.minutes(1)))
    func unavailableShareSetsAQuietError() async throws {
        var summary = BatoceraSyncSummary()
        summary.shareUnavailable = true
        let (model, _) = freshModel(summary: summary)
        model.chooseFolder = { URL(fileURLWithPath: "/tmp/vgn-fake-share") }
        model.pickShareFolder()
        model.syncNow()
        await waitUntil { !model.isSyncing && model.lastSummary != nil }
        #expect(model.pendingError == "Batocera share not mounted.")
        #expect(model.lastSyncAt == nil)
    }

    @Test func inertBackendNeverReportsMountedOrTouchesVolumes() async {
        let (model, _) = freshModel(isLive: false)
        model.chooseFolder = { URL(fileURLWithPath: "/tmp/vgn-fake-share") }
        model.pickShareFolder()
        await model.refresh()
        #expect(model.shareMounted == false)   // inert backend is never "live", so no stat of /Volumes
    }
}
