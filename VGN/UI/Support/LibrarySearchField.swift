import AppKit
import SwiftUI

/// The toolbar search field: magnifier · text · clear button (shown while there is
/// text), styled like a native search field. A plain `TextField(.roundedBorder)` has no
/// clear button on macOS, and `.searchable` would take the key handling (↓ into the
/// grid, esc, ↩) away from the view model.
///
/// Focus lives HERE, not in `RootView`: the field is hosted in the window toolbar (its
/// own hosting view), and a `@FocusState` owned by `RootView` and passed down never
/// moved focus into it — ⌘F / View ▸ Find did nothing (found by the UI smoke suite,
/// wave 22). The owner asks for focus by bumping `focusRequests`; the field reports
/// focus changes through `onFocusChange`.
struct LibrarySearchField: View {
    @Binding var text: String
    /// Bumped by ⌘F (`LibraryViewModel.searchFocusRequests`) → the field takes focus.
    var focusRequests: Int = 0
    var onFocusChange: (Bool) -> Void = { _ in }
    var onClear: () -> Void
    var onDownArrow: () -> Void
    /// esc: return true when it cleared the query (the field keeps focus); false → the
    /// field gives up focus.
    var onEscape: () -> Bool
    var onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityIdentifier(A11yID.toolbarSearch)
                .onKeyPress(.downArrow) { onDownArrow(); return .handled }
                .onKeyPress(.escape) {
                    if !onEscape() { focused = false }
                    return .handled
                }
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { onClear(); focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(A11yID.toolbarSearch + ".clear")
                .appKitTooltip("Clear search (esc)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.25),
                              lineWidth: focused ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { focused = true }      // click the magnifier / padding → focus
        .onChange(of: focusRequests) { _, _ in focused = true }
        // Belt and braces: a `@FocusState` write alone does not reliably reach a field
        // hosted in the NSToolbar, so the anchor also makes the field's NSTextField first
        // responder directly.
        .background(SearchFieldFocusAnchor(requests: focusRequests))
        .onChange(of: focused) { _, isFocused in onFocusChange(isFocused) }
    }
}

/// A zero-size, click-through, accessibility-hidden NSView next to the search field. When
/// `requests` changes it makes the nearest NSTextField (the search field's backing view,
/// found by walking up its own superviews) the window's first responder.
private struct SearchFieldFocusAnchor: NSViewRepresentable {
    let requests: Int

    func makeNSView(context: Context) -> SearchFieldFocusAnchorView {
        let view = SearchFieldFocusAnchorView()
        view.lastRequest = requests      // the initial value is not a request
        return view
    }

    func updateNSView(_ view: SearchFieldFocusAnchorView, context: Context) {
        guard view.lastRequest != requests else { return }
        view.lastRequest = requests
        DispatchQueue.main.async { view.focusNearestTextField() }
    }
}

final class SearchFieldFocusAnchorView: NSView {
    var lastRequest = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    func focusNearestTextField() {
        var node = superview
        while let current = node {
            if let field = Self.firstTextField(in: current) {
                window?.makeFirstResponder(field)
                return
            }
            node = current.superview
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }
}
