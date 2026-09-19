import SwiftUI

/// The bulk "Fetch Missing Time Estimates…" sheet (PLAN §5.3): live progress + Cancel
/// while running; a summary and the ambiguous list to resolve one-by-one when done or
/// stopped. Pure presentation — the model does the work; buttons only call it.
struct HLTBBulkSheet: View {
    @Bindable var model: HLTBBulkFetchModel
    let presenter: HLTBFetchPresenter
    var onClose: () -> Void

    @State private var pickFor: HLTBAmbiguousGame?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fetch Missing Time Estimates").font(.title3.bold())

            if model.isRunning {
                runningBody
            } else {
                summaryBody
            }
        }
        .padding(22)
        .frame(minWidth: 460, minHeight: 240)
        .accessibilityIdentifier("hltb.bulk")
        .sheet(item: $pickFor) { game in
            HLTBPickerSheet(
                title: game.title, year: game.year, candidates: game.candidates,
                onPick: { candidate in
                    model.pick(gameID: game.gameID, candidate: candidate)
                    pickFor = nil
                },
                onCancel: { pickFor = nil })
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
            if let note = model.stoppedNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            if !model.ambiguous.isEmpty {
                Text("Pick a match for these:").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.ambiguous) { game in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(game.title).font(.callout)
                                    Text("\(game.candidates.count) candidates")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Skip") { model.skip(gameID: game.gameID) }
                                    .buttonStyle(.borderless)
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
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("hltb.bulk.done")
            }
        }
    }
}
