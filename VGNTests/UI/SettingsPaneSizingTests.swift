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

        let heights: [(String, CGFloat)] = [
            ("General", fittingHeight(GeneralTab())),
            ("IGDB", fittingHeight(IGDBAccountTab(model: SettingsModel(secretStore: InMemorySecretStore())))),
            ("GOG signed in", fittingHeight(GOGAccountTab(model: signedIn))),
            ("GOG signed out", fittingHeight(GOGAccountTab(model: signedOut))),
            ("Photo Scan", fittingHeight(PhotoScanSettingsTab())),
        ]
        print("SETTINGS pane heights:", heights.map { "\($0.0)=\(Int($0.1))" })
        for (name, height) in heights {
            #expect(height > 80, "\(name) collapsed (\(height)) — the Form must report its content height")
            #expect(height < 760, "\(name) is \(height) pt tall — it would not fit a 13-inch screen without scrolling")
        }
    }
}
