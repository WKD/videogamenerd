import SwiftUI

/// The Play Next screen (PLAN §7b), the sidebar's LIBRARY → **Play Next** entry.
/// Reads its dependencies from `\.playNextEnvironment`; before the container wires
/// them it shows a clear "unavailable" state. The orchestrator's one-line swap is
/// simply `PlayNextView()` in place of `PlayNextPlaceholderView`.
struct PlayNextView: View {
    @Environment(\.playNextEnvironment) private var env

    var body: some View {
        if let env {
            PlayNextScreen(env: env)
        } else {
            ContentUnavailableView {
                Label("Play Next", systemImage: "sparkles")
            } description: {
                Text("Play Next is unavailable.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Owns the ``PlayNextModel`` (built from the injected environment) and renders the
/// body — the seam that lets previews/tests drive `PlayNextBody` directly.
struct PlayNextScreen: View {
    let env: PlayNextEnvironment
    @State private var model: PlayNextModel

    init(env: PlayNextEnvironment) {
        self.env = env
        _model = State(initialValue: PlayNextModel(
            backend: env.backend,
            secondOpinion: env.secondOpinion,
            pace: env.paceModel?.pace ?? .default,
            bracketHint: env.bracketHint))
    }

    var body: some View {
        PlayNextBody(model: model, loader: env.coverLoader, inspect: env.inspect,
                     paceModel: env.paceModel)
    }
}

// MARK: - Body

/// The full Play Next UI over a model — the previewable, testable seam.
struct PlayNextBody: View {
    @Bindable var model: PlayNextModel
    let loader: any CoverLoading
    var inspect: (@MainActor (Int64) -> Void)?
    /// The shared pace controller; a change to its pace recomputes the picks once.
    var paceModel: PlayPaceModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rankingActions) private var rankingActions
    @Environment(\.undoManager) private var undoManager
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var shortlist: [PlayNextSuggestion] { model.result?.shortlist ?? [] }
    private var secondOpinionActive: Bool { model.secondOpinionState != .idle }

    var body: some View {
        VStack(spacing: 0) {
            PlayNextBracketBar(model: model)
            Divider()
            scroll
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.space) { inspectSelected() }
        .onKeyPress(.delete) { snoozeSelected() }
        .onKeyPress { handleCharacter($0) }
        .overlay(alignment: .bottom) { toast }
        .task { await model.start(); focused = true }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onDisappear { model.stop() }
        // A pace change (sidebar "By Length" popover / Settings) recomputes once.
        .onChange(of: paceModel?.pace) { _, newPace in
            if let newPace { model.setPace(newPace) }
        }
        .onChange(of: model.result?.hero?.id) { selectedIndex = 0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: model.result?.hero?.id)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: secondOpinionActive)
    }

    // MARK: Scroll content

    @ViewBuilder
    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.rankedCount == 0 {
                    noRankingsState
                } else if let result = model.result, result.hero == nil, shortlist.isEmpty {
                    emptyState(for: result)
                } else if let result = model.result {
                    if model.isSmallLibrary { SmallLibraryBanner(count: model.rankedCount,
                                                                 goToDuel: rankingActions.goToDuel) }
                    picksSection(result)
                    tasteModelLine
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Picks section (Engine [| Claude])

    @ViewBuilder
    private func picksSection(_ result: PlayNextResult) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                if secondOpinionActive {
                    Text("Engine").font(.headline).foregroundStyle(.secondary)
                }
                if let hero = result.hero {
                    PlayNextHeroCard(
                        suggestion: hero, sentences: model.reasonSentences(for: hero),
                        bracket: model.bracket, loader: loader,
                        isSelected: selectedIndex == 0,
                        onStart: { act { await model.startPlaying(hero) } },
                        onNot: { act { await model.notThisOne(hero) } },
                        onNever: { act { await model.never(hero) } },
                        onInspect: { inspect?(hero.id) })
                        .accessibilityIdentifier(A11yID.playNextHero)
                }
                alternatives(result)
                unknownLane(result)
                exclusionsFootnote(result.exclusions)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if secondOpinionActive {
                AskClaudeColumn(model: model)
                    .transition(reduceMotion ? .opacity
                                : .move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func alternatives(_ result: PlayNextResult) -> some View {
        if !result.alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Or one of these").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(result.alternatives.enumerated()), id: \.element.id) { index, alt in
                            PlayNextAlternativeCard(
                                suggestion: alt, sentences: model.reasonSentences(for: alt),
                                bracket: model.bracket, loader: loader,
                                isSelected: selectedIndex == index + 1,
                                claudeBadge: claudeBadge(for: alt.id),
                                onStart: { act { await model.startPlaying(alt) } },
                                onNot: { act { await model.notThisOne(alt) } },
                                onNever: { act { await model.never(alt) } },
                                onInspect: { inspect?(alt.id) })
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func unknownLane(_ result: PlayNextResult) -> some View {
        if !result.unknownLength.isEmpty {
            DisclosureGroup {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(result.unknownLength) { game in
                            PlayNextAlternativeCard(
                                suggestion: game, sentences: model.reasonSentences(for: game),
                                bracket: model.bracket, loader: loader,
                                onStart: { act { await model.startPlaying(game) } },
                                onNot: { act { await model.notThisOne(game) } },
                                onNever: { act { await model.never(game) } },
                                onInspect: { inspect?(game.id) })
                        }
                    }
                    .padding(.vertical, 4)
                }
            } label: {
                Text("Unknown length (\(result.unknownLength.count))")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func exclusionsFootnote(_ exclusions: RecommendationExclusions) -> some View {
        let parts = exclusionParts(exclusions)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func exclusionParts(_ e: RecommendationExclusions) -> [String] {
        var parts: [String] = []
        if e.byTime > 0 { parts.append("\(e.byTime) too long for this bracket") }
        if e.byStatus > 0 { parts.append("\(e.byStatus) filtered by status") }
        if e.byFeedback > 0 { parts.append("\(e.byFeedback) snoozed") }
        return parts
    }

    // MARK: Taste model line

    @ViewBuilder
    private var tasteModelLine: some View {
        if let backtest = model.backtest {
            TasteModelLine(backtest: backtest)
        }
    }

    // MARK: Empty states

    private var noRankingsState: some View {
        ContentUnavailableView {
            Label("No rankings yet", systemImage: "trophy")
        } description: {
            Text("Play Next learns from your tiers. Rank a few games first, then come back for a pick.")
        } actions: {
            if let goToDuel = rankingActions.goToDuel {
                Button("Start ranking") { goToDuel() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityIdentifier(A11yID.playNextEmpty)
    }

    @ViewBuilder
    private func emptyState(for result: PlayNextResult) -> some View {
        if result.exclusions.byTime > 0 {
            ContentUnavailableView {
                Label("Nothing fits ‘\(result.bracket.label)’", systemImage: "hourglass")
            } description: {
                Text("\(result.exclusions.byTime) owned games were too long for this bracket. Try a longer one.")
            } actions: {
                if let next = nextShelf(after: model.bracketShelf) {
                    Button("Try ‘\(next.name)’") { model.selectShelf(next) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier(A11yID.playNextEmpty)
        } else {
            ContentUnavailableView {
                Label("Nothing to play here yet", systemImage: "tray")
            } description: {
                Text("No owned, unfinished games to suggest. Add some to your library, or include abandoned games from the options menu.")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier(A11yID.playNextEmpty)
        }
    }

    private func nextShelf(after shelf: LengthShelf) -> LengthShelf? {
        let all = LengthShelf.allCases
        guard let i = all.firstIndex(of: shelf), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    // MARK: Toast

    @ViewBuilder
    private var toast: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.text).font(.callout)
                if toast.undoable, model.pendingStartUndo != nil {
                    Button("Undo") { act { await model.undoLastStartPlaying() } }
                        .buttonStyle(.borderless)
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("playnext.undoStart")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .padding(.bottom, 16)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            // Tap the text (not the Undo button) to dismiss.
            .onTapGesture { model.clearToast() }
        }
    }

    // MARK: Claude badge

    private func claudeBadge(for id: Int64) -> String? {
        guard case let .result(opinion) = model.secondOpinionState,
              let idx = opinion.picks.firstIndex(where: { $0.gameID == id }) else { return nil }
        return "Claude #\(idx + 1)"
    }

    // MARK: Keyboard

    @discardableResult
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !shortlist.isEmpty else { return .ignored }
        selectedIndex = min(max(selectedIndex + delta, 0), shortlist.count - 1)
        return .handled
    }

    private func inspectSelected() -> KeyPress.Result {
        guard let game = shortlist[safe: selectedIndex] else { return .ignored }
        inspect?(game.id)
        return .handled
    }

    private func snoozeSelected() -> KeyPress.Result {
        guard let game = shortlist[safe: selectedIndex] else { return .ignored }
        act { await model.notThisOne(game) }
        return .handled
    }

    private func handleCharacter(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command), press.characters.lowercased() == "i" {
            return inspectSelected()
        }
        switch press.characters.lowercased() {
        case "1", "2", "3", "4", "5":
            if let n = Int(press.characters) { model.selectShelf(index: n - 1) }
            return .handled
        case "r":
            model.reroll()
            return .handled
        default:
            return .ignored
        }
    }

    private func act(_ operation: @escaping () async -> Void) {
        Task { await operation() }
    }
}

// MARK: - Small pieces

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A calm banner shown under ~15 ranked games (PLAN §7b honesty).
struct SmallLibraryBanner: View {
    let count: Int
    var goToDuel: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Only \(count) games ranked — these picks lean on general acclaim.")
                    .font(.callout)
                Text("Rank more in Duel or Triage to sharpen your recommendations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let goToDuel {
                Button("Rank more") { goToDuel() }.controlSize(.small)
            }
        }
        .padding(12)
        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.25)))
    }
}

/// The "Taste model: good · based on 47 ranked games" line + honest popover.
struct TasteModelLine: View {
    let backtest: TasteBacktestResult
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(.secondary)
            Text("Taste model: \(backtest.verdict.label)").fontWeight(.medium)
            if backtest.sampleCount > 0 {
                Text("· based on \(backtest.sampleCount) ranked games").foregroundStyle(.secondary)
            }
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { infoPopover }
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this is measured").font(.headline)
            Text("""
            Play Next hides each game you've ranked, predicts its score from the others, \
            and checks how well that matches where you actually placed it (a leave-one-out \
            backtest). '\(backtest.verdict.label.capitalized)' is that agreement.
            """)
            .font(.callout)
            switch backtest.verdict {
            case .good:
                Text("Your rankings are internally consistent, so the taste signal is trusted.")
                    .font(.caption).foregroundStyle(.secondary)
            case .rough:
                Text("The signal is noisy at this size — treat the order as a starting point, not a verdict.")
                    .font(.caption).foregroundStyle(.secondary)
            case .notEnoughData:
                Text("Under 15 ranked games there isn't enough to judge — picks lean on general acclaim.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - Previews

#if DEBUG
/// Hosts `PlayNextBody` over a scripted model, optionally auto-asking Claude once
/// the first result has resolved (for the Ask Claude previews).
private struct PlayNextPreviewHost: View {
    @State var model: PlayNextModel
    var autoAsk = false
    var width: CGFloat = 900

    var body: some View {
        PlayNextBody(model: model, loader: NoopCoverLoader(), inspect: { _ in })
            .frame(width: width, height: 720)
            .task {
                guard autoAsk else { return }
                while !model.hasLoaded { try? await Task.sleep(for: .milliseconds(10)) }
                model.askClaude()
            }
    }
}

#Preview("Hero + alternatives") {
    PlayNextPreviewHost(model: PlayNextSamples.model(result: PlayNextSamples.richResult()))
}

#Preview("Small library") {
    PlayNextPreviewHost(model: PlayNextSamples.model(
        result: PlayNextSamples.richResult(),
        backtest: TasteBacktestResult(spearman: nil, sampleCount: 9, verdict: .notEnoughData),
        ranked: 9))
}

#Preview("Empty — nothing fits") {
    PlayNextPreviewHost(model: PlayNextSamples.model(
        result: PlayNextSamples.nothingFitsResult(), ranked: 30))
}

#Preview("Empty — no rankings") {
    PlayNextPreviewHost(model: PlayNextSamples.model(
        result: PlayNextSamples.emptyResult(), ranked: 0))
}

#Preview("Ask Claude — asking") {
    let stub = StubSecondOpinionProvider()
    stub.delay = 60
    stub.echoEngineOrder = true
    return PlayNextPreviewHost(
        model: PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub),
        autoAsk: true, width: 1120)
}

#Preview("Ask Claude — agreed") {
    let stub = StubSecondOpinionProvider(opinion: SecondOpinion(
        picks: [.init(gameID: 200, reason: "FromSoftware's open-world Souls — exactly your S/A wheelhouse.", caveat: "The 53 h figure is a focused run."),
                .init(gameID: 201, reason: "The closest thing to Souls in 2D."),
                .init(gameID: 203, reason: "A timeless JRPG if you want a change of pace.")],
        model: "claude", metrics: ClaudeRunMetrics(costUSD: 0.73)))
    return PlayNextPreviewHost(
        model: PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub),
        autoAsk: true, width: 1120)
}

#Preview("Ask Claude — disagreed") {
    let stub = StubSecondOpinionProvider(opinion: SecondOpinion(
        picks: [.init(gameID: 201, reason: "For a long haul I'd start here — a tighter, more focused adventure.", caveat: "Slow first few hours."),
                .init(gameID: 200, reason: "Superb, but a bigger time sink than it looks.")],
        model: "claude", metrics: ClaudeRunMetrics(costUSD: 0.61)))
    return PlayNextPreviewHost(
        model: PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub),
        autoAsk: true, width: 1120)
}

#Preview("Ask Claude — failed") {
    let stub = StubSecondOpinionProvider(error: .unavailable("Claude Code is not logged in. Run `claude` once to sign in."))
    return PlayNextPreviewHost(
        model: PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub),
        autoAsk: true, width: 1120)
}

#Preview("Unavailable") {
    PlayNextView().frame(width: 800, height: 560)
}
#endif
