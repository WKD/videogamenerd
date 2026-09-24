import SwiftUI

/// The inspector's **Holds Up Today?** control (PLAN §7b/§8), under the tier: three segments
/// (Holds Up · Of Its Time · Too Archaic) plus a Clear affordance, each with the owner's
/// explanation as its tooltip. Shown only for **played** games (the caller hides it
/// otherwise — only a played game can be judged today).
///
/// Keys mirror the inspector's status keys (⌃⌘1…5, ⌃⌘0 clears) with ⌥ added so they never
/// collide: **⌃⌥⌘1** Holds Up, **⌃⌥⌘2** Of Its Time, **⌃⌥⌘3** Too Archaic, **⌃⌥⌘0** Clear.
/// They are registered ONCE, on the menu-bar Game ▸ Holds Up Today? items (so they act on the
/// grid selection whether or not the inspector is open — the rating pass); this control only
/// names them in its tooltips, so no key equivalent is ever registered twice.
///
/// Every line is bounded (`lineLimit`) — never an unbounded ideal height in the detail column.
struct HoldsUpInspectorRow: View {
    /// The current mark (`nil` = Unrated). For a multi-selection: the common mark, or nil.
    let current: HoldsUp?
    /// The importer-filled first-played date (PSN, v9), shown as a quiet "first played in
    /// 1991" so the owner notices when they are judging a memory (PLAN §7b). nil ⇒ nothing.
    var firstPlayedAt: Date? = nil
    let onPick: (HoldsUp?) -> Void

    static let modifiers: EventModifiers = [.control, .option, .command]

    /// The key for each value (the Clear key is `0`).
    static func key(for value: HoldsUp) -> KeyEquivalent {
        switch value {
        case .holdsUp: return "1"
        case .ofItsTime: return "2"
        case .tooArchaic: return "3"
        }
    }

    /// "⌃⌥⌘1" — the shortcut hint shown in a tooltip.
    static func keyHint(for value: HoldsUp?) -> String {
        "⌃⌥⌘" + (value.map { String(key(for: $0).character) } ?? "0")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(HoldsUpMenuItems.title).font(.headline)
                Spacer(minLength: 0)
                clearButton
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { segments }
                VStack(alignment: .leading, spacing: 4) { segments }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.inspectorHoldsUp)
            .accessibilityValue(HoldsUp.label(for: current))
            Text(current?.explanation ?? Self.unratedCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let caption = FirstPlayedCaption.text(firstPlayedAt) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    static let unratedCaption = "Unrated — how does it play today? A fact about the game now, not a rank."

    @ViewBuilder
    private var segments: some View {
        ForEach(HoldsUp.allCases) { value in
            Button {
                onPick(value)
            } label: {
                Text(value.label)
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(HoldsUpSegmentStyle(isSelected: current == value))
            .appKitTooltip(value.explanation + "  (" + Self.keyHint(for: value) + ")")
            .accessibilityAddTraits(current == value ? .isSelected : [])
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        Button {
            onPick(nil)
        } label: {
            Label("Clear", systemImage: "xmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(current == nil)
        .opacity(current == nil ? 0.35 : 1)
        .appKitTooltip("Clear — back to Unrated  (" + Self.keyHint(for: nil) + ")")
    }
}

/// One segment of the Holds Up control: a small rounded capsule, filled with the accent
/// colour when selected (a segmented look that keeps a per-value tooltip and shortcut).
private struct HoldsUpSegmentStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// "First played in 1991" — the quiet caption shown next to a game whose importer supplied a
/// first-played date (PLAN §7b "Helping me judge"). Pure, so Play Next and the inspector agree.
enum FirstPlayedCaption {
    static func text(_ date: Date?, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        return "First played in \(calendar.component(.year, from: date))"
    }
}
