import SwiftUI

/// A simple wrapping flow layout (left-to-right, top-to-bottom) for the Tier
/// Board's cover tiles, which wrap to as many lines as needed (PLAN §7). Tiles
/// are fixed-size, so measuring is cheap.
struct RankingFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct RowLine { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [RowLine] {
        var rows: [RowLine] = []
        var current = RowLine()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let addedWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, addedWidth > maxWidth {
                rows.append(current)
                current = RowLine()
                current.items = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(index)
                current.width = addedWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
