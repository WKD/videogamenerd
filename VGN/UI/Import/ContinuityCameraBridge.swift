#if canImport(AppKit)
import AppKit
import SwiftUI

/// AppKit bridge for Continuity Camera "Take Photo" (PLAN §6.2 step 1). SwiftUI on
/// macOS 15 has no first-class control, so this uses the documented Services mechanism:
/// a helper `NSButton` that is a valid image requestor (`validRequestor(forSendType:
/// returnType:)` + `NSServicesMenuRequestor`), made first responder, that pops an empty
/// menu carrying the `importFromDeviceIdentifier` placeholder — into which macOS injects
/// the "Import from iPhone or iPad" items. The captured image arrives on the pasteboard
/// via `readSelection(from:)` and is written to a temp JPEG the pipeline can read.
///
/// NOTE (human verification): the actual iPhone hand-off cannot be exercised headlessly
/// or in CI; it needs a signed-in iPhone nearby. Drag-drop and the file picker are the
/// paths covered by automated tests.
final class ContinuityCameraButtonView: NSButton, NSServicesMenuRequestor {
    var onCaptured: (URL) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    nonisolated func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let image = NSImage(pasteboard: pasteboard),
              let url = Self.writeTemporaryJPEG(image) else { return false }
        MainActor.assumeIsolated { onCaptured(url) }   // AppKit delivers on the main thread
        return true
    }

    nonisolated func writeSelection(
        to pasteboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool { false }

    @objc func presentImportMenu() {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let placeholder = NSMenuItem()
        placeholder.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(placeholder)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    nonisolated static func writeTemporaryJPEG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-continuity-\(UUID().uuidString).jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }
}

/// SwiftUI wrapper: a "Take Photo" button that triggers the Continuity Camera menu.
struct ContinuityCameraButton: NSViewRepresentable {
    var title: String = "Take Photo"
    var onCaptured: (URL) -> Void

    func makeNSView(context: Context) -> ContinuityCameraButtonView {
        let button = ContinuityCameraButtonView()
        button.title = title
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Take Photo")
        button.imagePosition = .imageLeading
        button.target = button
        button.action = #selector(ContinuityCameraButtonView.presentImportMenu)
        button.onCaptured = onCaptured
        return button
    }

    func updateNSView(_ view: ContinuityCameraButtonView, context: Context) {
        view.onCaptured = onCaptured
    }
}
#endif
