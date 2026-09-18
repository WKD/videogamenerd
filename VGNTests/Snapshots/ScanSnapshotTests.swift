#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Photo scan (PLAN §6.2): the input screen, the per-tile progress rows, and the
/// review sheet with all three confidence buckets + greyed duplicates.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ScanSnapshotTests {
    private let group = "06 Photo Scan"

    @Test func progress() async {
        let model = PhotoScanPreview.runningModel()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "scan-progress", size: SnapSize(width: 720, height: 560)) {
            PhotoScanView(model: model)
        }
    }

    @Test func input() async {
        let model = PhotoScanPreview.environment().makeModel()
        await SnapshotHarness.settle(rounds: 3)
        await SnapshotHarness.capture(group: group, "scan-input", size: SnapSize(width: 720, height: 560)) {
            PhotoScanView(model: model)
        }
    }

    @Test func reviewWide() async {
        let model = PhotoScanPreview.reviewModel()
        await SnapshotHarness.settle(rounds: 5)
        await SnapshotHarness.capture(group: group, "scan-review", size: SnapSize(width: 1000, height: 680)) {
            PhotoScanReviewView(model: model)
        }
    }

    @Test func reviewCompact() async {
        let model = PhotoScanPreview.reviewModel()
        await SnapshotHarness.settle(rounds: 5)
        await SnapshotHarness.capture(group: group, "scan-review-compact", size: SnapSize(width: 820, height: 600)) {
            PhotoScanReviewView(model: model)
        }
    }
}
#endif
