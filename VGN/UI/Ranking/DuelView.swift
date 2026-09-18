import SwiftUI

/// The Duel screen (PLAN §7 — two big covers, `←`/`→` pick, `↓` skip, `⌘Z` undo,
/// `space` peek, progress). A thin shell over ``DuelModel``: it renders state and
/// forwards keys; all logic lives in the model.
struct DuelView: View {
    @State var model: DuelModel
    let loader: any CoverLoading
    /// Opens the Disputes sheet (owned by the dispatcher so it can present it).
    var onOpenDisputes: () -> Void = {}
    /// Switches to the Triage tab from the drained empty state.
    var onGoToTriage: () -> Void = {}

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseWinner: Int64?

    var body: some View {
        ZStack {
            content
            overlays
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { route(.left) }
        .onKeyPress(.rightArrow) { route(.right) }
        .onKeyPress(.downArrow) { route(.down) }
        .onKeyPress(.space) { route(.peek) }
        .onKeyPress(.return) { route(.accept) }
        .onKeyPress(.escape) { route(.dismiss) }
        .onKeyPress { press in
            guard press.characters.lowercased() == "z", press.modifiers.contains(.command) else {
                return .ignored
            }
            return route(.undo)
        }
        .task {
            await model.start()
            focused = true
        }
        .onDisappear { model.stop() }
        .onChange(of: model.display) { focused = true }
    }

    // MARK: Routing

    private func route(_ key: DuelKeyInput) -> KeyPress.Result {
        let intent = DuelKeyRouter.intent(for: key, showingBorderSuggestion: model.borderSuggestion != nil)
        guard intent != .ignored else { return .ignored }
        if key == .left || key == .right, let id = winnerID(for: key) { pulse(id) }
        Task { await model.handle(key) }
        return .handled
    }

    private func winnerID(for key: DuelKeyInput) -> Int64? {
        guard let display = model.display else { return nil }
        return key == .left ? display.candidate.id : display.opponent.id
    }

    private func pulse(_ id: Int64) {
        guard !reduceMotion else { return }
        pulseWinner = id
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            pulseWinner = nil
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().controlSize(.large)
        } else if let display = model.display {
            duel(display)
        } else {
            DuelEmptyStateView(model: model, onGoToTriage: onGoToTriage, onOpenDisputes: onOpenDisputes)
        }
    }

    private func duel(_ display: DuelDisplay) -> some View {
        VStack(spacing: 20) {
            header(display)
            HStack(alignment: .top, spacing: 28) {
                side(display.candidate, key: .left)
                VStack {
                    Spacer()
                    Text("vs")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                side(display.opponent, key: .right)
            }
            .frame(maxWidth: 760)
            footerHints
        }
        .padding(28)
        .id(displayKey(display))
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: displayKey(display))
        .popover(isPresented: $model.isPeeking, arrowEdge: .bottom) {
            DuelPeekView(display: display).frame(width: 420)
        }
    }

    private func displayKey(_ display: DuelDisplay) -> String {
        "\(display.prompt.kind.rawValue)-\(display.candidate.id)-\(display.opponent.id)-\(display.prompt.comparisonsMade)"
    }

    // MARK: Header (PLAN §7 — plain words + thin progress bar)

    private func header(_ display: DuelDisplay) -> some View {
        let h = DuelPresentation.header(prompt: display.prompt,
                                        candidate: display.candidate, opponent: display.opponent)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(headerAttributed(h))
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if let step = h.stepText {
                    Text(step)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // Progress ("Placing X · 3 of ~6") as one queryable element for the
            // UI smoke suite: it must advance after each answer (PLAN §7).
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11yID.duelProgress)
            .accessibilityValue([h.text, h.stepText].compactMap { $0 }.joined(separator: " "))
            if let progress = h.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                    .tint(.accentColor)
            }
            HStack(spacing: 10) {
                Label(DuelPresentation.queueText(model.queueCount), systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.disputes.isEmpty {
                    Button {
                        onOpenDisputes()
                    } label: {
                        Label("\(model.disputes.count) disputes", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .tint(.orange)
                    .help("Preference cycles to settle")
                }
            }
        }
    }

    private func headerAttributed(_ h: DuelPresentation.Header) -> AttributedString {
        // The step ("3 of ~6") is rendered separately (monospaced, secondary), so
        // drop its suffix from the title to avoid showing the count twice.
        var display = h.text
        if let step = h.stepText { display = display.replacingOccurrences(of: " · \(step)", with: "") }
        var text = AttributedString(display)
        if !h.candidateName.isEmpty, let range = text.range(of: h.candidateName) {
            text[range].font = .title3.bold()
        }
        return text
    }

    // MARK: One side

    private func side(_ side: DuelSide, key: DuelKeyInput) -> some View {
        Button {
            pulse(side.id)
            Task { await model.handle(key) }
        } label: {
            VStack(spacing: 10) {
                RankingCoverView(title: side.title, coverFile: side.coverFile,
                                 platformID: side.platformIDs.first, loader: loader)
                    .frame(width: 240, height: 320)
                    .scaleEffect(pulseWinner == side.id ? 1.03 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pulseWinner)
                VStack(spacing: 4) {
                    Text(side.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let year = side.year {
                            Text(String(year)).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(side.platformIDs.prefix(3), id: \.self) { PlatformChip(slug: $0) }
                        if let letter = side.tierLetter {
                            TierChip(letter: letter, colorHex: side.tierColorHex, size: 18)
                        }
                    }
                }
                .frame(width: 240)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(key == .left ? A11yID.duelLeft : A11yID.duelRight)
        .help(key == .left ? "Pick \(side.title)  (←)" : "Pick \(side.title)  (→)")
    }

    private var footerHints: some View {
        HStack(spacing: 18) {
            hint("←", "left") ; hint("→", "right")
            hint("↓", "skip"); hint("space", "details"); hint("⌘Z", "undo")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }

    // MARK: Overlays (toast + border card)

    @ViewBuilder
    private var overlays: some View {
        VStack {
            Spacer()
            if let toast = model.toast {
                DuelToastView(toast: toast) { Task { await model.undoFromToast() } }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.toast)

        if let suggestion = model.borderSuggestion {
            BorderSuggestionCard(
                suggestion: suggestion,
                candidate: model.display?.candidate,
                opponent: model.display?.opponent,
                tier: { model.tier($0) },
                onAccept: { Task { await model.acceptBorder() } },
                onDismiss: { Task { await model.dismissBorder() } }
            )
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.borderSuggestion)
        }
    }
}

// MARK: - Toast

private struct DuelToastView: View {
    let toast: DuelToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(toast.text).font(.callout.weight(.medium))
            Divider().frame(height: 16)
            Button("Undo", action: onUndo).buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(radius: 8, y: 2)
    }
}

// MARK: - Peek

private struct DuelPeekView: View {
    let display: DuelDisplay

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            column(display.candidate)
            Divider()
            column(display.opponent)
        }
        .padding(16)
    }

    private func column(_ side: DuelSide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side.title).font(.headline)
            if !side.genres.isEmpty {
                Text(side.genres.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let summary = side.summary, !summary.isEmpty {
                Text(summary).font(.callout).lineLimit(8)
            } else {
                Text("No summary yet.").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Duel — placement") {
    DuelView(model: DuelModel(backend: ScriptedRankingBackend.previewPlacement()),
             loader: NoopCoverLoader())
        .frame(width: 820, height: 620)
}

#Preview("Duel — refine") {
    DuelView(model: DuelModel(backend: ScriptedRankingBackend.previewRefine()),
             loader: NoopCoverLoader())
        .frame(width: 820, height: 620)
}

#Preview("Duel — border") {
    DuelView(model: DuelModel(backend: ScriptedRankingBackend.previewBorder()),
             loader: NoopCoverLoader())
        .frame(width: 820, height: 620)
}

#Preview("Duel — empty") {
    DuelView(model: DuelModel(backend: ScriptedRankingBackend.previewEmpty()),
             loader: NoopCoverLoader())
        .frame(width: 820, height: 620)
}
#endif
