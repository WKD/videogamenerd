import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The grid tile's format-badge row (PLAN §8 / wave 19, D5) never draws wider than the tile.
/// With PS Plus moved to the top-left corner the bottom row is at most four badges (physical +
/// digital + ROM + played), which share one line even at the narrowest tile. Hosts the real
/// ``RankingFlowLayout`` with the shared ``FormatBadgeLayout`` sizes and measures it, and also
/// checks the top-left corner (tier chip + PS Plus) plus the top-right compilation marker fit
/// the top row at the minimum tile width. `@MainActor` hosting ⇒ `.serialized`.
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

    @Test func fourBadgesFitOnOneLineWithinTheMinimumTile() {
        let cw = FormatBadgeLayout.minTile
        let d = FormatBadgeLayout.diameter(cellWidth: cw)
        let avail = FormatBadgeLayout.availableWidth(cellWidth: cw)
        let size = rowFittingSize(count: 4, cellWidth: cw)
        #expect(size.width <= avail + 0.5, "badge row \(size.width) exceeds tile allotment \(avail)")
        #expect(size.height <= d + 2, "four badges should share one line at the min tile (h=\(size.height), d=\(d))")
    }

    @Test func fourBadgesStayOnOneLineAtTheDefaultTile() {
        let d = FormatBadgeLayout.diameter(cellWidth: 150)
        let size = rowFittingSize(count: 4, cellWidth: 150)
        #expect(size.height <= d + 2, "four badges should fit one line at the default tile (h=\(size.height), d=\(d))")
    }

    /// The top row — tier chip (22 pt) + PS Plus corner badge on the left, the compilation
    /// marker on the right — fits within the cover width at the smallest tile, so nothing
    /// clips or pushes the marker off the cover.
    @Test func tierChipPlusPSPlusAndCompilationMarkerFitTheTopRowAtMinTile() {
        let cw = FormatBadgeLayout.minTile
        let d = FormatBadgeLayout.diameter(cellWidth: cw)
        let s = FormatBadgeLayout.spacing(cellWidth: cw)
        // Cover area width ≈ tile width minus the cell padding (2×6); the badge overlay adds
        // its own 6 pt inset each side.
        let coverWidth = cw - 12
        let overlayAvail = coverWidth - 12
        // Left corner: 22 pt tier chip + spacing + PS Plus badge. Right corner: the compilation
        // marker (an SF Symbol at .caption with 4 pt padding ≈ ~22 pt). They must not overlap.
        let leftCorner = 22 + s + d
        let rightMarker: CGFloat = 22
        #expect(leftCorner + rightMarker <= overlayAvail + 0.5,
                "top row \(leftCorner + rightMarker) exceeds cover \(overlayAvail) at the min tile")

        // And it actually renders without exploding the host.
        let row = HStack(alignment: .top) {
            HStack(spacing: s) {
                Circle().frame(width: 22, height: 22)
                Circle().frame(width: d, height: d)
            }
            Spacer(minLength: 0)
            Circle().frame(width: 22, height: 22)
        }
        .frame(width: overlayAvail, alignment: .top)
        let host = NSHostingView(rootView: row)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= overlayAvail + 0.5)
    }
}
