import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The inspector layout survives a narrow column (owner 2026-09-20): the header action
/// buttons stack one-per-line instead of squeezing each label letter-by-letter, and the
/// Playtime table / me-vs-average summary never wrap mid-value. Model tests can't see this —
/// these host the real views and measure their fitting size.
@MainActor
@Suite(.serialized)
struct InspectorLayoutTests {

    /// Inner content width at a given inspector column width (the section has 16 pt padding
    /// on each side). Min column is 300 (`RootView`), max 480.
    private static func inner(_ column: CGFloat) -> CGFloat { column - 32 }

    private func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - Header action buttons

    private func action(_ title: String) -> InspectorAction {
        InspectorAction(title: title, systemImage: "link", help: title, action: {})
    }

    /// The full action set (long labels) is one line per button at the minimum width — no
    /// letter-by-letter wrapping.
    @Test func headerActionsAreOneLinePerButtonAtMinimumWidth() {
        let full = [
            action("Change IGDB Match…"), action("Refresh metadata"), action("Choose Cover…"),
            action("Remove custom cover"), action("Expand Bundle into Games…"),
        ]
        let width = Self.inner(300)
        let perLine = fittingHeight(InspectorActionsView(actions: [action("X")]), width: width)
        let expected = perLine * CGFloat(full.count) + 8 * CGFloat(full.count - 1)   // vertical spacing 8
        let actual = fittingHeight(InspectorActionsView(actions: full), width: width)
        // If any label wrapped to a second line, `actual` would exceed `expected`.
        #expect(abs(actual - expected) <= 6, "expected \(expected), got \(actual)")
    }

    /// When they fit, the actions lay out as a single horizontal row (ViewThatFits uses the
    /// row before the stack).
    @Test func headerActionsUseARowWhenTheyFit() {
        let few = [action("Link"), action("Refresh")]
        let width = Self.inner(480)
        let perLine = fittingHeight(InspectorActionsView(actions: [action("Link")]), width: width)
        let row = fittingHeight(InspectorActionsView(actions: few), width: width)
        #expect(abs(row - perLine) <= 4, "two short actions should share one row (\(row) vs \(perLine))")
    }

    // MARK: - Playtime table

    /// Long estimate values do not wrap between the minimum (300) and a wide (440) column.
    @Test func playtimeEstimatesDoNotWrap() {
        let table = PlaytimeEstimatesTable(
            psnSeconds: 2310 * 3600 + 5 * 60, manualWins: true,
            mainS: 620 * 3600, completionistS: 1240 * 3600, rushedS: 410 * 3600,
            sourceLabel: "HowLongToBeat", showEstimates: true)
        let narrow = fittingHeight(table, width: Self.inner(300))
        let wide = fittingHeight(table, width: Self.inner(440))
        #expect(narrow == wide, "table wrapped: \(narrow) vs \(wide)")
    }

    /// The suspicious-estimate warning (PLAN §5.3, D3) survives the 300 pt minimum column:
    /// its ⚠︎ + two action labels stack rather than squeezing letter-by-letter, so the row
    /// lays out with a finite, bounded height in both the flagged and dismissed states.
    @Test func estimateWarningSurvivesMinimumWidth() {
        let width = Self.inner(300)
        let flagged = PlaytimeEstimateWarning(
            reason: "Completionist (1000 h) is more than 4× the main story (54 h).",
            dismissed: false, isRefreshing: false, onRefresh: {}, onDismissToggle: { _ in })
        let dismissed = PlaytimeEstimateWarning(
            reason: "Completionist (1000 h) is more than 4× the main story (54 h).",
            dismissed: true, isRefreshing: false, onRefresh: {}, onDismissToggle: { _ in })
        let hFlagged = fittingHeight(flagged, width: width)
        let hDismissed = fittingHeight(dismissed, width: width)
        #expect(hFlagged > 0 && hFlagged.isFinite)
        #expect(hDismissed > 0 && hDismissed.isFinite)
        // Three stacked caption rows are the worst case — well under this bound; a
        // letter-by-letter squeeze of the long "Refresh from HowLongToBeat" label would
        // blow far past it.
        #expect(hFlagged < 160, "warning too tall at 300 pt: \(hFlagged)")
    }

    /// The compilation "N h on the whole collection (PSN)" caption stays one line at the 300 pt
    /// minimum — a long value scales down (minimumScaleFactor) instead of wrapping (PLAN §13.3/D2).
    @Test func collectionPlaytimeCaptionStaysOneLine() {
        let label = CompilationCollectionPlaytimeLabel(seconds: 2310 * 3600 + 6 * 60)  // "2310 h 6"
        let narrow = fittingHeight(label, width: Self.inner(300))
        let wide = fittingHeight(label, width: Self.inner(440))
        #expect(narrow == wide, "collection playtime caption wrapped: \(narrow) vs \(wide)")
    }

    /// The one-line me-vs-average summary stays one line (it scales down before wrapping).
    @Test func playtimeComparisonStaysOneLine() {
        let bar = PlaytimeBar.make(mineSeconds: 2310 * 3600 + 5 * 60,
                                   rushed: 410 * 3600, main: 620 * 3600, completionist: 1240 * 3600)
        let label = PlaytimeComparisonLabel(bar: bar)
        let narrow = fittingHeight(label, width: Self.inner(300))
        let wide = fittingHeight(label, width: Self.inner(440))
        #expect(narrow == wide, "summary wrapped: \(narrow) vs \(wide)")
    }
}
