#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// The inspector (PLAN §8): single game with copies / playtime / score line,
/// multi-select, and the empty state.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct InspectorSnapshotTests {
    private let group = "02 Inspector"
    private let size = SnapSize(width: 320, height: 700)

    @Test func single() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1])
        await SnapshotHarness.capture(group: group, "inspector-single", size: size) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }

    @Test func multi() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1, 2, 3])
        await SnapshotHarness.capture(group: group, "inspector-multi", size: size) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }

    @Test func empty() async {
        let vm = await SnapSupport.libraryVM(.sampled)
        await SnapshotHarness.capture(group: group, "inspector-empty", size: size) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }
}
#endif
