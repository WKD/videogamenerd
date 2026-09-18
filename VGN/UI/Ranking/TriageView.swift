import SwiftUI

/// The Triage screen (PLAN §7 — one big cover, `S A B C D F` to tier, `0`/`space`
/// skip, `←` back, progress "17 of 43"). A thin shell over ``TriageModel``.
struct TriageView: View {
    @State var model: TriageModel
    let loader: any CoverLoading
    var onStartDuels: () -> Void = {}

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            content
            legend
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { Task { await model.back() }; return .handled }
        .onKeyPress(.space) { model.skip(); return .handled }
        .onKeyPress { press in
            guard let ch = press.characters.first, press.modifiers.isEmpty else { return .ignored }
            if ch == "0" || (ch.isLetter && "sabcdf".contains(Character(ch.lowercased()))) {
                Task { await model.handle(character: ch) }
                return .handled
            }
            return .ignored
        }
        .task {
            await model.start()
            focused = true
        }
        .onChange(of: model.current) { focused = true }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let game = model.current {
            card(game)
        } else {
            summary
        }
    }

    private func card(_ game: GameSummary) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    Task { await model.back() }
                } label: {
                    Label("Back", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canGoBack)
                .buttonStyle(.borderless)
                Spacer()
                Text(model.progressText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.skip()
                } label: {
                    Label("Skip", systemImage: "arrow.right.to.line")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)

            RankingCoverView(title: game.title, coverFile: game.coverFile,
                             platformID: game.platformIDs.first, loader: loader)
                .frame(width: 300, height: 400)
                .id(game.id)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: game.id)

            VStack(spacing: 6) {
                Text(game.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    if let year = game.year { Text(String(year)).foregroundStyle(.secondary) }
                    ForEach(game.platformIDs.prefix(3), id: \.self) { PlatformChip(slug: $0) }
                }
                .font(.callout)
            }

            // Preload the next cover so advancing is instant (PLAN §7 target ≈ 2 s).
            if let next = model.next {
                RankingCoverView(title: next.title, coverFile: next.coverFile,
                                 platformID: next.platformIDs.first, loader: loader)
                    .frame(width: 1, height: 1).opacity(0).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 20)
    }

    private var summary: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 42)).foregroundStyle(.green)
            Text("Triage complete").font(.title2.weight(.semibold))
            Text("^[\(model.tieredCount) game](inflect: true) tiered.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(model.tiers) { tier in
                    VStack(spacing: 4) {
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 28)
                        Text("\(model.perTierCounts[tier.id] ?? 0)")
                            .font(.headline.monospacedDigit())
                    }
                }
            }
            if model.tieredCount > 0 {
                Button {
                    onStartDuels()
                } label: {
                    Label("Start duels", systemImage: "flag.2.crossed")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: Legend (always visible while tiering)

    @ViewBuilder
    private var legend: some View {
        if !model.isDone {
            VStack(spacing: 6) {
                Divider()
                RankingTierLegend(tiers: model.tiers, highlighted: model.highlightedTier) { tier in
                    Task { await model.tierCurrent(tier.id) }
                }
                .padding(.vertical, 8)
                Text("Press a letter to tier · 0 / space to skip · ← back")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
    }
}

#if DEBUG
#Preview("Triage") {
    TriageView(model: TriageModel(backend: ScriptedRankingBackend.previewTriage()),
               loader: NoopCoverLoader())
        .frame(width: 640, height: 640)
}

#Preview("Triage — done") {
    let backend = ScriptedRankingBackend.previewTriage()
    backend.unranked = []
    return TriageView(model: TriageModel(backend: backend), loader: NoopCoverLoader())
        .frame(width: 640, height: 640)
}
#endif
