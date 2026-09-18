#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VGN

// MARK: - Off-screen SwiftUI snapshot rendering
//
// Renders any SwiftUI view into a PNG *without ever showing a window*: an
// `NSHostingView` inside a borderless, never-ordered-front `NSWindow` with a
// forced `NSAppearance`, laid out at a fixed size, spun on the run loop until
// async `.task`s / observations have delivered, then captured with
// `bitmapImageRepForCachingDisplay` / `cacheDisplay`. `ImageRenderer` is *not*
// used — it cannot render AppKit-backed controls (List, TextField, split views,
// toolbars), which is most of this app.
//
// Determinism: sample/preview data sources emit once and finish (no clocks, no
// network, no live DB), animations are disabled, and models are driven to their
// loaded state *before* capture rather than relying on `onAppear` firing in an
// unshown window.
//
// Output: every run writes `<repo>/.build/snapshots/<name>@<appearance>.png`
// (git-ignored) and an `index.html` contact sheet. Reference comparison is
// opt-in (`VGN_SNAPSHOT_VERIFY=1`) because sub-pixel text AA is not bit-stable
// across machines; generation is always on so agents/owner get eyes every run.
// `VGN_SNAPSHOT_RECORD=1` (re)writes the committed references.

/// The forced appearance for a snapshot.
enum SnapAppearance: String, CaseIterable, Sendable {
    case light
    case dark

    var nsName: NSAppearance.Name { self == .light ? .aqua : .darkAqua }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

/// A named render size. Layout-sensitive screens are captured at two of these.
struct SnapSize: Sendable {
    var width: CGFloat
    var height: CGFloat
    var cgSize: CGSize { CGSize(width: width, height: height) }

    /// The wide main-window size (PLAN §8 split view has room for the inspector).
    static let large = SnapSize(width: 1200, height: 780)
    /// A cramped main-window size (sidebar + grid, narrow inspector).
    static let compact = SnapSize(width: 900, height: 600)
}

/// Perceptual comparison thresholds (documented in `docs/snapshots.md`).
enum SnapThresholds {
    /// A pixel counts as "changed" only if any RGBA channel differs by more than
    /// this (0…255) — absorbs anti-aliasing jitter.
    static let channelTolerance = 12
    /// The snapshot fails only if more than this fraction of pixels changed.
    static let maxChangedFraction = 0.02
}

@MainActor
enum SnapshotHarness {

    // MARK: Paths (derived from source location, not the flattened bundle)

    /// `.../VGNTests/Snapshots`
    private static let snapshotsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    /// `.../` (repo / worktree root — parent of `VGNTests`)
    private static let repoRoot = snapshotsDir.deletingLastPathComponent().deletingLastPathComponent()
    /// Committed reference PNGs (`snap-…` prefixed; read from source on disk).
    static let referenceDir = snapshotsDir.appendingPathComponent("Reference")
    /// Git-ignored generated output.
    static let outputDir = repoRoot.appendingPathComponent(".build/snapshots")

    // A macOS unit-test host does NOT inherit xcodebuild's shell environment, so
    // recording/verifying is signalled by a sentinel FILE that the test process
    // (which reads the disk anyway) checks. `scripts/snapshots.sh` creates and
    // removes them; the env vars remain as a fallback for direct invocations.
    private static var recordSentinel: URL { repoRoot.appendingPathComponent(".build/snapshot-record") }
    private static var verifySentinel: URL { repoRoot.appendingPathComponent(".build/snapshot-verify") }

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["VGN_SNAPSHOT_RECORD"] == "1"
            || FileManager.default.fileExists(atPath: recordSentinel.path)
    }
    static var isVerifying: Bool {
        ProcessInfo.processInfo.environment["VGN_SNAPSHOT_VERIFY"] == "1"
            || FileManager.default.fileExists(atPath: verifySentinel.path)
    }

    // MARK: Contact-sheet registry (rebuilt on disk after every capture)

    struct Entry: Sendable { var group: String; var name: String; var appearance: SnapAppearance }
    private static var registry: [Entry] = []

    /// Hosting windows are retained for the whole run rather than torn down after
    /// each capture: destroying a graph host while a SwiftUI async observation
    /// transaction is still pending trips an AttributeGraph precondition (SIGABRT).
    /// Off-screen borderless windows are cheap; they die with the test process.
    private static var retainedWindows: [NSWindow] = []

    // MARK: Public entry

    /// Render a view for every appearance, write PNGs, refresh the contact sheet,
    /// and (only under `VGN_SNAPSHOT_VERIFY`) diff against the committed reference.
    /// `group` clusters variants on the contact sheet; `name` is the full stem.
    static func capture(
        group: String,
        _ name: String,
        size: SnapSize = .large,
        appearances: [SnapAppearance] = SnapAppearance.allCases,
        settle: Int = 3,
        _ content: @escaping () -> some View,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for appearance in appearances {
            // A SwiftUI backdrop of the appearance's window colour makes the
            // captured rep opaque and gives dark-mode (light) text the right
            // contrast — without it, SwiftUI paints no background and the hosting
            // rep captures white, so dark-mode content reads white-on-white.
            let view = ZStack {
                Color(nsColor: windowBackground(for: appearance)).ignoresSafeArea()
                content()
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, appearance.colorScheme)
            .transaction { $0.disablesAnimations = true }
            guard let rep = await renderToBitmap(view, size: size.cgSize,
                                                 appearance: appearance, settleRounds: settle) else {
                Issue.record("Snapshot \(name)@\(appearance.rawValue) failed to render",
                             sourceLocation: sourceLocation)
                continue
            }
            let png = pngData(from: rep)
            writeOutput(png, name: name, appearance: appearance)
            record(Entry(group: group, name: name, appearance: appearance))

            // The smoke suite is a harness self-test whose screens are also
            // captured by the real suites, so it is left out of the committed
            // reference set (it still writes PNGs for the contact sheet).
            let referenced = group != "smoke"
            if isRecording && referenced { writeReference(rep, name: name, appearance: appearance) }
            if isVerifying && referenced { verify(rep, name: name, appearance: appearance, sourceLocation: sourceLocation) }
        }
        writeContactSheet()
    }

    // MARK: Rendering

    /// Build the off-screen window + hosting view, drive the run loop, capture.
    static func renderToBitmap(
        _ view: some View, size: CGSize, appearance: SnapAppearance, settleRounds: Int
    ) async -> NSBitmapImageRep? {
        // An `NSHostingController` (not a bare `NSHostingView`) gives the proper
        // view-controller containment that `NavigationSplitView` / toolbars need
        // to lay out off-screen without asserting.
        let controller = NSHostingController(rootView: AnyView(view))
        let host = controller.view
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance.nsName)

        // Borderless, off-screen, never ordered front. It has a backing store so
        // SwiftUI lays out and its `.task`s can run, but it is never made key or
        // shown on any display.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance.nsName)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        retainedWindows.append(window)

        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true

        // Let async data sources / observations deliver, and layout/display settle.
        await settle(rounds: settleRounds)
        host.layoutSubtreeIfNeeded()
        host.display()
        // One more run-loop spin so SwiftUI's deferred text/glyph pass lands.
        pumpMainRunLoop(0.02)
        host.display()

        let rep = snapshot1x(of: host, size: size, appearance: appearance)
        // Flush any observation transaction still queued against this graph host
        // before returning, so nothing fires mid-teardown later.
        pumpMainRunLoop(0.01)
        return rep
    }

    /// The opaque window backdrop for an appearance, so light dark-mode text is
    /// not composited onto transparency (which reads as invisible over white).
    /// Fixed values (≈ the aqua / darkAqua window background) keep it deterministic
    /// and free of deprecated dynamic-colour resolution.
    private static func windowBackground(for appearance: SnapAppearance) -> NSColor {
        switch appearance {
        case .light: return NSColor(deviceWhite: 0.925, alpha: 1)
        case .dark: return NSColor(deviceWhite: 0.118, alpha: 1)
        }
    }

    /// Pump both the AppKit run loop (timers, main-queue work, layout) and the
    /// Swift cooperative executor (async continuations), so scripted models that
    /// finish their one-shot streams are fully drained before capture.
    static func settle(rounds: Int, interval: TimeInterval = 0.02) async {
        // Async data-delivery phase: sleep on the MainActor so the one-shot
        // streams' continuations resume and mutate the models. Deliberately does
        // NOT spin a nested `RunLoop` here — doing so re-enters SwiftUI's
        // observation transactions from inside an `await` and trips an
        // AttributeGraph precondition on complex hosts (NavigationSplitView).
        for _ in 0..<max(1, rounds) {
            try? await Task.sleep(for: .seconds(interval))
            await Task.yield()
        }
    }

    /// Spin the main run loop for a beat. Synchronous on purpose: `RunLoop.current`
    /// is banned from async contexts, but a plain `@MainActor` function may use it.
    /// Only called from the synchronous display phase (never mid-`await`), so it
    /// forces SwiftUI's deferred text/glyph pass without re-entrant transactions.
    static func pumpMainRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Capture at 1× scale (references stay small): grab the backing-scale rep the
    /// documented way, then downscale into a fresh 1× RGBA rep.
    private static func snapshot1x(of host: NSView, size: CGSize, appearance: SnapAppearance) -> NSBitmapImageRep? {
        guard let hi = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: hi)
        guard let out = makeCanvas(size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = NSRect(origin: .zero, size: size)
        windowBackground(for: appearance).setFill()
        rect.fill()
        hi.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// A canonical 1× device-RGBA bitmap of exactly `size` points/pixels.
    private static func makeCanvas(_ size: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded()), pixelsHigh: Int(size.height.rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func pngData(from rep: NSBitmapImageRep) -> Data {
        rep.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: File output

    private static func writeOutput(_ png: Data, name: String, appearance: SnapAppearance) {
        let url = outputDir.appendingPathComponent("\(name)@\(appearance.rawValue).png")
        try? png.write(to: url)
    }

    /// References are downscaled to this max width so the committed set stays
    /// small (≈ 3.5× fewer bytes than full 1× at 1200 pt); comparison downscales
    /// the current capture to match, and the perceptual tolerance absorbs the
    /// resampling. Full-resolution captures still land in `.build/snapshots`.
    private static let referenceMaxWidth: CGFloat = 560

    private static func writeReference(_ rep: NSBitmapImageRep, name: String, appearance: SnapAppearance) {
        try? FileManager.default.createDirectory(at: referenceDir, withIntermediateDirectories: true)
        let url = referenceDir.appendingPathComponent("snap-\(name)@\(appearance.rawValue).png")
        try? pngData(from: downscaled(rep, maxWidth: referenceMaxWidth)).write(to: url)
    }

    /// Draw a bitmap into a smaller canvas (no-op when already within `maxWidth`).
    private static func downscaled(_ rep: NSBitmapImageRep, maxWidth: CGFloat) -> NSBitmapImageRep {
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        guard w > maxWidth else { return rep }
        let scale = maxWidth / w
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let out = makeCanvas(size) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: Reference comparison (opt-in)

    private static func verify(
        _ rep: NSBitmapImageRep, name: String, appearance: SnapAppearance, sourceLocation: SourceLocation
    ) {
        let refURL = referenceDir.appendingPathComponent("snap-\(name)@\(appearance.rawValue).png")
        guard let refData = try? Data(contentsOf: refURL), let refRep = canonicalize(refData) else {
            Issue.record("No reference for \(name)@\(appearance.rawValue) — run scripts/snapshots.sh --record",
                         sourceLocation: sourceLocation)
            return
        }
        // Downscale the current capture to the reference's width before comparing.
        guard let current = canonicalize(pngData(from: downscaled(rep, maxWidth: referenceMaxWidth))) else { return }
        let result = compare(current, refRep)
        if result.changedFraction > SnapThresholds.maxChangedFraction {
            if let diff = result.diff {
                let url = outputDir.appendingPathComponent("\(name)@\(appearance.rawValue).diff.png")
                try? pngData(from: diff).write(to: url)
            }
            let pct = String(format: "%.2f%%", result.changedFraction * 100)
            let allowed = String(format: "%.0f%%", SnapThresholds.maxChangedFraction * 100)
            Issue.record(
                "Snapshot \(name)@\(appearance.rawValue) changed: \(pct) of pixels differ (> \(allowed) allowed)",
                sourceLocation: sourceLocation)
        }
    }

    /// Redraw arbitrary PNG data into the canonical 1× RGBA layout so two reps are
    /// byte-comparable regardless of how the PNG was encoded.
    private static func canonicalize(_ png: Data) -> NSBitmapImageRep? {
        guard let src = NSBitmapImageRep(data: png) else { return nil }
        let size = src.size == .zero ? CGSize(width: src.pixelsWide, height: src.pixelsHigh) : src.size
        guard let out = makeCanvas(size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        src.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    private struct CompareResult { var changedFraction: Double; var diff: NSBitmapImageRep? }

    private static func compare(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CompareResult {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let pa = a.bitmapData, let pb = b.bitmapData else {
            return CompareResult(changedFraction: 1, diff: nil)
        }
        let w = a.pixelsWide, h = a.pixelsHigh
        let rowA = a.bytesPerRow, rowB = b.bytesPerRow, spp = a.samplesPerPixel
        let diff = makeCanvas(CGSize(width: w, height: h))
        let pd = diff?.bitmapData
        let rowD = diff?.bytesPerRow ?? 0
        var changed = 0
        let tol = SnapThresholds.channelTolerance
        for y in 0..<h {
            for x in 0..<w {
                let ia = y * rowA + x * spp
                let ib = y * rowB + x * spp
                var isDiff = false
                for c in 0..<min(spp, 4) where abs(Int(pa[ia + c]) - Int(pb[ib + c])) > tol { isDiff = true; break }
                if isDiff { changed += 1 }
                if let pd {
                    let id = y * rowD + x * 4
                    pd[id + 0] = isDiff ? 255 : pa[ia + 0]
                    pd[id + 1] = isDiff ? 0 : pa[min(ia + 1, ia)]
                    pd[id + 2] = isDiff ? 0 : pa[min(ia + 2, ia)]
                    pd[id + 3] = 255
                }
            }
        }
        return CompareResult(changedFraction: Double(changed) / Double(w * h), diff: diff)
    }

    // MARK: Contact sheet

    private static func record(_ entry: Entry) {
        registry.removeAll { $0.name == entry.name && $0.appearance == entry.appearance }
        registry.append(entry)
    }

    private static func writeContactSheet() {
        let groups = Dictionary(grouping: registry, by: \.group)
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>VGN snapshots</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
                 background: #1a1a1c; color: #eee; }
          h1 { font-size: 18px; } h2 { font-size: 15px; margin: 28px 0 10px; border-bottom: 1px solid #444; padding-bottom: 6px; }
          .row { display: flex; flex-wrap: wrap; gap: 18px; }
          .pair { background: #262629; border: 1px solid #3a3a3d; border-radius: 8px; padding: 10px; }
          .pair .name { font-size: 12px; color: #bbb; margin-bottom: 6px; font-family: ui-monospace, monospace; }
          .shots { display: flex; gap: 8px; }
          .shot { text-align: center; }
          .shot span { display: block; font-size: 10px; color: #888; margin-bottom: 3px; text-transform: uppercase; }
          .shot.light img { background: #fff; } .shot.dark img { background: #000; }
          img { max-height: 340px; border-radius: 4px; box-shadow: 0 1px 4px rgba(0,0,0,.5); }
        </style></head><body>
        <h1>VGN — off-screen snapshot contact sheet</h1>
        <p style="color:#999">Generated by the unit tests. Light / dark side by side. Regenerate with <code>scripts/snapshots.sh</code>.</p>
        """
        for group in groups.keys.sorted() {
            html += "<h2>\(escape(group))</h2><div class=\"row\">"
            let byName = Dictionary(grouping: groups[group] ?? [], by: \.name)
            for name in byName.keys.sorted() {
                html += "<div class=\"pair\"><div class=\"name\">\(escape(name))</div><div class=\"shots\">"
                for appearance in SnapAppearance.allCases {
                    guard byName[name]?.contains(where: { $0.appearance == appearance }) == true else { continue }
                    let file = "\(name)@\(appearance.rawValue).png"
                    html += "<div class=\"shot \(appearance.rawValue)\"><span>\(appearance.rawValue)</span>"
                    html += "<img src=\"\(file)\" loading=\"lazy\"></div>"
                }
                html += "</div></div>"
            }
            html += "</div>"
        }
        html += "</body></html>"
        try? html.data(using: .utf8)?.write(to: outputDir.appendingPathComponent("index.html"))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
#endif
