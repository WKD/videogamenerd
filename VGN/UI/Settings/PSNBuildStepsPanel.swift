#if DEBUG
import AppKit
import SwiftUI

/// The DEBUG-only "PSN build steps" panel (PLAN §13.5): one compact row per gated live step,
/// run one at a time with the owner. Shown from Settings ▸ PlayStation (a "PSN build steps…"
/// button opens it in a sheet so the pane keeps its ``settingsPane()`` sizing). It never
/// scrolls horizontally; every run button carries an ``appKitTooltip``. All state and logic
/// live in ``PSNBuildStepsModel`` — this view only renders it and forwards taps.
struct PSNBuildStepsPanel: View {
    @Bindable var model: PSNBuildStepsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let message = model.rejectMessage {
                rejectBanner(message)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.rows) { row in
                    stepRow(row)
                    Divider()
                }
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 460)
        .task { await model.refresh() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PSN build steps").font(.headline)
                Spacer()
                if model.isRealAccount {
                    Text("REAL ACCOUNT")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("psn.buildSteps.realMarker")
                }
            }
            HStack(spacing: 10) {
                Picker("Account", selection: $model.accountLabel) {
                    Text("test").tag("test")
                    Text("real").tag("real")
                }
                .pickerStyle(.segmented).fixedSize()
                .accessibilityIdentifier("psn.buildSteps.accountPicker")
                if let online = model.onlineID {
                    Label(online, systemImage: "person.crop.circle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !model.signedIn {
                    Text("Not signed in").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.requestsText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Reject lock

    private func rejectBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "stop.circle.fill").foregroundStyle(.red).font(.callout.bold())
            if let failed = model.failedStep, let excerpt = model.row(failed)?.rejectExcerpt {
                Text(excerpt).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Acknowledge") { model.acknowledge() }
                .accessibilityIdentifier("psn.buildSteps.acknowledge")
                .appKitTooltip("Acknowledge the stop")
        }
        .padding(10)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Step row

    @ViewBuilder
    private func stepRow(_ row: PSNBuildStepsModel.StepRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                statusIcon(row.status).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.kind.title) \(row.kind.costHint)").font(.callout)
                    if let summary = row.summary {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let path = row.outcome?.devCachePath {
                        Button { revealInFinder(path) } label: {
                            Label(path, systemImage: "folder").font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                        .appKitTooltip("Reveal the cached body in Finder")
                    }
                    if let excerpt = row.rejectExcerpt, row.status == .failed, model.rejectMessage == nil {
                        Text(excerpt).font(.caption2).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = model.actionNote(for: row.kind) {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("psn.buildSteps.note.\(row.kind.rawValue)")
                    }
                }
                Spacer(minLength: 8)
                trailingButton(row)
            }
            if model.isConfirming(row.kind) {
                inlineConfirm(for: row.kind)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func trailingButton(_ row: PSNBuildStepsModel.StepRow) -> some View {
        if model.isConfirming(row.kind) {
            EmptyView()   // the inline confirm row below carries the actionable buttons
        } else if model.needsRetry(row.kind) {
            Button("Try this step again") { model.requestRetry(row.kind) }
                .controlSize(.small)
                .accessibilityIdentifier("psn.buildSteps.retry.\(row.kind.rawValue)")
                .appKitTooltip("Re-run \(row.kind.title) — one new request")
        } else {
            Button(row.kind.isFullFetch ? "Fetch" : "Probe") { model.activate(row.kind) }
                .controlSize(.small)
                .disabled(!model.isEnabled(row.kind))
                .accessibilityIdentifier("psn.buildSteps.run.\(row.kind.rawValue)")
                .appKitTooltip(row.kind.title)
        }
    }

    /// The in-panel confirmation (replaces the old `confirmationDialog`): a single confirm,
    /// stronger on the real account, with a Fetch/Try-again/Wipe default and Cancel. Because it
    /// lives inside the view, no presentation is ever requested while another is dismissing.
    @ViewBuilder
    private func inlineConfirm(for kind: PSNBuildStepKind) -> some View {
        let real = model.isRealAccount && kind.isFullFetch
        VStack(alignment: .leading, spacing: 6) {
            if real {
                Label(model.confirmTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold()).foregroundStyle(.red)
                    .accessibilityIdentifier("psn.buildSteps.confirmTitle.\(kind.rawValue)")
            }
            Text(model.confirmMessage).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.confirmButtonTitle) { model.confirmPending() }
                    .controlSize(.small).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("psn.buildSteps.confirm.\(kind.rawValue)")
                    .appKitTooltip(model.confirmButtonTitle)
                Button("Cancel", role: .cancel) { model.cancelPending() }
                    .controlSize(.small)
                    .accessibilityIdentifier("psn.buildSteps.cancelConfirm.\(kind.rawValue)")
                    .appKitTooltip("Cancel this fetch")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(real ? Color.red.opacity(0.10) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("psn.buildSteps.confirmRow.\(kind.rawValue)")
    }

    private func statusIcon(_ status: PSNBuildStepsModel.Status) -> some View {
        Group {
            switch status {
            case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.small)
            case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Wipe dev cache (this account)…", role: .destructive) { model.requestWipe() }
                    .controlSize(.small)
                    .disabled(!model.canWipe)
                    .accessibilityIdentifier("psn.buildSteps.wipe")
                Spacer()
                Button("Copy report") { copyReport() }
                    .controlSize(.small)
                    .accessibilityIdentifier("psn.buildSteps.copyReport")
            }
            if let note = model.generalActionNote {
                Label(note, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("psn.buildSteps.note.wipe")
            }
            if model.isWipeConfirming {
                wipeConfirm
            }
        }
    }

    private var wipeConfirm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.confirmMessage).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(model.confirmButtonTitle, role: .destructive) { model.confirmPending() }
                    .controlSize(.small)
                    .accessibilityIdentifier("psn.buildSteps.confirm.wipe")
                    .appKitTooltip(model.confirmButtonTitle)
                Button("Cancel", role: .cancel) { model.cancelPending() }
                    .controlSize(.small)
                    .accessibilityIdentifier("psn.buildSteps.cancelConfirm.wipe")
                    .appKitTooltip("Cancel the wipe")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("psn.buildSteps.confirmRow.wipe")
    }

    private func copyReport() {
        let text = model.reportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}
#endif
