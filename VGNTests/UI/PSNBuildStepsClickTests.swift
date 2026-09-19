#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The DEBUG build-steps panel really delivers clicks (PLAN §13.5): an enabled button
/// triggers a runner call, disabled buttons trigger none, and Acknowledge unlocks — hosted
/// headless in a ``ClickProbeWindow`` over a ``ScriptedPSNBuildRunner``. Uses the `sweep`
/// harness (proven under parallel load) and isolates a single enabled button so "exactly one
/// runner call" is unambiguous.
@MainActor
@Suite(.serialized)
struct PSNBuildStepsClickTests {

    private func clearPrefs() {
        for label in ["test", "real"] {
            for kind in PSNBuildStepKind.allCases {
                AppPreferences.defaults.removeObject(forKey: PSNBuildStepsGate.key(label: label, kind: kind))
            }
        }
        AppPreferences.defaults.removeObject(forKey: PSNAccountModel.accountLabelKey)
    }

    private func tooltips(in view: NSView, into out: inout [(String, NSRect)]) {
        if let tip = view.toolTip, !tip.isEmpty { out.append((tip, view.convert(view.bounds, to: nil))) }
        for sub in view.subviews { tooltips(in: sub, into: &out) }
    }
    private func rect(_ window: ClickProbeWindow, tooltip: String) -> NSRect? {
        var found: [(String, NSRect)] = []
        if let root = window.window.contentView { tooltips(in: root, into: &found) }
        return found.first { $0.0 == tooltip }?.1
    }

    /// Click a button (by tooltip) repeatedly until `done`. Safe for an idempotent control
    /// like Acknowledge; retries a click dropped under parallel load.
    private func clickUntil(_ window: ClickProbeWindow, tooltip: String,
                            done: () -> Bool, max: Int = 60) async throws {
        for attempt in 0..<max {
            if done() { return }
            if let r = rect(window, tooltip: tooltip) {
                window.click(at: NSPoint(x: r.midX, y: r.midY))
            }
            try await Task.sleep(for: .milliseconds(attempt < 6 ? 40 : 150))
        }
    }

    @Test(.timeLimit(.minutes(5)))
    func anEnabledButtonTriggersExactlyOneRunnerCall() async throws {
        clearPrefs(); defer { clearPrefs() }
        let runner = ScriptedPSNBuildRunner(session: true, onlineID: "test_nerd")
        // Nothing passed yet → only the profile probe (S2) is enabled, so a click on the step
        // rows can reach only that one runner call (its own guard blocks a second).
        let model = PSNBuildStepsModel(runner: runner, accountLabel: "test")
        await model.refresh()
        #expect(PSNBuildStepKind.allCases.filter { model.isEnabled($0) } == [.probeProfile])

        let window = ClickProbeWindow(PSNBuildStepsPanel(model: model),
                                      size: NSSize(width: 700, height: 560))
        defer { window.close() }
        try await window.settle()
        // Sweep from the top: the header (and its account picker — harmless here) then the
        // first step row (S2). `until` stops the sweep the moment the call lands, before the
        // Wipe footer is reached.
        let hits = try await window.sweep(band: 520, stepX: 18, stepY: 12,
                                          observe: { runner.callCount },
                                          until: { runner.callCount > 0 })
        #expect(hits >= 1, "the enabled Probe button never received a click")
        #expect(runner.calls == [.probeProfile], "one enabled button → exactly one runner call")
    }

    @Test(.timeLimit(.minutes(5)))
    func disabledButtonsTriggerNoRunnerCall() async throws {
        clearPrefs(); defer { clearPrefs() }
        let runner = ScriptedPSNBuildRunner(session: false, onlineID: nil)   // signed out
        let model = PSNBuildStepsModel(runner: runner, accountLabel: "test")
        await model.refresh()
        #expect(PSNBuildStepKind.allCases.allSatisfy { model.isEnabled($0) == false })

        let window = ClickProbeWindow(PSNBuildStepsPanel(model: model),
                                      size: NSSize(width: 700, height: 560))
        defer { window.close() }
        try await window.settle()
        // Click each disabled step button's rect a couple of times — either a click lands on
        // a disabled control (no-op) or is dropped, so the runner is never reached.
        for _ in 0..<2 {
            for kind in PSNBuildStepKind.allCases {
                if let r = rect(window, tooltip: kind.title) {
                    window.click(at: NSPoint(x: r.midX, y: r.midY))
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        #expect(runner.callCount == 0, "no disabled step button may reach the runner")
    }

    @Test(.timeLimit(.minutes(5)))
    func acknowledgeButtonUnlocksAfterAReject() async throws {
        clearPrefs(); defer { clearPrefs() }
        let runner = ScriptedPSNBuildRunner(session: true, onlineID: "test_nerd")
        runner.scriptError(PSNBuildStepsTests.FakeReject(), for: .probeProfile)
        let model = PSNBuildStepsModel(runner: runner, accountLabel: "test")
        await model.refresh()
        // Drive the reject through the model so the panel is hosted already-locked and stable.
        model.activate(.probeProfile)
        await poll(until: { model.rejectMessage != nil })
        #expect(model.failedStep == .probeProfile)

        let window = ClickProbeWindow(PSNBuildStepsPanel(model: model),
                                      size: NSSize(width: 700, height: 520))
        defer { window.close() }
        try await window.settle()
        // Acknowledge is a large, stable button in the reject banner; a precise retry-click
        // clears the lock (and keeps `failedStep` for the explicit retry).
        try await clickUntil(window, tooltip: "Acknowledge the stop",
                             done: { model.rejectMessage == nil })
        #expect(model.rejectMessage == nil, "Acknowledge must clear the lock")
        #expect(model.failedStep == .probeProfile, "Acknowledge keeps the failed step for an explicit retry")
    }
}
#endif
