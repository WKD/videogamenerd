import SwiftUI

/// Routes the three ranking sidebar destinations (PLAN §7) to their screens:
/// `.duel` → the Duel screen (with a Duel | Triage mode switch), `.tierBoard` →
/// ``TierBoardView``, `.theTop` → ``TheTopView``.
///
/// Reads its dependencies from `\.rankingEnvironment`; when the container hasn't
/// injected them yet it renders a clear "ranking unavailable" state. Keeps the
/// old type name available as ``RankingPlaceholderView`` so `RootView` compiles
/// unchanged.
struct RankingDestinationView: View {
    let selection: SidebarSelection
    @Environment(\.rankingEnvironment) private var env

    var body: some View {
        if let env {
            switch selection {
            case .duel:
                DuelDestinationView(env: env)
            case .tierBoard:
                TierBoardView(env: env)
            case .theTop:
                TheTopView(env: env)
            default:
                unavailable("Not a ranking view")
            }
        } else {
            unavailable("Ranking is unavailable")
        }
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label(SidebarView.title(for: selection), systemImage: SidebarView.icon(for: selection))
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Kept so `RootView`'s `RankingPlaceholderView(selection:)` compiles unchanged.
typealias RankingPlaceholderView = RankingDestinationView

// MARK: - Duel destination (Duel | Triage switch + disputes sheet)

/// Hosts the Duel and Triage screens behind a mode switch, owning both models so
/// switching tabs (or opening the disputes sheet) keeps their state.
private struct DuelDestinationView: View {
    let env: RankingEnvironment

    enum Mode: String, CaseIterable, Identifiable { case duel = "Duel", triage = "Triage"; var id: String { rawValue } }

    @State private var mode: Mode = .duel
    @State private var duelModel: DuelModel
    @State private var triageModel: TriageModel
    @State private var showDisputes = false

    init(env: RankingEnvironment) {
        self.env = env
        _duelModel = State(initialValue: DuelModel(backend: env.backend))
        _triageModel = State(initialValue: TriageModel(backend: env.backend))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.vertical, 8)

            Divider()

            switch mode {
            case .duel:
                DuelView(model: duelModel, loader: env.coverLoader,
                         onOpenDisputes: { showDisputes = true },
                         onGoToTriage: { mode = .triage })
            case .triage:
                TriageView(model: triageModel, loader: env.coverLoader,
                           onStartDuels: { mode = .duel })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showDisputes) {
            DisputesSheet(
                disputes: duelModel.disputes,
                titles: duelModel.disputeTitles,
                onSettle: { dispute in Task { await duelModel.settle(dispute) } },
                onClose: { showDisputes = false }
            )
        }
    }
}

#if DEBUG
#Preview("Ranking — unavailable") {
    RankingDestinationView(selection: .duel)
        .frame(width: 700, height: 480)
}
#endif
