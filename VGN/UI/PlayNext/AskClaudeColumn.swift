import SwiftUI

/// The "Claude" second-opinion column that streams in beside the engine's own
/// order (PLAN §7b): a spinner with elapsed seconds while asking, Claude's ordered
/// picks with reasons/caveats when it answers (agreement with the engine
/// highlighted), and a friendly failure with a Settings link when the CLI is
/// missing or signed out.
struct AskClaudeColumn: View {
    @Bindable var model: PlayNextModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch model.secondOpinionState {
            case .idle:
                EmptyView()
            case .asking:
                asking
            case let .result(opinion):
                result(opinion)
            case let .failed(error):
                failure(error)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text("Claude").font(.headline)
            Spacer()
            Button {
                model.dismissSecondOpinion()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
    }

    // MARK: - Asking

    private var asking: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking… \(model.secondOpinionElapsed) s")
                    .foregroundStyle(.secondary)
            }
            Text("Usually 10–20 s.").font(.caption).foregroundStyle(.tertiary)
            Button("Cancel") { model.cancelSecondOpinion() }
                .controlSize(.small)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func result(_ opinion: SecondOpinion) -> some View {
        if model.secondOpinionAgreesOnHero,
           let heroID = model.result?.hero?.id,
           let title = model.suggestion(for: heroID)?.title {
            Label("Both pick \(title)", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Text("Claude's order")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(opinion.picks.enumerated()), id: \.element.gameID) { index, pick in
                pickRow(index: index, pick: pick)
            }
        }

        if let cost = opinion.metrics?.costUSD {
            Text(String(format: "Claude's take · about $%.2f", cost))
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            Text("Claude's take — non-deterministic; the engine's pick still stands.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func pickRow(index: Int, pick: SecondOpinion.Pick) -> some View {
        let title = model.suggestion(for: pick.gameID)?.title ?? "Unknown"
        let agrees = model.result?.hero?.id == pick.gameID
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
                    .background(agrees ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15),
                                in: Circle())
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            if !pick.reason.isEmpty {
                reasonText(pick.reason).font(.caption).foregroundStyle(.secondary)
            }
            if let caveat = pick.caveat {
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(agrees ? Color.green.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Failure

    private func failure(_ error: SecondOpinionError) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.message, systemImage: "exclamationmark.bubble")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The engine's pick still stands.")
                .font(.caption).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Try again") { model.askClaude() }
                    .controlSize(.small)
                if error.suggestsSettings {
                    SettingsLink { Text("Settings…") }
                        .controlSize(.small)
                }
            }
        }
    }
}
