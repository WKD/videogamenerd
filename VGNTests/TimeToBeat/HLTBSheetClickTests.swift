import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse clicks against the HLTB sheets' primary buttons (PLAN §5.3), through the
/// shared ``ClickProbeWindow`` — model-level tests can't see a hit-testing bug.
@MainActor
@Suite(.serialized)
struct HLTBSheetClickTests {

    /// A tiny observable box the SwiftUI callbacks write into.
    @MainActor final class Flag { var count = 0 }

    @Test(.timeLimit(.minutes(5)))
    func pickerUseButtonReceivesClicks() async throws {
        let flag = Flag()
        let candidates = [
            HLTBCandidate(id: 2600, name: "Bloodborne", releaseYear: 2015,
                          mainSeconds: 115200, mainExtraSeconds: 154800, completionistSeconds: 259200),
        ]
        // Pin the sheet content to the top so its buttons sit in the band the sweep
        // covers (a horizontal scroll view would swallow clicks — this uses none).
        let view = VStack(spacing: 0) {
            HLTBPickerSheet(title: "Bloodborne", year: 2015, candidates: candidates,
                            onPick: { _ in flag.count += 1 }, onCancel: {})
            Color.clear
        }
        .frame(minWidth: 900, minHeight: 600)

        let window = ClickProbeWindow(view)
        defer { window.close() }
        try await window.settle()
        let clicks = try await window.sweep(band: 260, stepX: 12, stepY: 8,
                                            observe: { flag.count }, until: { flag.count > 0 })
        #expect(clicks >= 1, "no click reached the picker's Use button")
        #expect(flag.count > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func bulkDoneButtonReceivesClicks() async throws {
        let flag = Flag()
        let db = try AppDatabase.inMemory()
        let model = HLTBBulkFetchModel(store: LibraryStore(db), makeSearch: { HLTBInertSearch() })
        model.start(gameIDs: [])   // empty scope → finished immediately → summary + Done
        let presenter = HLTBFetchPresenter(store: LibraryStore(db), makeSearch: { HLTBInertSearch() })

        let view = VStack(spacing: 0) {
            HLTBBulkSheet(model: model, presenter: presenter, onClose: { flag.count += 1 })
            Color.clear
        }
        .frame(minWidth: 900, minHeight: 600)

        let window = ClickProbeWindow(view)
        defer { window.close() }
        try await window.settle()
        let clicks = try await window.sweep(band: 220, stepX: 12, stepY: 8,
                                            observe: { flag.count }, until: { flag.count > 0 })
        #expect(clicks >= 1, "no click reached the bulk sheet's Done button")
    }
}
