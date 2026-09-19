import AppKit
import Testing
@testable import VGN

/// ⌘-click toggles, ⇧-click extends, a plain click selects (owner bug report
/// 2026-09-19: every click replaced the selection).
struct GameCellClickTests {
    @Test func plainClickSelects() {
        #expect(GameCell.clickKind(for: []) == .select)
        #expect(GameCell.clickKind(for: [.capsLock]) == .select)
        #expect(GameCell.clickKind(for: [.option, .control, .function]) == .select)
    }

    @Test func commandClickToggles() {
        #expect(GameCell.clickKind(for: [.command]) == .toggle)
        #expect(GameCell.clickKind(for: [.command, .capsLock]) == .toggle)
    }

    @Test func shiftClickExtends() {
        #expect(GameCell.clickKind(for: [.shift]) == .extend)
    }

    @Test func commandWinsOverShift() {
        #expect(GameCell.clickKind(for: [.command, .shift]) == .toggle)
    }
}
