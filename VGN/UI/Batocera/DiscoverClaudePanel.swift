import SwiftUI

/// "Engine vs Claude" for the **From the vault** row (PLAN §7b): the scorer's own order on the
/// left, Claude's re-ordering (reason + optional caveat) on the right, the shared #1 highlighted.
/// A spinner with elapsed seconds + Cancel while asking; a clear message (and a Settings link
/// for a setup problem) when the CLI is missing, logged out or times out — the engine's order
/// stands. All text is line-limited (it lives in the detail column).
struct DiscoverClaudePanel: View {
    @Bindable var model: DiscoverModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            engineColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            claudeColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }

    // MARK: Engine

    private var engineColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Engine").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(model.shortlist.prefix(5).enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 6) {
                    rankBadge(index + 1, agrees: index == 0 && model.secondOpinionAgreesOnTop)
                    Text(entry.name).font(.caption).lineLimit(1)
                    Text(DiscoverSecondOpinion.systemLabel(for: entry))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    // MARK: Claude

    private var claudeColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("Claude").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.dismissSecondOpinion()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
                .accessibilityIdentifier("discover.claude.close")
            }
            switch model.secondOpinionState {
            case .idle:
                EmptyView()
            case .asking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking… \(model.secondOpinionElapsed) s")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel") { model.cancelSecondOpinion() }
                        .controlSize(.small)
                        .accessibilityIdentifier("discover.claude.cancel")
                }
            case let .result(opinion):
                if model.secondOpinionAgreesOnTop, let top = model.shortlist.first {
                    Label("Both pick \(top.name)", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green).lineLimit(1)
                }
                ForEach(Array(opinion.picks.enumerated()), id: \.element.gameID) { index, pick in
                    pickRow(index: index, pick: pick)
                }
                Text("Claude's take — non-deterministic; the engine's order still stands.")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            case let .failed(error):
                Label(error.message, systemImage: "exclamationmark.bubble")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Button("Try again") { model.askClaude() }
                        .controlSize(.small)
                        .accessibilityIdentifier("discover.claude.retry")
                    if error.suggestsSettings {
                        SettingsLink { Text("Settings…") }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func pickRow(index: Int, pick: SecondOpinion.Pick) -> some View {
        let title = model.shortlistEntry(for: pick.gameID)?.name ?? "Unknown"
        let agrees = model.shortlist.first?.id == pick.gameID
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                rankBadge(index + 1, agrees: agrees)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            }
            if !pick.reason.isEmpty {
                Text(pick.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            if let caveat = pick.caveat {
                Label(caveat, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    private func rankBadge(_ n: Int, agrees: Bool) -> some View {
        Text("\(n)")
            .font(.caption2.weight(.bold))
            .frame(width: 16, height: 16)
            .background(agrees ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), in: Circle())
    }
}
