import SwiftUI

/// The slim header above the grid when **PS Plus Only** is selected (PLAN §8/§13.3): what the
/// list is, how it differs from THE VAULT ▸ PS Plus, and — when the owner set one in Settings ▸
/// PlayStation — the planned leave date ("Leaves with PS Plus around March 2027 · 12 games").
/// Mounted like the other review-list headers; bounded text only (`lineLimit`), never
/// `fixedSize(vertical:)`.
struct PSPlusOnlyHeader: View {
    let count: Int
    /// Injected for tests; the live app reads the owner's setting.
    var deadline: (year: Int, month: Int)? = PSPlusDeadlinePreferences().picked

    var body: some View {
        HStack(spacing: 8) {
            PSPlusBadgeView(size: 16, shadow: false)
            Text(Self.message(count: count, deadline: deadline))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .appKitTooltip(SidebarView.psPlusOnlyTooltip)
        .accessibilityIdentifier("psPlusOnly.header")
    }

    /// Pure copy (tested).
    static func message(count: Int, deadline: (year: Int, month: Int)?) -> String {
        let games = count == 1 ? "1 game" : "\(count) games"
        guard let deadline, (1...12).contains(deadline.month) else {
            return "Games you only have through PS Plus — they leave with the subscription. "
                + "(Claims you didn't add are in THE VAULT.) · \(games)"
        }
        let month = Self.monthNames[deadline.month - 1]
        return "Leaves with PS Plus around \(month) \(deadline.year) · \(games) you only have through PS Plus."
    }

    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                                     "August", "September", "October", "November", "December"]
}
