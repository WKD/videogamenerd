import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The grid tile's format-badge row (PLAN §8 / wave 19, D4) never draws wider than the tile:
/// with the worst case (5 badges) at the minimum tile width it **wraps to a second line**
/// rather than overflow, while at the default tile the five sit on one line. Hosts the real
/// ``RankingFlowLayout`` with the shared ``FormatBadgeLayout`` sizes and measures it. `@MainActor`
/// hosting ⇒ `.serialized`.
@MainActor
@Suite(.serialized)
struct GridBadgeRowLayoutTests {

    /// The fitting size of a `count`-badge row laid out with the tile's diameter/spacing, given
    /// the width the tile actually allots the badge row.
    private func rowFittingSize(count: Int, cellWidth: CGFloat) -> CGSize {
        let d = FormatBadgeLayout.diameter(cellWidth: cellWidth)
        let s = FormatBadgeLayout.spacing(cellWidth: cellWidth)
        let avail = FormatBadgeLayout.availableWidth(cellWidth: cellWidth)
        let row = RankingFlowLayout(spacing: s) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().frame(width: d, height: d)
            }
        }
        .frame(width: avail, alignment: .leading)
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func fiveBadgesWrapWithinTheMinimumTile() {
        let cw = FormatBadgeLayout.minTile
        let d = FormatBadgeLayout.diameter(cellWidth: cw)
        let s = FormatBadgeLayout.spacing(cellWidth: cw)
        let avail = FormatBadgeLayout.availableWidth(cellWidth: cw)
        // A single line of five would genuinely overflow, so wrapping is doing real work.
        let oneLine = CGFloat(5) * d + CGFloat(4) * s
        #expect(oneLine > avail, "expected five badges to overflow one line at the min tile")

        let size = rowFittingSize(count: 5, cellWidth: cw)
        // Never wider than the tile's allotment, and wrapped to a second line.
        #expect(size.width <= avail + 0.5, "badge row \(size.width) exceeds tile allotment \(avail)")
        #expect(size.height > d + 1, "five badges should wrap at the min tile (h=\(size.height), d=\(d))")
    }

    @Test func fiveBadgesStayOnOneLineAtTheDefaultTile() {
        let d = FormatBadgeLayout.diameter(cellWidth: 150)
        let size = rowFittingSize(count: 5, cellWidth: 150)
        #expect(size.height <= d + 2, "five badges should fit one line at the default tile (h=\(size.height), d=\(d))")
    }
}
