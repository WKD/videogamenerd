import SwiftUI

/// The manual "Find on HowLongToBeat…" sheet (PLAN §5.3, D5) — modelled on the Link-to-IGDB
/// sheet. Header = the library game (title, year, "In your library: …"); an editable search
/// field prefilled with the D3-cleaned title (search fires on Return or after an 800 ms
/// pause, ≥ 3 chars); a results list with the D2 platform emphasis and two link actions;
/// a visible per-session request counter. Pure presentation — the model does the work.
struct HLTBFindSheet: View {
    @Bindable var model: HLTBFindModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField

            if model.isLinked {
                HStack(spacing: 8) {
                    Label("Linked to HowLongToBeat", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Unlink") { model.unlink() }
                        .accessibilityIdentifier("hltb.find.unlink")
                }
            }

            content

            HStack {
                Text(model.requestCountLabel)
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityIdentifier("hltb.find.requestCount")
                Spacer()
                Button("Done") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("hltb.find.done")
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 300)
        .accessibilityIdentifier("hltb.find")
        .task { model.start(); searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.sheetTitle).font(.headline)
            Text(model.year.map { "\(model.title) · \($0)" } ?? model.title)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if !model.librarySlugs.isEmpty {
                Text("In your library: \(model.libraryPlatformLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search HowLongToBeat…", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { model.searchNow() }
                .accessibilityIdentifier("hltb.find.query")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .inert:
            message("HowLongToBeat search is off in this mode (sample / test). Link is unavailable here.")
        case .stopped:
            message(model.stopMessage ?? "HowLongToBeat request stopped.")
        case .idle:
            message("Type at least \(model.minChars) characters, then press Return.")
        case .searching:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, minHeight: 120)
        case .empty:
            message("No HowLongToBeat results for “\(model.query)”.")
        case .results:
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.results) { candidate in
                    HLTBFindRow(candidate: candidate, librarySlugs: Set(model.librarySlugs),
                                onLinkAndUse: { model.linkAndUse(candidate) },
                                onLinkOnly: { model.linkOnly(candidate) })
                }
                if model.reachedCap {
                    Text("Reached this session's request limit. Refine the search or try again later.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 160, maxHeight: 320)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .multilineTextAlignment(.center)
    }
}

private struct HLTBFindRow: View {
    let candidate: HLTBCandidate
    let librarySlugs: Set<String>
    var onLinkAndUse: () -> Void
    var onLinkOnly: () -> Void

    private var overlapping: Set<String> {
        Set(HLTBPlatformMap.overlapping(candidatePlatforms: candidate.platforms, librarySlugs: librarySlugs))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.name).font(.callout.weight(.medium))
                    if !overlapping.isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .help("On one of your platforms")
                    }
                }
                if let y = candidate.releaseYear {
                    Text(String(y)).font(.caption).foregroundStyle(.secondary)
                }
                if !candidate.platforms.isEmpty {
                    Text(candidate.platforms.prefix(6).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if !timesLine.isEmpty {
                    Text(timesLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let url = HowLongToBeatLink.gameURL(id: candidate.id) {
                    Link("Open on HowLongToBeat", destination: url).font(.caption2)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Link & Use") { onLinkAndUse() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hltb.find.linkAndUse.\(candidate.id)")
                Button("Link Only") { onLinkOnly() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("hltb.find.linkOnly.\(candidate.id)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var timesLine: String { candidate.timesLine }
}
