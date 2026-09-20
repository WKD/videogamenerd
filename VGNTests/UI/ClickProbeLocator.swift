import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Test-support additions to ``ClickProbeWindow`` (defined in `FilterChipsClickTests.swift`)
/// for the wave-18 click-probe sweep.
///
/// **The safety rule that matters most:** a synthetic click must never land on a `Menu` /
/// menu-style `Picker` / pop-up button — it opens a REAL menu on the owner's screen and blocks
/// the whole run until a human dismisses it (`docs/LIMITATIONS.md` §3, happened twice). Two
/// defences here:
///  1. `safeClick` refuses any point that sits over an `NSPopUpButton` (SwiftUI `Menu` and
///     menu-style `Picker` are backed by one), so a guarded sweep can never open a menu.
///  2. Callers host an **isolated component** (a single card / sheet body) or bound the sweep to
///     a region provably free of menus, and use `clickSegment` — which clicks a precise segment
///     of a real `NSSegmentedControl` — for segmented pickers instead of sweeping near them.
///
/// (An accessibility-identifier locator was tried first; SwiftUI does not materialise its
/// accessibility peer tree in an off-screen, never-key, in-process window — only ~60 AppKit
/// chrome nodes exist, none carrying the app's identifiers — so location falls back to the
/// codebase's established coordinate-sweep idiom plus AppKit control frames.)
@MainActor
extension ClickProbeWindow {

    // MARK: - AppKit control location (these DO exist off-screen)

    /// The first AppKit control of a given type anywhere under the content view. Segmented
    /// controls, sliders and pop-up buttons are real `NSView`s even inside a SwiftUI host.
    func firstAppKitView<T: NSView>(ofType _: T.Type) -> T? {
        guard let root = window.contentView else { return nil }
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if let hit = v as? T { return hit }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    /// Any `NSPopUpButton` whose frame (window coordinates) contains `point` — the menu guard.
    func popUpButton(atWindowPoint point: NSPoint) -> NSPopUpButton? {
        guard let root = window.contentView else { return nil }
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if let popUp = v as? NSPopUpButton, popUp.convert(popUp.bounds, to: nil).contains(point) {
                return popUp
            }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    // MARK: - Safe clicking

    /// Click a window-coordinate point, refusing (returning false) if a pop-up button sits under
    /// it — a synthetic click on a menu-backed control opens a real menu and blocks the run.
    @discardableResult
    func safeClick(atWindowPoint point: NSPoint) -> Bool {
        if popUpButton(atWindowPoint: point) != nil { return false }
        click(at: point)
        return true
    }

    /// A real double-click at a window-coordinate point (two downs, the second `clickCount == 2`),
    /// for a control that resolves a single tap only after the double-click interval — a rapid
    /// single-click sweep never lets that single tap fire (a `count:2`-over-`count:1` tap stack).
    func doubleClick(at point: NSPoint) {
        func event(_ type: NSEvent.EventType, _ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: count, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp, 1), atStart: false)
        window.sendEvent(event(.leftMouseDown, 1))
        NSApp.postEvent(event(.leftMouseUp, 2), atStart: false)
        window.sendEvent(event(.leftMouseDown, 2))
    }

    /// A pop-up-guarded double-click.
    @discardableResult
    func safeDoubleClick(atWindowPoint point: NSPoint) -> Bool {
        if popUpButton(atWindowPoint: point) != nil { return false }
        doubleClick(at: point)
        return true
    }

    /// Click the centre of one segment of the first `NSSegmentedControl` (a real, safe AppKit
    /// control — never a menu). `index` is 0-based left→right. Polls for the control to lay out.
    @discardableResult
    func clickSegment(_ index: Int, of segmentCount: Int, timeout: Duration = .seconds(4)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let seg = firstAppKitView(ofType: NSSegmentedControl.self), seg.frame.width > 0 {
                let f = seg.convert(seg.bounds, to: nil)          // window coordinates
                let segWidth = f.width / CGFloat(segmentCount)
                let x = f.minX + segWidth * (CGFloat(index) + 0.5)
                return safeClick(atWindowPoint: NSPoint(x: x, y: f.midY))
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return false
    }

    /// Whether the window currently holds an `NSSegmentedControl` (used to tell a segmented
    /// picker from a menu-style one at a given width).
    func hasSegmentedControl() -> Bool { firstAppKitView(ofType: NSSegmentedControl.self) != nil }

    // MARK: - Guarded band sweep

    /// A patient, pop-up-guarded sweep of a horizontal band in **window** coordinates
    /// (`yTop` down to `yBottom`), across the window width. Stops as soon as `until` is true.
    /// Every click goes through `safeClick`, so it can never open a menu. Up to three passes,
    /// each more patient (SwiftUI can need longer to process a click under parallel load).
    @discardableResult
    func sweepBand(yTop: CGFloat, yBottom: CGFloat, stepX: CGFloat = 16, stepY: CGFloat = 12,
                   xMin: CGFloat? = nil, xMax: CGFloat? = nil, maxClicks: Int = 900,
                   rightToLeft: Bool = false, doubleClick: Bool = false, until: () -> Bool) async -> Bool {
        let lo = xMin ?? 6
        let hi = xMax ?? (window.frame.width - 6)
        guard hi > lo, yTop > yBottom else { return until() }
        let xs = Array(stride(from: lo, through: hi, by: stepX))
        let ordered = rightToLeft ? xs.reversed() : Array(xs)
        var clicks = 0
        // Two passes, the second a little more patient (SwiftUI can lag a click under parallel
        // load). Hard-capped so a genuine miss returns in bounded time — never a 3-minute hang.
        for wait in [10, 45] {
            for y in stride(from: yTop, through: yBottom, by: -stepY) {
                for x in ordered {
                    let p = NSPoint(x: x, y: y)
                    _ = doubleClick ? safeDoubleClick(atWindowPoint: p) : safeClick(atWindowPoint: p)
                    clicks += 1
                    try? await Task.sleep(for: .milliseconds(wait))
                    if until() { return true }
                    if clicks >= maxClicks { return until() }
                }
            }
        }
        return until()
    }

    /// Sweep the band just under the toolbar down `height` points (the region most exposed to
    /// the two shipped dead-click bugs).
    @discardableResult
    func sweepTopBand(height: CGFloat, stepX: CGFloat = 16, stepY: CGFloat = 12,
                      maxClicks: Int = 900, rightToLeft: Bool = false, doubleClick: Bool = false,
                      until: () -> Bool) async -> Bool {
        await sweepBand(yTop: contentTop - 2, yBottom: contentTop - height,
                        stepX: stepX, stepY: stepY, maxClicks: maxClicks,
                        rightToLeft: rightToLeft, doubleClick: doubleClick, until: until)
    }

    /// Sweep a band anchored to the bottom of the window (banners, sheet footer button rows).
    @discardableResult
    func sweepBottomBand(height: CGFloat, stepX: CGFloat = 16, stepY: CGFloat = 12,
                         rightToLeft: Bool = false, until: () -> Bool) async -> Bool {
        await sweepBand(yTop: height, yBottom: 4, stepX: stepX, stepY: stepY,
                        rightToLeft: rightToLeft, until: until)
    }

    /// A short readiness wait for an isolated component (cheaper than the 1 s `settle()`); the
    /// sweeps do their own patient retrying, so this only needs to let first layout land.
    func settleShort() async { try? await Task.sleep(for: .milliseconds(250)) }

    /// Poll a condition until true or a hard deadline (no wall-clock assertion; correctness
    /// only). Returns whether it became true.
    @discardableResult
    func poll(timeout: Duration = .seconds(4), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }
}
