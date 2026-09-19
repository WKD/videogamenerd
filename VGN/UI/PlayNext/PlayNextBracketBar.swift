import SwiftUI

/// The bracket picker on top of Play Next (PLAN §7b): segmented presets, a
/// "Custom…" budget popover, the completionist toggle, an options menu, re-roll and
/// the "Ask Claude" button — plus the one-time disclosure of what is sent.
struct PlayNextBracketBar: View {
    @Bindable var model: PlayNextModel
    @State private var showCustom = false

    /// A discrete choice for the segmented picker: one of the five "By Length"
    /// shelves, or custom.
    private enum Choice: Hashable {
        case shelf(LengthShelf)
        case custom
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { model.usesCustom ? .custom : .shelf(model.bracketShelf) },
            set: { newValue in
                switch newValue {
                case let .shelf(shelf): model.selectShelf(shelf)
                case .custom: showCustom = true
                }
            })
    }

    /// The always-visible caption under the control: the selected bracket's name +
    /// current hour range so the owner sees the numbers without hovering. For a shelf
    /// it also states the pace the range derives from.
    private var selectedCaption: String {
        if model.usesCustom {
            return "Custom · \(model.bracket.rangeText)"
        }
        let shelf = model.bracketShelf
        return "\(shelf.name) · \(model.bracket.rangeText) at \(LengthShelf.formatHours(model.pace.hoursPerWeek)) h a week"
    }

    /// The picker-level hover tooltip (SwiftUI's segmented picker can't host reliable
    /// per-segment tooltips — the caption is the primary display).
    private var pickerTooltip: String {
        model.usesCustom
            ? "Custom budget — \(model.bracket.rangeText)"
            : "\(model.bracketShelf.name) — \(model.bracket.rangeText) at \(LengthShelf.formatHours(model.pace.hoursPerWeek)) h a week. Same shelves as the sidebar’s By Length."
    }

    private var candidateCount: Int { model.result?.shortlist.count ?? 0 }

    /// How much room the bar has. `ViewThatFits` picks the first density that fits, so
    /// a narrow window drops the button labels (then the segmented picker) in one
    /// deterministic step instead of the whole row fighting for space and wiggling.
    enum Density: CaseIterable { case full, iconButtons, compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                row(.full)
                row(.iconButtons)
                row(.compact)
            }

            Text(selectedCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.playNextBracketRange)

            if !model.hasShownAskDisclosure {
                Label("Ask Claude sends your tier list and these \(candidateCount) candidates — nothing else.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func row(_ density: Density) -> some View {
        HStack(spacing: density == .full ? 12 : 8) {
            bracketPicker(density)

            Toggle(density == .full ? "Plan for 100%" : "100%", isOn: Binding(
                get: { model.completionistOn },
                set: { model.setCompletionist($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
                .disabled(model.completionistForced)
                .appKitTooltip(model.completionistForced
                    ? "You already play as a completionist — lengths already estimate to 100%."
                    : "Plan for 100% — estimate this session to full completion instead of your usual play style.")

            optionsMenu(iconOnly: density != .full)

            Spacer(minLength: 8)

            if model.isRecomputing {
                ProgressView().controlSize(.small)
            }

            Button {
                model.reroll()
            } label: {
                barLabel("Re-roll", systemImage: "dice", iconOnly: density != .full)
            }
            .fixedSize()
            .accessibilityIdentifier(A11yID.playNextReroll)
            .appKitTooltip("Re-roll among near-ties (R)")

            Button {
                model.askClaude()
            } label: {
                barLabel("Ask Claude", systemImage: "sparkles", iconOnly: density != .full)
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(candidateCount == 0)
            .accessibilityIdentifier(A11yID.playNextAskClaude)
            .appKitTooltip("Ask Claude — sends only your tier list and this shortlist, nothing else")
        }
    }

    @ViewBuilder
    private func barLabel(_ title: String, systemImage: String, iconOnly: Bool) -> some View {
        if iconOnly {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private func bracketPicker(_ density: Density) -> some View {
        let picker = Picker("Time I have", selection: choice) {
            ForEach(LengthShelf.allCases) { shelf in
                Text(shelf.name).tag(Choice.shelf(shelf))
            }
            Text("Custom…").tag(Choice.custom)
        }
        .labelsHidden()
        .fixedSize()
        .appKitTooltip(pickerTooltip)
        .popover(isPresented: $showCustom, arrowEdge: .bottom) {
            CustomBudgetPopover(model: model)
        }
        if density == .compact {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private func optionsMenu(iconOnly: Bool) -> some View {
        Menu {
            Toggle("Include abandoned", isOn: Binding(
                get: { model.includeAbandoned },
                set: { model.setIncludeAbandoned($0) }))
            Toggle("Include played (no status)", isOn: Binding(
                get: { model.includePlayedWithoutStatus },
                set: { model.setIncludePlayedWithoutStatus($0) }))
            Divider()
            Toggle("Prefer expiring PS Plus games", isOn: Binding(
                get: { model.preferExpiringSubscription },
                set: { model.setPreferExpiringSubscription($0) }))
        } label: {
            barLabel("Options", systemImage: "slider.horizontal.3", iconOnly: iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .appKitTooltip("Options — which played games may be suggested")
    }
}

/// The precise-mode popover: hours per week × weeks → a budget (PLAN §7b).
struct CustomBudgetPopover: View {
    @Bindable var model: PlayNextModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom budget").font(.headline)

            Stepper(value: Binding(get: { model.customHoursPerWeek },
                                   set: { model.setCustomHoursPerWeek($0) }),
                    in: 0.5...80, step: 0.5) {
                LabeledContent("Hours per week", value: trimmed(model.customHoursPerWeek))
            }
            Stepper(value: Binding(get: { model.customWeeks },
                                   set: { model.setCustomWeeks($0) }),
                    in: 0.5...52, step: 0.5) {
                LabeledContent("Weeks", value: trimmed(model.customWeeks))
            }

            Divider()
            HStack {
                Text("Budget").foregroundStyle(.secondary)
                Spacer()
                Text("≈ \(Int((model.customHoursPerWeek * model.customWeeks).rounded())) h")
                    .fontWeight(.semibold)
            }
            .font(.callout)
        }
        .padding()
        .frame(width: 280)
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
