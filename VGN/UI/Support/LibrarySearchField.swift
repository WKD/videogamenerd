import SwiftUI

/// The toolbar search field: magnifier · text · clear button (shown while there is
/// text), styled like a native search field. A plain `TextField(.roundedBorder)` has no
/// clear button on macOS, and `.searchable` would take the key handling (↓ into the
/// grid, esc, ↩) away from the view model.
struct LibrarySearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var onClear: () -> Void
    var onDownArrow: () -> Void
    var onEscape: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .accessibilityIdentifier(A11yID.toolbarSearch)
                .onKeyPress(.downArrow) { onDownArrow(); return .handled }
                .onKeyPress(.escape) { onEscape(); return .handled }
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button(action: onClear) {
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
                .strokeBorder(focus.wrappedValue ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.25),
                              lineWidth: focus.wrappedValue ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { focus.wrappedValue = true }      // click the magnifier / padding → focus
    }
}
