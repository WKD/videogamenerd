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
    /// The chosen member (index into ``members``) to receive the placeholder's play data.
    var playDataTargetIndex: Int = 0

    var onConfirm: (BundleExpansionModel) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(gameID: Int64, bundleTitle: String, members: [CompilationMemberDraft],
         carriesPlayData: Bool) {
        self.gameID = gameID
        self.bundleTitle = bundleTitle
        self.members = members
        self.carriesPlayData = carriesPlayData
    }

    var memberCount: Int { members.count }
    var confirmTitle: String { "Expand into \(memberCount) Game\(memberCount == 1 ? "" : "s")" }
    /// The index passed to the store — nil when there is no play data to move.
    var effectiveTargetIndex: Int? { carriesPlayData ? playDataTargetIndex : nil }

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
            if model.carriesPlayData {
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

    private var memberList: some View {
        List {
            ForEach(Array(model.members.enumerated()), id: \.offset) { _, member in
                HStack(spacing: 6) {
                    Text(member.title)
                    if let year = member.year {
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
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
