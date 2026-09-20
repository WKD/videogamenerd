import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Every Settings pane sizes itself to its content — no pane needs scrolling, and the
/// window follows the selected tab (owner request 2026-09-19).
@MainActor
@Suite(.serialized)
struct SettingsPaneSizingTests {
    private func fittingHeight<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.settingsPane().frame(width: SettingsView.paneWidth))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test(.timeLimit(.minutes(2)))
    func everyPaneHasAFiniteContentHeightThatFitsAScreen() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let signedIn = GOGAccountModel(
            backend: FakeImportBackend(dataSets: [], staging: ImportStagingStore(db), session: true, username: "gog_gamer"),
            login: nil)
        await signedIn.refresh()
        let signedOut = GOGAccountModel(
            backend: FakeImportBackend(dataSets: [], staging: ImportStagingStore(db), session: false, username: nil),
            login: nil)
        await signedOut.refresh()

        let psnDataSets = [
            ImportDataSet(id: PSNEndpoint.profile, title: "Profile", estimatedRequests: 1),
            ImportDataSet(id: PSNEndpoint.trophyTitles, title: "Trophy titles", estimatedRequests: 4),
            ImportDataSet(id: PSNEndpoint.gameList, title: "Game list", estimatedRequests: 3),
            ImportDataSet(id: PSNEndpoint.purchases, title: "Purchases", estimatedRequests: 4),
        ]
        // The latch is read at init, so arm it before building the "on" models and clear it
        // before the latch-off one (the build-steps panel is behind a button, so it never
        // affects the pane's own height).
        AppPreferences.defaults.set(true, forKey: PSNImportBuilder.liveEnabledKey)
        let psnSignedIn = PSNAccountModel(
            backend: FakeImportBackend(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                       dataSets: psnDataSets, staging: ImportStagingStore(db),
                                       session: true, username: "nerd_ps"),
            login: nil)
        await psnSignedIn.refresh()
        // Tallest PSN signed-in layout: the PS Plus deadline section expanded with the past-date
        // hint (PLAN §16). The menu-style pickers lay out fine off-screen (never clicked).
        psnSignedIn.planningToLeavePSPlus = true
        psnSignedIn.deadlineYear = 2020
        psnSignedIn.deadlineMonth = 1
        #if DEBUG
        psnSignedIn.buildSteps = PSNBuildStepsModel(
            runner: ScriptedPSNBuildRunner(session: true), accountLabel: "test")
        #endif
        let psnSignedOut = PSNAccountModel(
            backend: FakeImportBackend(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                       dataSets: [], staging: ImportStagingStore(db), session: false),
            login: nil)
        psnSignedOut.pasteExpanded = true   // tallest signed-out layout
        await psnSignedOut.refresh()
        AppPreferences.defaults.removeObject(forKey: PSNImportBuilder.liveEnabledKey)
        let psnLatchOff = PSNAccountModel(
            backend: FakeImportBackend(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                       dataSets: [], staging: ImportStagingStore(db), session: false),
            login: nil)
        await psnLatchOff.refresh()

        // Batocera pane (PLAN §15): the tallest state has the status block, the skip list and
        // the threshold row.
        BatoceraPreferences.shareFolderPath = nil
        let batoceraNoFolder = BatoceraSettingsModel(backend: InertBatoceraBackend())
        BatoceraPreferences.shareFolderPath = "/Volumes/share"
        let batoceraConfigured = BatoceraSettingsModel(
            backend: FakeBatoceraBackend(isLive: false,
                                         status: BatoceraCatalogStatus(totalEntries: 11_300, systemsCount: 40,
                                                                       candidatesWaiting: 290)))
        BatoceraPreferences.shareFolderPath = nil

        let heights: [(String, CGFloat)] = [
            ("General", fittingHeight(GeneralTab())),
            ("Batocera no folder", fittingHeight(BatoceraSettingsTab(model: batoceraNoFolder))),
            ("Batocera configured", fittingHeight(BatoceraSettingsTab(model: batoceraConfigured))),
            ("IGDB", fittingHeight(IGDBAccountTab(model: SettingsModel(secretStore: InMemorySecretStore())))),
            ("GOG signed in", fittingHeight(GOGAccountTab(model: signedIn))),
            ("GOG signed out", fittingHeight(GOGAccountTab(model: signedOut))),
            ("PSN signed in", fittingHeight(PSNAccountTab(model: psnSignedIn))),
            ("PSN signed out", fittingHeight(PSNAccountTab(model: psnSignedOut))),
            ("PSN latch off", fittingHeight(PSNAccountTab(model: psnLatchOff))),
            ("Photo Scan", fittingHeight(PhotoScanSettingsTab())),
        ]
        print("SETTINGS pane heights:", heights.map { "\($0.0)=\(Int($0.1))" })
        for (name, height) in heights {
            #expect(height > 80, "\(name) collapsed (\(height)) — the Form must report its content height")
            #expect(height < 760, "\(name) is \(height) pt tall — it would not fit a 13-inch screen without scrolling")
        }
    }
}
