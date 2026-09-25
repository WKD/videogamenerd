import SwiftUI

/// The bulk "Fetch Missing Time Estimates…" sheet (PLAN §5.3): live progress + Cancel
/// while running; a summary and the ambiguous list to resolve one-by-one when done or
/// stopped. Pure presentation — the model does the work; buttons only call it.
struct HLTBBulkSheet: View {
    @Bindable var model: HLTBBulkFetchModel
    let presenter: HLTBFetchPresenter
    var onClose: () -> Void

    @State private var pickFor: HLTBAmbiguousGame?
    @State private var confirmClearLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.sheetTitle).font(.title3.bold())

            if model.needsConfirmation {
                confirmBody
            } else if model.isRunning {
                runningBody
            } else {
                summaryBody
            }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: 240)
        .accessibilityIdentifier("hltb.bulk")
        .task(id: model.phase) { await presenter.reloadRejectLogCount() }
        .alert("Clear the rejected-response log?", isPresented: $confirmClearLog) {
            Button("Clear", role: .destructive) { Task { await presenter.clearRejectLog() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the \(presenter.rejectLogCount) HowLongToBeat response(s) VGN kept as evidence of a stop. "
                 + "Older ones may contain your sign-in token. Your games and cached times are not touched.")
        }
        .sheet(item: $pickFor) { game in
            HLTBPickerSheet(
                title: game.title, year: game.year, candidates: game.candidates,
                librarySlugs: game.librarySlugs,
                onPick: { candidate in
                    model.pick(gameID: game.gameID, candidate: candidate)
                    pickFor = nil
                },
                onCancel: { pickFor = nil })
        }
    }

    // MARK: Confirm (replace mode only)

    private var confirmBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.confirmationMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                clearLogButton
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("hltb.bulk.cancelConfirm")
                Button("Replace") { model.confirmAndRun() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("hltb.bulk.confirmReplace")
            }
        }
    }

    // MARK: Running

    private var runningBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
            Text("\(model.completed) of \(model.total)")
                .font(.callout).monospacedDigit()
            if !model.currentTitle.isEmpty {
                Text(model.currentTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("hltb.bulk.cancel")
            }
        }
    }

    // MARK: Summary

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.summaryLine).font(.callout.weight(.medium)).monospacedDigit()
                .lineLimit(3)
            if let note = model.mainStoryNote {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let note = model.stoppedNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            if !model.ambiguous.isEmpty {
                Text("Needs your pick — HowLongToBeat has plausible entries:").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.ambiguous) { game in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(game.title).font(.callout)
                                    Text(subtitle(for: game))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Skip") { model.skip(gameID: game.gameID) }
                                    .buttonStyle(.borderless)
                                Button("Find…") { presenter.findOne(gameID: game.gameID) }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("hltb.bulk.find.\(game.gameID)")
                                Button("Choose…") { pickFor = game }
                                    .accessibilityIdentifier("hltb.bulk.choose.\(game.gameID)")
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack {
                clearLogButton
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("hltb.bulk.done")
            }
        }
    }

    /// "Clear rejected-response log (N)" — only when HowLongToBeat has rows in the log;
    /// asks for confirmation first (wave 21 E).
    @ViewBuilder private var clearLogButton: some View {
        if presenter.rejectLogCount > 0 {
            Button("Clear rejected-response log (\(presenter.rejectLogCount))") { confirmClearLog = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("hltb.bulk.clearRejectLog")
        }
    }

    /// "3 candidates · on PS4, PS5" — my platforms inline so many rows resolve at a glance (D6).
    private func subtitle(for game: HLTBAmbiguousGame) -> String {
        var parts = ["\(game.candidates.count) candidates"]
        if !game.librarySlugs.isEmpty {
            parts.append("on " + game.librarySlugs.map { PlatformLabels.short($0) }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}
