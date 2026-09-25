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
            // `U` = "not actually played" (safe un-play), plus the tier letters + 0.
            // `1`/`2`/`3` rate "Holds up today?" (PLAN §7b) without advancing.
            if ch == "0" || TriageModel.holdsUpKeys[ch] != nil
                || (ch.isLetter && "sabcdfu".contains(Character(ch.lowercased()))) {
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
        .alert("Remove from library?", isPresented: removalPresented, presenting: model.removalPrompt) { _ in
            Button("Remove", role: .destructive) { Task { await model.confirmRemoval() } }
            Button("Cancel", role: .cancel) { model.cancelRemoval() }
        } message: { game in
            Text("\u{201C}\(game.title)\u{201D} isn't owned, so marking it not-played would "
                 + "leave nothing to keep it. Remove it from the library?")
        }
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { model.removalPrompt != nil }, set: { if !$0 { model.cancelRemoval() } })
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
                    .accessibilityIdentifier(A11yID.triageProgress)
                    .accessibilityValue(model.progressText)
                Spacer()
                Button {
                    model.skip()
                } label: {
                    Label("Skip", systemImage: "arrow.right.to.line")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            // Tiers = favourites, memories included (PLAN §7/§7b) — Holds Up is the "now" fact.
            RankingPhilosophyCaption(style: .triage)

            RankingCoverView(title: game.title, coverFile: game.coverFile,
                             platformID: game.platformIDs.first, loader: loader)
                .frame(width: 300, height: 400)
                .id(game.id)
                .accessibilityIdentifier(A11yID.triageCover)
                .accessibilityLabel(game.title)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: game.id)

            VStack(spacing: 6) {
                Text(game.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    if let year = game.year { Text(String(year)).foregroundStyle(.secondary) }
                    ForEach(game.platformIDs.prefix(3), id: \.self) { PlatformChip(slug: $0) }
                }
                .font(.callout)
                TriageHoldsUpRow(current: game.holdsUp) { value in
                    Task { await model.rateCurrent(value) }
                }
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
                .accessibilityIdentifier(A11yID.triageEmpty)
            Text("^[\(model.tieredCount) game](inflect: true) tiered.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(model.tiers) { tier in
                    VStack(spacing: 4) {
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 28, label: tier.label)
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
                Text(TriageView.legendText)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
    }
}

extension TriageView {
    /// The key legend under the tier chips (PLAN §7 + §7b).
    static let legendText = "Press a letter to tier · 1 Holds Up · 2 Of Its Time · 3 Too Archaic "
        + "· 0 / space to skip · U not played · ← back"
}

/// The "Holds up today?" chips on the Triage card — the current mark highlighted, a click (or
/// `1`/`2`/`3`) sets it; pressing the current one again clears it. Bounded, single line.
private struct TriageHoldsUpRow: View {
    let current: HoldsUp?
    let onPick: (HoldsUp) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(HoldsUp.allCases.enumerated()), id: \.element) { index, value in
                Button {
                    onPick(value)
                } label: {
                    Text("\(index + 1) \(value.label)")
                        .font(.caption)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .foregroundStyle(current == value ? Color.white : Color.secondary)
                        .background(Capsule().fill(current == value ? Color.accentColor : Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .appKitTooltip(value.explanation)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Holds up today?")
        .accessibilityValue(HoldsUp.label(for: current))
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
