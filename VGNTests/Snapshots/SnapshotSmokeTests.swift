#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VGN

/// A tiny first-light suite that proves the harness renders a leaf view, an
/// AppKit-backed control view, and a full `NavigationSplitView` window off-screen.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SnapshotSmokeTests {

    @Test func leafComponentRenders() async {
        await SnapshotHarness.capture(group: "smoke", "smoke-tier-chips", size: SnapSize(width: 300, height: 120)) {
            HStack(spacing: 12) {
                TierChip(letter: "S", colorHex: "#FF3B30")
                TierChip(letter: "A", colorHex: "#FF9500")
                TierChip(letter: "F", colorHex: "#8E8E93")
            }
            .padding()
        }
        try? verifyProduced("smoke-tier-chips")
    }

    @Test func databaseErrorRenders() async {
        await SnapshotHarness.capture(group: "smoke", "smoke-db-error", size: SnapSize(width: 620, height: 460)) {
            DatabaseErrorView(failure: .init(message: "The library file is not a valid SQLite database.",
                                             path: "~/Library/Application Support/VGN/vgn.sqlite"))
        }
        try? verifyProduced("smoke-db-error")
    }

    @Test func gridContentRenders() async {
        let vm = await SnapSupport.libraryVM(.sampled)
        await SnapshotHarness.capture(group: "smoke", "smoke-gridcontent", size: .compact, appearances: [.light]) {
            GridContent(vm: vm)
        }
        try? verifyProduced("smoke-gridcontent", appearances: [.light])
    }

    @Test func realEmptyGridRenders() async {
        let vm = await SnapSupport.libraryVM(.empty)
        await SnapshotHarness.capture(group: "smoke", "smoke-grid-empty", size: .compact, appearances: [.light]) {
            LibraryGridView(vm: vm)
        }
        try? verifyProduced("smoke-grid-empty", appearances: [.light])
    }

    @Test func bigGridContentRenders() async {
        let vm = await SnapSupport.libraryVM(SnapSupport.bigLibrarySource(1000))
        await SnapshotHarness.capture(group: "smoke", "smoke-grid-1000", size: .large, appearances: [.light]) {
            GridContent(vm: vm, limit: 80)
        }
        try? verifyProduced("smoke-grid-1000", appearances: [.light])
    }

    @Test func mainWindowHStackRenders() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1], inspector: true)
        await SnapshotHarness.capture(group: "smoke", "smoke-mainwindow", size: .large, appearances: [.light]) {
            SnapSupport.mainWindow(vm: vm, inspector: true)
        }
        try? verifyProduced("smoke-mainwindow", appearances: [.light])
    }

    /// Assert the PNG landed and is non-trivial (a blank capture is ~a few bytes).
    private func verifyProduced(_ name: String, appearances: [SnapAppearance] = SnapAppearance.allCases) throws {
        for appearance in appearances {
            let url = SnapshotHarness.outputDir.appendingPathComponent("\(name)@\(appearance.rawValue).png")
            let data = try Data(contentsOf: url)
            #expect(data.count > 1000, "\(name)@\(appearance.rawValue) looks empty (\(data.count) bytes)")
        }
    }
}
#endif
