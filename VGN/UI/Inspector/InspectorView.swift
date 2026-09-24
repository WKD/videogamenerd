import SwiftUI

/// The trailing inspector (PLAN §8, ⌘I). Single selection renders the live
/// ``GameDetail`` (kept fresh by the view model's detail observation): cover,
/// metadata, genres, platform chips, summary, owned copies, played + status,
/// tier + rank, and playtime (mine, editable, vs. IGDB averages). Multi-selection
/// offers bulk tier / played / status actions.
struct InspectorView: View {
    @Bindable var vm: LibraryViewModel

    var body: some View {
        Group {
            switch vm.selectedGameIDs.count {
            case 0:
                emptyState
            case 1:
                if let detail = vm.selectedDetail, detail.id == vm.selectedGameIDs.first {
                    SingleGameInspector(vm: vm, detail: detail)
                } else if let summary = vm.selectedGame {
                    // Detail still loading — show what the slim row already has.
                    SingleGameInspector(vm: vm, detail: GameDetail(previewFrom: summary))
                } else {
                    emptyState
                }
            default:
                multiSelection(vm.selectedGames)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier(A11yID.inspector)
    }

    // MARK: Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No selection", systemImage: "sidebar.right")
        } description: {
            Text("Select a game to see its details.")
        }
    }

    // MARK: Multi

    private func multiSelection(_ games: [GameSummary]) -> some View {
        let ids = Set(games.map(\.id))
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(games.count) games selected").font(.title3.bold())
                Text("Bulk actions apply to all selected games.")
                    .font(.callout).foregroundStyle(.secondary)

                Divider()

                TierPickerRow(tiers: vm.tiers, current: nil) { letter in
                    vm.setTier(letter, for: ids)
                }

                Divider()

                HStack {
                    Button("Mark Owned") { vm.setOwned(true, for: ids) }
                    Button("Mark Played") { vm.setPlayed(true, for: ids) }
                }

                StatusPickerRow(current: nil) { status in
                    Task { await vm.actions?.setStatus(ids: ids, status: status) }
                }

                // "Holds up today?" (PLAN §7b) — acts on the played games of the selection.
                if games.contains(where: \.played) {
                    Divider()
                    let marks = Set(games.filter(\.played).map(\.holdsUp))
                    HoldsUpInspectorRow(current: marks.count == 1 ? marks.first ?? nil : nil) { value in
                        vm.setHoldsUp(value, for: ids)
                    }
                }

                if games.count > 1 {
                    Divider()
                    Button {
                        vm.onGroupAsCompilation(ids)
                    } label: {
                        Label("Group as compilation…", systemImage: "square.stack.3d.up")
                    }
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Single-game detail

private struct SingleGameInspector: View {
    @Bindable var vm: LibraryViewModel
    let detail: GameDetail
    @Environment(\.hltbFetchPresenter) private var hltbFetch

    private var ids: Set<Int64> { [detail.id] }

    /// The header action buttons (PLAN §8): link/re-match, refresh, choose cover, and the
    /// conditional "Remove custom cover" / "Expand Bundle" repairs. Built as data so the same
    /// set renders as a horizontal row or a vertical stack (``InspectorActionsView``).
    private var headerActions: [InspectorAction] {
        var actions: [InspectorAction] = [
            InspectorAction(
                title: detail.igdbID == nil ? "Link to IGDB…" : "Change IGDB Match…",
                systemImage: "link",
                help: detail.igdbID == nil
                    ? "Match this game to an IGDB entry to fetch metadata, cover and time estimates."
                    : "Re-match this game to a different IGDB entry (wrong edition / localised title).",
                accessibilityID: "inspector.linkIGDB",
                action: { vm.requestLinkToIGDB(gameID: detail.id) }),
            InspectorAction(
                title: "Refresh metadata", systemImage: "arrow.clockwise",
                help: "Re-fetch metadata, cover and completion times from IGDB.",
                isDisabled: detail.igdbID == nil,
                action: { vm.refreshMetadata(gameID: detail.id) }),
            InspectorAction(
                title: "Choose Cover…", systemImage: "photo.stack",
                help: "Browse every cover from all providers, or pick an image file.",
                isDisabled: !vm.canChooseCover,
                action: { vm.requestChooseCover(gameID: detail.id) }),
        ]
        if detail.userEditedCover {
            actions.append(InspectorAction(
                title: "Remove custom cover", systemImage: "photo.badge.arrow.down",
                help: "Drop the hand-picked cover and fetch one from IGDB / libretro again.",
                action: { vm.removeCustomCover(gameID: detail.id) }))
        }
        // A linked game that sits on its own (not a compilation member) may be an unexpanded
        // bundle — offer to expand it (PLAN §5.1 repair). Verified against IGDB on click; a
        // no-op with a note when it is not a bundle.
        if detail.igdbID != nil, !detail.isCompilationMember {
            actions.append(InspectorAction(
                title: "Expand Bundle into Games…", systemImage: "square.stack.3d.up",
                help: "If this is a bundle/collection on IGDB, expand it into its member games.",
                action: { vm.requestExpandBundle(gameID: detail.id) }))
        }
        return actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorCover(coverFile: detail.coverFile, title: detail.title,
                               platformID: detail.platformIDs.first, loader: vm.coverLoader,
                               onDropCover: { url in vm.importCover(gameID: detail.id, from: url) })
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.title).font(.title2.bold())
                    if let year = detail.year {
                        Text(String(year)).foregroundStyle(.secondary)
                    }
                }

                if detail.igdbID == nil { unlinkedNotice }

                // The action buttons lay out as one horizontal row when they fit on a single
                // line without any label wrapping, else stack vertically — one full-width,
                // left-aligned icon+label button per line (owner 2026-09-20, narrow inspector).
                InspectorActionsView(actions: headerActions)

                if !detail.genres.isEmpty {
                    Text(detail.genres.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }

                if !detail.platformIDs.isEmpty {
                    FlowChips(slugs: detail.platformIDs)
                }

                if let summary = detail.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }

                Divider()
                playedStatusSection
                Divider()
                tierSection
                Divider()
                copiesSection
                Divider()
                playtimeSection

                originFooter

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    /// The "not linked to IGDB" notice at the top of an unlinked game's inspector
    /// (PLAN §5.1) — no metadata / time estimates / recommendations, with a "Link…"
    /// affordance. The button action opens the sheet (never a state write in `body`).
    private var unlinkedNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "link.badge.plus").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not linked to IGDB").font(.callout.weight(.medium))
                Text("No metadata, time estimates or recommendations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Link…") { vm.requestLinkToIGDB(gameID: detail.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("inspector.linkNotice")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    /// A single, quiet line recording when and how the game entered the library
    /// (owner request — debugging, not prominent): "Added 19 Sep 2026 · via GOG".
    @ViewBuilder
    private var originFooter: some View {
        let added = detail.addedAt.formatted(date: .abbreviated, time: .omitted)
        if let origin = detail.origin {
            Text("Added \(added) · via \(origin.label)")
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            Text("Added \(added)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Played + status

    private var playedStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Owned", isOn: Binding(
                get: { detail.owned },
                set: { vm.setOwned($0, for: ids) }
            ))
            Toggle("Played", isOn: Binding(
                get: { detail.played },
                set: { vm.setPlayed($0, for: ids) }
            ))
            .accessibilityIdentifier(A11yID.inspectorPlayedToggle)
            if detail.played {
                StatusPickerRow(current: detail.status) { status in
                    Task { await vm.actions?.setStatus(ids: ids, status: status) }
                }
                if let last = detail.lastPlayedAt {
                    Text("Last played \(Self.playedDateFormatter.string(from: last))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "12 Mar 2021" for the importer-filled last-played date (PLAN §13.3).
    private static let playedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    // MARK: Tier + rank

    private var tierSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TierPickerRow(tiers: vm.tiers, current: detail.tierLetter,
                          score: vm.selectedScoreLine?.score,
                          isRankable: detail.played) { letter in
                vm.setTier(letter, for: ids)
            }
            .accessibilityIdentifier(A11yID.inspectorTierChip)
            .accessibilityValue(detail.tierLetter ?? "Unranked")
            scoreLineView
            // "Holds up today?" (PLAN §7b) — under the tier, played games only.
            if detail.played {
                HoldsUpInspectorRow(current: detail.holdsUp, firstPlayedAt: detail.firstPlayedAt) { value in
                    vm.setHoldsUp(value, for: ids)
                }
                .padding(.top, 6)
            }
        }
    }

    /// The derived-score line (PLAN §7): "9.6 · #4 overall · A, #2 of 14" for a
    /// placed game; "~8.5 · unplaced in A" + "Place now" for an unplaced one;
    /// a plain hint for unranked / unplayed games (nothing but the tier picker).
    @ViewBuilder
    private var scoreLineView: some View {
        if !detail.played {
            Text("Only played games can be ranked — mark it as played first.")
                .font(.caption).foregroundStyle(.secondary)
        } else if detail.tierID == nil {
            Text("Unranked — press ⇧S…⇧F to place it in a tier.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let line = vm.selectedScoreLine, line.isPlaced {
            Text(line.summary())
                .font(.callout.weight(.medium))
                .monospacedDigit()
        } else if let line = vm.selectedScoreLine {
            HStack(spacing: 8) {
                Text(line.summary())
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Button("Place now") { vm.select(.duel) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Run this game's placement duels now.")
            }
        } else {
            // Placed in a tier, score still resolving.
            Text(detail.isUnplaced ? "Placed in tier, not yet ranked (unplaced)."
                                   : "Ranked.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Copies

    private var copiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Copies").font(.headline)
                Spacer()
                Button {
                    vm.actions?.requestAddCopy(gameID: detail.id, title: detail.title,
                                               platforms: detail.platformIDs)
                } label: {
                    Label("Add copy…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.actions == nil)
            }

            if detail.copies.isEmpty {
                Text("Not owned. Press O or “Add copy…” to add one.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(detail.copies) { copy in
                    copyRow(copy)
                }
            }
        }
    }

    @ViewBuilder
    private func copyRow(_ copy: GameDetail.Copy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copyPrimaryLine(copy)).font(.callout)
                    if let sub = copy.subscription {
                        // PLAN §13.3: a subscription copy (PS Plus) leaves with the membership.
                        // The shared PS Plus badge asset in place of a system "+" (wave 17).
                        Label {
                            Text("\(sub.label) — expires with the subscription")
                        } icon: {
                            PSPlusBadgeView(size: 13, shadow: false)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if copy.isCompilation {
                        // PLAN §8: "Part of *Metal Gear Solid: The Legacy Collection* (PS3) · n games".
                        (Text("Part of ")
                         + Text(copy.title ?? "a compilation").italic()
                         + Text(" (\(PlatformLabels.short(copy.platformID))) · ^[\(copy.memberCount) game](inflect: true)"))
                            .font(.caption).foregroundStyle(.secondary)
                        // PLAN §13.3 / D2: PSN play time recorded for the whole collection (not split
                        // per member). Nothing when there is no such record.
                        if let seconds = copy.collectionPlaytimeS {
                            CompilationCollectionPlaytimeLabel(seconds: seconds)
                        }
                    }
                }
                Spacer()
                Button {
                    vm.actions?.removeCopy(productID: copy.productID, gameTitle: detail.title)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(copy.isCompilation ? "Remove the whole compilation" : "Remove this copy")
                .disabled(vm.actions == nil)
            }

            if copy.isCompilation {
                compilationMembers(copy)
                Button {
                    vm.editCompilation(productID: copy.productID)
                } label: {
                    Label("Edit compilation…", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    /// The inline member list of a compilation copy — click a member to select it
    /// (PLAN §8). The currently-shown game is highlighted, not clickable.
    private func compilationMembers(_ copy: GameDetail.Copy) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(zip(copy.memberIDs, copy.memberTitles)), id: \.0) { id, title in
                if id == detail.id {
                    Text("• \(title)")
                        .font(.caption).fontWeight(.semibold)
                } else {
                    Button {
                        vm.selectOnly(id)
                    } label: {
                        Text("• \(title)")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func copyPrimaryLine(_ copy: GameDetail.Copy) -> String {
        var parts = [PlatformLabels.short(copy.platformID), copy.format.rawValue.capitalized]
        if let edition = copy.edition, !edition.isEmpty { parts.append(edition) }
        return parts.joined(separator: " · ")
    }

    // MARK: Playtime

    private var playtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playtime").font(.headline)
            PlaytimeEditor(detail: detail) { seconds in
                Task { await vm.actions?.setMyPlaytime(gameID: detail.id, seconds: seconds) }
            }
            // A single label-left / value-right table (owner 2026-09-20): PSN/Batocera source
            // rows and the IGDB estimates read as one thing and never wrap mid-value.
            PlaytimeEstimatesTable(
                psnSeconds: detail.psnPlaytimeS, manualWins: detail.myPlaytimeS != nil,
                mainS: detail.ttbNormallyS, completionistS: detail.ttbCompletelyS,
                rushedS: detail.ttbHastilyS,
                sourceLabel: Self.sourceLabel(detail.ttbSource), showEstimates: hasAverages,
                sourceIsHLTB: detail.ttbSource == HLTBSource.id)
            estimateWarning
            if hasAverages {
                MeVsAverageBar(bar: bar)
            } else {
                Text("Average completion times arrive with metadata.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            hltbActions
        }
    }

    /// The suspicious-estimate warning (PLAN §5.3, D3 / wave 19): a ⚠︎ with the reason on hover
    /// that points at the single "Refresh from HowLongToBeat" button below, plus "Estimate Looks
    /// Right"; once dismissed, a subdued note with "Flag again". Shown only when the raw times
    /// trip ``EstimateSanity`` and are not already from HowLongToBeat. The refresh itself lives
    /// in ``hltbActions`` (one per-game HLTB action for the whole section).
    @ViewBuilder
    private var estimateWarning: some View {
        if detail.ttbSource != HLTBSource.id,
           let reason = EstimateSanity.isSuspicious(
               rushed: detail.ttbHastilyS, main: detail.ttbNormallyS, completionist: detail.ttbCompletelyS) {
            PlaytimeEstimateWarning(
                reason: reason.sentence,
                dismissed: hltbFetch?.isEstimateDismissed(detail.id) ?? false,
                onDismissToggle: { dismissed in
                    hltbFetch?.setEstimateLooksRight(gameID: detail.id, dismissed: dismissed)
                })
        }
    }

    /// The **one** per-game HowLongToBeat action for the section (wave 19 / D6): always
    /// "Refresh from HowLongToBeat", always in this place, always the same behaviour — an
    /// explicit request that **replaces** the three completion times from HLTB (filling gaps as
    /// a special case; leaving a game HLTB doesn't know unchanged; ambiguous → the picker; one
    /// undo step; never touches the owner's own playtime). Shown for every game, including one
    /// whose times already come from HLTB (then it is a re-check). Rendered as a real bordered
    /// button — the owner couldn't tell the old link-styled text was an action. Next to it, the
    /// "Open on HowLongToBeat" link, which leaves the app, so it stays an accent-coloured link.
    /// Wrapped so the two never squeeze letter-by-letter at the 300 pt minimum width.
    @ViewBuilder
    private var hltbActions: some View {
        InspectorWrappingRow(spacing: 12) {
            if let hltbFetch {
                Button {
                    hltbFetch.refreshOne(gameID: detail.id)
                } label: {
                    Label("Refresh from HowLongToBeat", systemImage: "clock.arrow.circlepath")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hltbFetch.isFetchingOne)
                .appKitTooltip("Fetch this game from HowLongToBeat and replace its completion times.")
                .accessibilityIdentifier("inspector.refreshHLTB")

                Button {
                    hltbFetch.findOne(gameID: detail.id)
                } label: {
                    Label("Find on HowLongToBeat…", systemImage: "magnifyingglass")
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .appKitTooltip("Search HowLongToBeat by title and link this game — useful for long or edition-heavy names.")
                .accessibilityIdentifier("inspector.findHLTB")
            }
            hltbLink
        }
        if detail.hltbID != nil {
            Text("Linked to HowLongToBeat").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var bar: PlaytimeBar {
        PlaytimeBar.make(mineSeconds: detail.effectivePlaytimeS,
                         rushed: detail.ttbHastilyS, main: detail.ttbNormallyS,
                         completionist: detail.ttbCompletelyS)
    }

    private var hasAverages: Bool {
        detail.ttbHastilyS != nil || detail.ttbNormallyS != nil || detail.ttbCompletelyS != nil
    }

    /// Display the ttb source as "IGDB" / "HowLongToBeat" / "edited" (PLAN §5.3), or
    /// nil when there is no source to show.
    static func sourceLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "igdb": return "IGDB"
        case "hltb": return "HowLongToBeat"
        case "edited", "user": return "edited"
        default: return raw.capitalized
        }
    }

    /// "Open on HowLongToBeat" — the exact game page when the HLTB id is known (the
    /// fallback persists it), else a plain search link (PLAN §5.3/§6.4). No scraping.
    @ViewBuilder
    private var hltbLink: some View {
        if let url = detail.hltbID.flatMap(HowLongToBeatLink.gameURL(id:))
            ?? HowLongToBeatLink.searchURL(title: detail.title) {
            // A link, not a button: it leaves the app. Kept visibly a link — accent colour +
            // the ↗ leaving-the-app glyph — rather than grey text (owner, wave 19).
            Link(destination: url) {
                Label("Open on HowLongToBeat", systemImage: "arrow.up.forward.square")
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.callout)
            .tint(.accentColor)
        }
    }
}

// MARK: - Reusable pieces

/// One inspector header action, as data so ``InspectorActionsView`` can render the same set
/// horizontally or vertically without duplicating the button definitions (owner 2026-09-20).
struct InspectorAction: Identifiable {
    let title: String
    let systemImage: String
    let help: String
    var accessibilityID: String? = nil
    var isDisabled: Bool = false
    let action: () -> Void

    var id: String { title }
}

/// The inspector's action buttons: one horizontal row when they fit on a single line without
/// any label wrapping, else a vertical stack of full-width, left-aligned icon+label buttons
/// (PLAN §8; the narrow-inspector fix). Each label is one line; tooltips use `appKitTooltip`
/// (the reliable one for the inspector column).
struct InspectorActionsView: View {
    let actions: [InspectorAction]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(actions) { button($0, fillWidth: false) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions) { button($0, fillWidth: true) }
            }
        }
    }

    @ViewBuilder
    private func button(_ a: InspectorAction, fillWidth: Bool) -> some View {
        Button(action: a.action) {
            Label(a.title, systemImage: a.systemImage)
                .lineLimit(1)
                // Horizontal: pin the intrinsic width so ViewThatFits measures the true row
                // width (and rejects it when it doesn't fit). Vertical: let it fill the column.
                .fixedSize(horizontal: !fillWidth, vertical: true)
                .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
        }
        // A real bordered control, not link-styled secondary text — these change data, so they
        // must read as buttons at a glance (owner, wave 19). Small keeps the horizontal row
        // fitting a wide inspector; at the 300 pt minimum ViewThatFits still stacks them
        // full-width (each with its visible button shape) rather than squeeze the labels.
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(a.isDisabled)
        .appKitTooltip(a.help)
        .accessibilityIdentifierIfPresent(a.accessibilityID)
    }
}

/// Lays its content as a horizontal row when it fits, else a vertical stack — for short action
/// clusters (e.g. the HowLongToBeat actions) whose labels must never squeeze letter-by-letter.
/// Children should carry `.fixedSize()` so the horizontal candidate is measured at true width.
private struct InspectorWrappingRow<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

private extension View {
    @ViewBuilder
    func accessibilityIdentifierIfPresent(_ id: String?) -> some View {
        if let id { accessibilityIdentifier(id) } else { self }
    }
}

/// The tier picker used in both single and multi inspectors.
private struct TierPickerRow: View {
    let tiers: [TierInfo]
    let current: String?
    /// The current game's derived score, shown in the tooltip of the button for
    /// the game's *current* tier (nil for the multi-selection picker).
    var score: DerivedScoreValue? = nil
    /// False for a game that is not played: only played games carry a tier, so the
    /// chips are shown for reference (with their tooltips) but are NOT buttons — no
    /// press animation that suggests something happened.
    var isRankable: Bool = true
    let onPick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tier").font(.headline)
            HStack(spacing: 6) {
                ForEach(tiers) { tier in
                    let tip = TierChip.hoverText(letter: tier.letter, label: tier.label, labels: [:],
                                                 score: tier.letter == current ? score : nil)
                    if isRankable {
                        Button {
                            onPick(tier.letter)
                        } label: {
                            // One tooltip only, on the outermost view (the chip's own is off).
                            TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 26,
                                     showsLabelOnHover: false)
                                .opacity(current == nil || current == tier.letter ? 1 : 0.4)
                        }
                        .buttonStyle(.plain)
                        .appKitTooltip(tip)
                    } else {
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 26,
                                 showsLabelOnHover: false)
                            .opacity(0.35)
                            .appKitTooltip(tip + " — mark the game as played to rank it")
                    }
                }
                if isRankable {
                    Button {
                        onPick(nil)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .appKitTooltip("Clear tier")
                }
            }
        }
    }
}

/// A status menu (Playing / Finished / 100% / Abandoned / To Revisit, or None) with
/// inspector keyboard shortcuts (⌃⌘1…5 set a status, ⌃⌘0 clears — PLAN §12 / milestone 5).
private struct StatusPickerRow: View {
    let current: PlayStatus?
    let onPick: (PlayStatus?) -> Void

    private static let shortcuts: [PlayStatus: KeyEquivalent] = [
        .playing: "1", .finished: "2", .completed: "3", .abandoned: "4", .toRevisit: "5",
    ]

    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            Menu(current?.label ?? "None") {
                Button("None") { onPick(nil) }
                    .keyboardShortcut("0", modifiers: [.control, .command])
                Divider()
                ForEach(PlayStatus.allCases) { status in
                    Button(status.label) { onPick(status) }
                        .keyboardShortcut(Self.shortcuts[status] ?? "0", modifiers: [.control, .command])
                }
            }
            .fixedSize()
            .accessibilityIdentifier(A11yID.inspectorStatus)
            .accessibilityValue(current?.label ?? "None")
        }
    }
}

/// The editable "my playtime" field. Accepts `45h`, `45:30`, `2d`… via
/// `PlaytimeParser`; commits on return / focus loss; rejects garbage.
private struct PlaytimeEditor: View {
    let detail: GameDetail
    let onCommit: (Int?) -> Void

    @State private var text: String = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text("Mine")
            TextField("e.g. 45h, 45:30, 2d", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .foregroundStyle(invalid ? Color.red : Color.primary)
                .accessibilityIdentifier(A11yID.inspectorPlaytimeField)
                .accessibilityValue(invalid ? "Invalid" : text)
            if !text.isEmpty {
                Button {
                    text = ""
                    onCommit(nil)
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: detail.id) { text = displayText }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private var displayText: String {
        guard let s = detail.myPlaytimeS, s > 0 else { return "" }
        return PlaytimeParser.format(seconds: s)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            invalid = false
            onCommit(nil)
            return
        }
        if let seconds = PlaytimeParser.seconds(from: trimmed) {
            invalid = false
            onCommit(seconds)
        } else {
            invalid = true
        }
    }
}

/// A label-left / value-right table for the inspector's Playtime section (owner 2026-09-20):
/// PSN/Batocera source rows and the IGDB estimates, values right-aligned with monospaced
/// digits and `.lineLimit(1)` so they never wrap mid-value (a missing estimate shows "—").
/// The estimate order is Main, Completionist (what the app plans with), then Rushed (last and
/// secondary-styled).
struct PlaytimeEstimatesTable: View {
    var psnSeconds: Int?
    var manualWins: Bool
    var mainS: Int?
    var completionistS: Int?
    var rushedS: Int?
    var sourceLabel: String?
    var showEstimates: Bool
    /// The times come from HowLongToBeat (`ttb_source = 'hltb'`) — enables the wave-21
    /// Main-Story-only read rule for the Main row (``EstimateSanity/effectiveMain``).
    var sourceIsHLTB: Bool = false

    private var hasPSN: Bool { (psnSeconds ?? 0) > 0 }

    /// HLTB lists only a Main Story for this game (wave 21 D1): the Main row shows it (read
    /// from the rushed slot for rows written before the new mapping), with a tooltip; Rushed
    /// keeps showing the same value honestly.
    private var mainStoryOnly: Bool {
        EstimateSanity.isHLTBMainStoryOnly(rushed: rushedS, main: mainS, sourceIsHLTB: sourceIsHLTB)
    }
    static let mainStoryOnlyTooltip = "HowLongToBeat lists only Main Story for this game."
    static let mainStoryOnlyCaption = "Main+Extra not on HowLongToBeat — main story used."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                if let psn = psnSeconds, psn > 0 {
                    row("PSN", PlaytimeParser.format(seconds: psn), secondary: true)
                }
                if showEstimates {
                    row("Main", estimate(EstimateSanity.effectiveMain(
                            rushed: rushedS, main: mainS, sourceIsHLTB: sourceIsHLTB)),
                        tooltip: mainStoryOnly ? Self.mainStoryOnlyTooltip : nil)
                    row("Completionist", estimate(completionistS))
                    row("Rushed", estimate(rushedS), secondary: true)
                }
            }
            if hasPSN, manualWins {
                Text("Your manual time is used; PSN is kept for reference.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            if showEstimates, let sourceLabel {
                Text("Source: \(sourceLabel)").font(.caption2).foregroundStyle(.tertiary)
            }
            if showEstimates, mainStoryOnly {
                Text(Self.mainStoryOnlyCaption)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .accessibilityIdentifier("inspector.hltb.mainStoryOnly")
            }
        }
    }

    private func estimate(_ s: Int?) -> String {
        s.map { PlaytimeParser.formatApprox(seconds: $0) } ?? "—"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, secondary: Bool = false,
                     tooltip: String? = nil) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(secondary ? Color.secondary : Color.primary)
                .appKitTooltip(tooltip ?? "")
        }
        .font(.caption)
        .opacity(secondary ? 0.85 : 1)
    }
}

/// The suspicious-estimate warning row (PLAN §5.3, D3 / wave 19): a small ⚠︎ carrying the reason
/// as a tooltip and a line that points at the section's single "Refresh from HowLongToBeat"
/// button, plus "Estimate Looks Right" (dismiss). Once dismissed, the same place shows a subdued
/// note and "Flag again". No longer carries its own refresh button — there is one HLTB action per
/// game (in ``SingleGameInspector/hltbActions``). Its buttons are real bordered controls, not
/// link-styled text (owner, wave 19). Wrapped so the labels never squeeze at the 300 pt minimum
/// inspector width (they stack instead). Never a `Menu` (a synthetic click must not open one).
struct PlaytimeEstimateWarning: View {
    let reason: String
    let dismissed: Bool
    let onDismissToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorWrappingRow(spacing: 10) {
                if dismissed {
                    Label("Estimate marked OK", systemImage: "checkmark.seal")
                        .lineLimit(1).fixedSize()
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Flag again") { onDismissToggle(false) }
                        .buttonStyle(.bordered).controlSize(.small).fixedSize()
                        .accessibilityIdentifier("inspector.estimate.flagAgain")
                } else {
                    Label("Suspicious estimate", systemImage: "exclamationmark.triangle.fill")
                        .lineLimit(1).fixedSize()
                        .font(.caption).foregroundStyle(.orange)
                        .appKitTooltip(reason)
                        .accessibilityLabel("Suspicious estimate: \(reason)")
                    Button("Estimate Looks Right") { onDismissToggle(true) }
                        .buttonStyle(.bordered).controlSize(.small).fixedSize()
                        .accessibilityIdentifier("inspector.estimate.looksRight")
                }
            }
            if !dismissed {
                Text("Refresh from HowLongToBeat below, or mark it as right.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The one-line "me vs. average" summary shown under the bar (owner 2026-09-20): "You 84 h 49 ·
/// 141 % of completionist", the comparison emphasised in orange only when my time is beyond
/// every estimate. One line, scaled down before it would wrap.
struct PlaytimeComparisonLabel: View {
    let bar: PlaytimeBar

    var body: some View {
        if let c = bar.comparisonSummary() {
            (Text(c.mineText)
             + Text(" · ")
             + Text(c.comparison).foregroundStyle(c.beyond ? Color.orange : Color.secondary))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityLabel("\(c.mineText), \(c.comparison)\(c.beyond ? ", beyond every estimate" : "")")
        }
    }
}

/// The "75 h on the whole collection (PSN)" caption under a compilation copy's "Part of …" line
/// (PLAN §13.3 / D2): PSN play time recorded for the whole collection, not split per member. Uses
/// the same duration formatting as the Playtime section; one line, scales down before it wraps so
/// it survives the inspector's 300 pt minimum width. Extracted so `InspectorLayoutTests` can host it.
struct CompilationCollectionPlaytimeLabel: View {
    let seconds: Int
    var body: some View {
        Text("\(PlaytimeParser.format(seconds: seconds)) on the whole collection (PSN)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// The "me vs. average" bar (PLAN §6.4): my playtime as a fill, with the IGDB rushed / main /
/// completionist averages as tick markers on the same scale — each tick carrying its label on
/// hover (`appKitTooltip`), with a single one-line summary underneath. Geometry is the pure
/// ``PlaytimeBar``; this only draws it.
struct MeVsAverageBar: View {
    let bar: PlaytimeBar

    private let height: CGFloat = 12

    var body: some View {
        if bar.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: height)
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(bar.mineSeconds == nil ? 0 : 3, width * bar.fillFraction),
                                   height: height)
                        // Average markers, each with a wider transparent hover target carrying
                        // its "Main ≈ 39 h" tooltip so the labels stay discoverable.
                        ForEach(bar.markers) { marker in
                            Rectangle().fill(.primary.opacity(0.55))
                                .frame(width: 2, height: height + 6)
                                .frame(width: 14)
                                .contentShape(Rectangle())
                                .appKitTooltip("\(marker.label) \(PlaytimeParser.formatApprox(seconds: marker.seconds))")
                                .offset(x: min(width - 14, max(0, width * marker.fraction - 7)))
                        }
                    }
                }
                .frame(height: height + 6)

                PlaytimeComparisonLabel(bar: bar)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let mine = bar.mineSeconds { parts.append("Your playtime \(PlaytimeParser.format(seconds: mine))") }
        for marker in bar.markers {
            parts.append("\(marker.label) average \(PlaytimeParser.formatApprox(seconds: marker.seconds))")
        }
        if bar.exceedsCompletionist { parts.append("beyond the completionist estimate") }
        return parts.joined(separator: ", ")
    }
}

/// The inspector's large cover, loaded through the cover seam with a placeholder
/// fallback.
private struct InspectorCover: View {
    let coverFile: String?
    let title: String
    let platformID: String?
    let loader: any CoverLoading
    var onDropCover: (URL) -> Void = { _ in }
    @State private var image: CGImage?
    @State private var isDropTargeted = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                PlaceholderCover(title: title, platformID: platformID)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL }) else { return false }
            onDropCover(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .task(id: "\(coverFile ?? "")") {
            guard let coverFile else { image = nil; return }
            let px = CGSize(width: 240 * displayScale, height: 320 * displayScale)
            let loaded = await loader.thumbnail(for: coverFile, pixelSize: px)
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// A simple wrapping row of platform chips.
private struct FlowChips: View {
    let slugs: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(slugs, id: \.self) { PlatformChip(slug: $0) }
        }
    }
}

#if DEBUG
#Preview("Inspector — single") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    InspectorView(vm: vm)
        .task { vm.start(); vm.selectOnly(1) }
        .frame(width: 300, height: 640)
}

#Preview("Inspector — empty") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    InspectorView(vm: vm)
        .task { vm.start() }
        .frame(width: 300, height: 640)
}

#Preview("Inspector — multi") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    InspectorView(vm: vm)
        .task { vm.start(); vm.selectedGameIDs = [1, 2, 3] }
        .frame(width: 300, height: 640)
}

#Preview("Me-vs-average bar") {
    VStack(alignment: .leading, spacing: 24) {
        MeVsAverageBar(bar: .make(mineSeconds: 40 * 3600, rushed: 27 * 3600,
                                  main: 32 * 3600, completionist: 61 * 3600))
        MeVsAverageBar(bar: .make(mineSeconds: 120 * 3600, rushed: 27 * 3600,
                                  main: 32 * 3600, completionist: 61 * 3600))
        MeVsAverageBar(bar: .make(mineSeconds: nil, rushed: 27 * 3600,
                                  main: 32 * 3600, completionist: 61 * 3600))
    }
    .padding(24)
    .frame(width: 300)
}
#endif
