import SwiftUI
import Observation

/// The confirm step for expanding a placeholder game into a compilation of an IGDB
/// bundle's member games (PLAN §5.1). Shown after a bundle is chosen in the link sheet
/// (reconcile) or via "Expand Bundle into Games…" (repair). Lists the members, and — when
/// the placeholder carries play data that must not be dropped — offers a member to move it
/// onto. `@MainActor @Observable`; the presenter performs the store write.
@MainActor
@Observable
final class BundleExpansionModel: Identifiable {
    nonisolated var id: Int64 { gameID }
    let gameID: Int64
    /// The bundle's title (the compilation Product's name).
    let bundleTitle: String
    /// The member games to create/link, in order.
    let members: [CompilationMemberDraft]
    /// True when the placeholder carries play data (played / tier / rank / status / playtime
    /// / dates / hand-edits) that the expansion must move to a member.
    let carriesPlayData: Bool
    /// The placeholder was played — the sheet shows the per-member played ticks (D4c).
    let isPlayed: Bool
    /// The placeholder carries a tier/rank — the sheet shows the tier/rank target picker (D4c).
    let isRanked: Bool
    /// The chosen member (index into ``members``) to receive the placeholder's tier/rank when it is
    /// not routed to a single played member.
    var playDataTargetIndex: Int = 0
    /// The members the owner ticked as played (D4c — "Which did you play?", default none).
    var playedIndices: Set<Int> = []

    var onConfirm: (BundleExpansionModel) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(gameID: Int64, bundleTitle: String, members: [CompilationMemberDraft],
         carriesPlayData: Bool, isPlayed: Bool = false, isRanked: Bool = false) {
        self.gameID = gameID
        self.bundleTitle = bundleTitle
        self.members = members
        self.carriesPlayData = carriesPlayData
        self.isPlayed = isPlayed
        self.isRanked = isRanked
    }

    var memberCount: Int { members.count }
    var confirmTitle: String { "Expand into \(memberCount) Game\(memberCount == 1 ? "" : "s")" }
    var playedCount: Int { playedIndices.count }
    /// The single ticked member, when exactly one is ticked (the exactly-one rule, D2/D4c).
    var singlePlayedIndex: Int? { playedCount == 1 ? playedIndices.first : nil }

    /// The member that inherits the placeholder's play data. The placeholder is deleted, so its play
    /// time / dates / tier / rank must land somewhere: on the single ticked member when exactly one
    /// (the exactly-one rule), else the tier/rank target picker (default the first). nil when the
    /// placeholder carries no play data.
    var effectiveTargetIndex: Int? {
        guard carriesPlayData else { return nil }
        return singlePlayedIndex ?? playDataTargetIndex
    }

    /// The members with the owner's played ticks applied (passed to the store).
    var resolvedMembers: [CompilationMemberDraft] {
        members.enumerated().map { index, member in
            var m = member; m.played = playedIndices.contains(index); return m
        }
    }

    func toggle(_ index: Int, _ on: Bool) {
        if on { playedIndices.insert(index) } else { playedIndices.remove(index) }
    }
    func playedAll() { playedIndices = Set(members.indices) }
    func playedNone() { playedIndices = [] }

    func confirm() { onConfirm(self) }
    func cancel() { onCancel() }
}

struct BundleExpansionSheet: View {
    @Bindable var model: BundleExpansionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            memberList
            if model.isRanked {
                Divider()
                playDataPicker
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                Text("Expand “\(model.bundleTitle)”").font(.headline)
            }
            Text("This bundle becomes a compilation of \(model.memberCount) games. Games you "
                 + "already have are linked, not duplicated.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var memberList: some View {
        if model.isPlayed {
            // "Which did you play?" — a played tick per member with All / None (default none),
            // exactly-one routes the play time / dates (D4c).
            HStack(spacing: 6) {
                Text("Which did you play?").font(.caption).foregroundStyle(.secondary)
                Button("All") { model.playedAll() }.controlSize(.small)
                Button("None") { model.playedNone() }.controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
        List {
            ForEach(Array(model.members.enumerated()), id: \.offset) { index, member in
                if model.isPlayed {
                    Toggle(isOn: Binding(
                        get: { model.playedIndices.contains(index) },
                        set: { model.toggle(index, $0) }
                    )) {
                        memberLabel(member)
                    }
                    .toggleStyle(.checkbox)
                } else {
                    memberLabel(member)
                }
            }
        }
        .listStyle(.inset)
    }

    private func memberLabel(_ member: CompilationMemberDraft) -> some View {
        HStack(spacing: 6) {
            Text(member.title)
            if let year = member.year {
                Text(String(year)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var playDataPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your play data stays on:").font(.caption).foregroundStyle(.secondary)
            Picker("Play data target", selection: $model.playDataTargetIndex) {
                ForEach(Array(model.members.enumerated()), id: \.offset) { index, member in
                    Text(member.title).tag(index)
                }
            }
            .labelsHidden()
            Text("The placeholder’s played status, tier, rank and playtime move to this game.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            Button(model.confirmTitle) { model.confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}
