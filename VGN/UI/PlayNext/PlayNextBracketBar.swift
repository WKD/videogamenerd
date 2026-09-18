import SwiftUI

/// The bracket picker on top of Play Next (PLAN §7b): segmented presets, a
/// "Custom…" budget popover, the completionist toggle, an options menu, re-roll and
/// the "Ask Claude" button — plus the one-time disclosure of what is sent.
struct PlayNextBracketBar: View {
    @Bindable var model: PlayNextModel
    @State private var showCustom = false

    /// A discrete choice for the segmented picker: one of the presets, or custom.
    private enum Choice: Hashable {
        case preset(TimeBracket.Preset)
        case custom
    }

    private var choice: Binding<Choice> {
        Binding(
            get: { model.usesCustom ? .custom : .preset(model.bracketPreset) },
            set: { newValue in
                switch newValue {
                case let .preset(preset): model.selectPreset(preset)
                case .custom: showCustom = true
                }
            })
    }

    private var candidateCount: Int { model.result?.shortlist.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Time I have", selection: choice) {
                    ForEach(TimeBracket.Preset.allCases) { preset in
                        Text(preset.label).tag(Choice.preset(preset))
                    }
                    Text("Custom…").tag(Choice.custom)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .popover(isPresented: $showCustom, arrowEdge: .bottom) {
                    CustomBudgetPopover(model: model)
                }

                Toggle("Completionist", isOn: Binding(
                    get: { model.completionist },
                    set: { model.setCompletionist($0) }))
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("Estimate to 100% instead of a normal playthrough")

                optionsMenu

                Spacer(minLength: 8)

                if model.isRecomputing {
                    ProgressView().controlSize(.small)
                }

                Button {
                    model.reroll()
                } label: {
                    Label("Re-roll", systemImage: "dice")
                }
                .help("Re-roll among near-ties (R)")

                Button {
                    model.askClaude()
                } label: {
                    Label("Ask Claude", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidateCount == 0)
                .help("Sends only your tier list and this shortlist — nothing else")
            }

            if !model.hasShownAskDisclosure {
                Label("Ask Claude sends your tier list and these \(candidateCount) candidates — nothing else.",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Include abandoned", isOn: Binding(
                get: { model.includeAbandoned },
                set: { model.setIncludeAbandoned($0) }))
            Toggle("Include played (no status)", isOn: Binding(
                get: { model.includePlayedWithoutStatus },
                set: { model.setIncludePlayedWithoutStatus($0) }))
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
