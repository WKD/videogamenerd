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

    // MARK: - Run-loop pumping & readiness (no fixed-sleep tiers)

    /// Advance the main run loop one small slice so AppKit delivers queued mouse events and SwiftUI
    /// flushes its transaction. This is the poll GRANULARITY — never a fixed per-click dwell: the
    /// callers below poll the post-condition between pumps and stop the instant it holds.
    func pump() async { try? await Task.sleep(for: .milliseconds(4)) }

    /// Synchronously deliver every queued AppKit event — including the mouse-up our `click` posted —
    /// so a click is FULLY processed before the next one is sent (no rapid-fire event pile-up, the
    /// cause of the wave-19 dropped-click flake), and a synchronous button action has already run by
    /// the time the post-condition is checked. Non-blocking: `.distantPast` returns at once when the
    /// queue is empty, so a miss stays cheap.
    func drainEvents(max: Int = 64) {
        var n = 0
        while n < max,
              let e = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(e)
            n += 1
        }
    }

    /// Total NSView descendants of the content view — a cheap "has the SwiftUI tree finished
    /// mounting?" proxy for the readiness wait.
    private func descendantViewCount() -> Int {
        guard let root = window.contentView else { return 0 }
        var n = 0
        var stack: [NSView] = [root]
        while let v = stack.popLast() { n += 1; stack.append(contentsOf: v.subviews) }
        return n
    }

    /// Wait for the hosted view to lay out: its descendant-view count settles (stable across two
    /// run-loop turns, after a small floor of turns), the same "stable across two turns" idea
    /// `SidebarJumpMatrixTests` uses on the sidebar frame. Replaces a fixed `settle` sleep —
    /// returns as soon as the tree is quiet and only waits longer under load. Bounded.
    func awaitReady(timeout: Duration = .milliseconds(1200)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last = -1, stableTurns = 0, turns = 0
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            let n = descendantViewCount()
            stableTurns = (n == last && n > 1) ? stableTurns + 1 : 0
            last = n
            turns += 1
            if turns >= 3 && stableTurns >= 2 { return }
            await pump()
        }
    }

    /// Poll `until` across run-loop turns until it holds or `budget` elapses. Returns the instant
    /// the post-condition holds — no fixed dwell. The building block of every click helper.
    @discardableResult
    func awaitCondition(_ budget: Duration, until: () -> Bool) async -> Bool {
        if until() { return true }
        let deadline = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < deadline {
            await pump()
            if until() { return true }
        }
        return until()
    }

    /// The robust single-click primitive: click a window-coordinate point (pop-up guarded), deliver
    /// the click's queued events deterministically, then poll `until` across run-loop turns until it
    /// holds or `timeout` elapses — never a fixed post-click sleep. Returns whether the
    /// post-condition held.
    @discardableResult
    func clickAndAwait(at point: NSPoint, timeout: Duration = .seconds(1),
                       until: () -> Bool) async -> Bool {
        guard safeClick(atWindowPoint: point) else { return until() }
        drainEvents()
        return await awaitCondition(timeout, until: until)
    }

    // MARK: - Guarded sweep (poll the post-condition, stop at first success)

    /// Click each point in order (pop-up guarded), checking `until` between clicks and stopping at
    /// the first success. A MISS costs a single run-loop turn (cheap, so a wide sweep stays fast);
    /// after each full pass a patient settle poll catches the RIGHT click still being processed
    /// under heavy parallel load (where SwiftUI can lag a click by seconds — the click was still
    /// delivered, so its effect surfaces and is caught here). No fixed-sleep tiers, and bounded —
    /// a genuinely dead control returns in a few seconds, never a multi-minute hang.
    @discardableResult
    func clickUntil(points: [NSPoint], settle: Duration = .seconds(3), passes: Int = 2,
                    doubleClick: Bool = false, until: () -> Bool) async -> Bool {
        if until() { return true }
        for _ in 0..<passes {
            for p in points {
                if popUpButton(atWindowPoint: p) != nil { continue }   // never open a real menu
                if doubleClick { self.doubleClick(at: p) } else { click(at: p) }
                drainEvents()                                           // deliver the click now
                if until() { return true }
                await pump()                                            // let async effects propagate
                if until() { return true }
            }
            if await awaitCondition(settle, until: until) { return true }
        }
        return until()
    }

    /// A bounded region of the window in window coordinates (`yTop` above `yBottom`).
    struct SweepRegion {
        var xMin: CGFloat, xMax: CGFloat, yTop: CGFloat, yBottom: CGFloat
    }

    /// The canonical region sweep: click every grid point of a bounded region (pop-up guarded)
    /// until `until` holds, polling the post-condition between clicks. `sweepBand`/`sweepTopBand`/
    /// `sweepBottomBand` are thin wrappers over this. (Callers `settle()`/`settleShort()` for
    /// layout before sweeping — the readiness wait is not repeated here.)
    @discardableResult
    func sweepUntil(region: SweepRegion, stepX: CGFloat = 16, stepY: CGFloat = 12,
                    rightToLeft: Bool = false, doubleClick: Bool = false,
                    maxClicks: Int = 900, until: () -> Bool) async -> Bool {
        guard region.xMax > region.xMin, region.yTop > region.yBottom else { return until() }
        let xsAsc = Array(stride(from: region.xMin, through: region.xMax, by: stepX))
        let xs = rightToLeft ? Array(xsAsc.reversed()) : xsAsc
        var points: [NSPoint] = []
        for y in stride(from: region.yTop, through: region.yBottom, by: -stepY) {
            for x in xs { points.append(NSPoint(x: x, y: y)) }
        }
        if points.count > maxClicks { points = Array(points.prefix(maxClicks)) }
        return await clickUntil(points: points, doubleClick: doubleClick, until: until)
    }

    /// A pop-up-guarded sweep of a horizontal band in **window** coordinates (`yTop` down to
    /// `yBottom`) across the window width. Stops as soon as `until` holds.
    @discardableResult
    func sweepBand(yTop: CGFloat, yBottom: CGFloat, stepX: CGFloat = 16, stepY: CGFloat = 12,
                   xMin: CGFloat? = nil, xMax: CGFloat? = nil, maxClicks: Int = 900,
                   rightToLeft: Bool = false, doubleClick: Bool = false, until: () -> Bool) async -> Bool {
        let region = SweepRegion(xMin: xMin ?? 6, xMax: xMax ?? (window.frame.width - 6),
                                 yTop: yTop, yBottom: yBottom)
        return await sweepUntil(region: region, stepX: stepX, stepY: stepY,
                                rightToLeft: rightToLeft, doubleClick: doubleClick,
                                maxClicks: maxClicks, until: until)
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

    /// A readiness wait for an isolated component — the same layout-settle as `settle()`; the
    /// sweeps do their own patient polling, so this only needs to let first layout land.
    func settleShort() async { await awaitReady() }

    /// Poll a condition until true or a hard deadline (no wall-clock assertion; correctness
    /// only). Returns whether it became true.
    @discardableResult
    func poll(timeout: Duration = .seconds(4), until condition: () -> Bool) async -> Bool {
        await awaitCondition(timeout, until: condition)
    }
}
