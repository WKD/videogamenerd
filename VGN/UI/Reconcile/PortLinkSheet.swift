import SwiftUI
import Observation

/// Confirm step when the owner picks a **port** result in the Link-to-IGDB sheet
/// (PLAN §5.1 D4 — "a port is the same game"): offer to link to the original, with a
/// secondary "Use the port entry instead". `@MainActor @Observable`; the presenter
/// performs the actual link / merge.
@MainActor
@Observable
final class PortLinkModel: Identifiable {
    nonisolated var id: Int64 { gameID }
    let gameID: Int64
    /// The port result's own title (what the owner clicked).
    let portTitle: String
    /// The original game the port links to.
    let parent: PortParentInfo

    var onLinkToOriginal: () -> Void = {}
    var onUsePort: () -> Void = {}
    var onCancel: () -> Void = {}

    init(gameID: Int64, portTitle: String, parent: PortParentInfo) {
        self.gameID = gameID
        self.portTitle = portTitle
        self.parent = parent
    }

    var linkTitle: String { "Link to \(parent.display)" }
}

struct PortLinkSheet: View {
    @Bindable var model: PortLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                Text("This is a port").font(.headline)
            }
            // Bounded, wrapping copy in a fixed-width sheet (never the detail column).
            Text("“\(model.portTitle)” is IGDB's port entry. A port is the same game, so linking "
                 + "to the original keeps one game to rank — it just gains this copy on its platform.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Use the port entry instead") { model.onUsePort() }
                Spacer()
                Button("Cancel") { model.onCancel() }.keyboardShortcut(.cancelAction)
                Button(model.linkTitle) { model.onLinkToOriginal() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
