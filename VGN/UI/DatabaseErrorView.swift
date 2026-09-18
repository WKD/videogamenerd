import SwiftUI
import AppKit

/// Shown in place of the main window when the database can't be opened
/// (PLAN §9 Safety). Gives the reason and the file path, and offers to reveal
/// the folder in Finder or quit — never a silent crash.
struct DatabaseErrorView: View {
    let failure: AppEnvironment.DatabaseOpenFailure

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("VGN can't open its library")
                .font(.title2.bold())

            Text(failure.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            GroupBox {
                Text(failure.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxWidth: 460)

            HStack(spacing: 12) {
                Button("Reveal in Finder") { revealInFinder() }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: failure.path)
        // Reveal the containing folder even if the file itself doesn't exist.
        let folder = url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting(
            FileManager.default.fileExists(atPath: url.path) ? [url] : [folder]
        )
    }
}
