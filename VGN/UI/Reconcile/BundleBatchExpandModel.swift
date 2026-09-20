import SwiftUI
import Observation

/// The **Expand All Unplayed** batch (PLAN §13.3 / §5.1 D4b): expand every bundle candidate that
/// carries no play data in one pass. Members are fetched **one game at a time** through the shared
/// IGDB client + rate limiter (behind the injected ``membersOf`` seam so tests never touch the
/// network), with cancellable progress in ``ImportMatchingProgressView``; then ONE confirmation
/// lists "Title → member, member…" with rows individually untickable and non-bundles auto-dismissed
/// and listed as "not a bundle"; confirming expands each in its own transaction but as ONE undo
/// step for the whole batch. `@MainActor @Observable`.
@MainActor
@Observable
final class BundleBatchExpandModel: Identifiable {
    nonisolated let id = UUID()

    /// One candidate's outcome after its members were fetched.
    struct Row: Identifiable {
        let gameID: Int64
        let title: String
        var members: [CompilationMemberDraft]
        /// false ⇒ IGDB has no members for it — "not a bundle", auto-dismissed (never expanded).
        var isBundle: Bool
        /// Individually untickable (only meaningful for a bundle row).
        var included: Bool
        var id: Int64 { gameID }
    }

    enum Phase: Equatable { case fetching, confirming, expanding, done }

    private(set) var phase: Phase = .fetching
    private(set) var progress: ImportProgress?
    private(set) var results: [Row] = []
    private(set) var expandedCount = 0
    /// The per-game undo records the batch produced — replayed as ONE undo step.
    private(set) var undoRecords: [BundleExpansionUndo] = []

    private let store: LibraryStore
    private let membersOf: @Sendable (BundleExpansionCandidate) async -> [CompilationMemberDraft]
    /// Fired when the batch finishes (confirm or cancel) so the presenter can register undo / banner.
    var onFinished: (BundleBatchExpandModel) -> Void = { _ in }
    /// Fired when the owner cancels or closes without expanding.
    var onClose: () -> Void = {}

    private var cancelled = false

    init(store: LibraryStore,
         membersOf: @escaping @Sendable (BundleExpansionCandidate) async -> [CompilationMemberDraft]) {
        self.store = store
        self.membersOf = membersOf
    }

    var bundleRows: [Row] { results.filter(\.isBundle) }
    var notBundleRows: [Row] { results.filter { !$0.isBundle } }
    var includedCount: Int { results.filter { $0.isBundle && $0.included }.count }
    var confirmTitle: String { "Expand \(includedCount) Bundle\(includedCount == 1 ? "" : "s")" }

    /// Fetch each candidate's members (one at a time, cancellable), auto-dismissing non-bundles, then
    /// move to the confirm step. `internal` and awaitable so a test drives it without the sheet.
    func run(_ candidates: [BundleExpansionCandidate]) async {
        phase = .fetching
        var rows: [Row] = []
        for (index, candidate) in candidates.enumerated() {
            if cancelled { break }
            progress = ImportProgress(phase: .matching, completed: index, total: candidates.count,
                                      detail: candidate.title, currentTitle: candidate.title)
            let members = await membersOf(candidate)
            if members.isEmpty {
                // Not a bundle on IGDB — dismiss for good so it leaves the list (§5.1).
                try? await store.dismissBundleCandidate(gameID: candidate.gameID)
                rows.append(Row(gameID: candidate.gameID, title: candidate.title,
                                members: [], isBundle: false, included: false))
            } else {
                rows.append(Row(gameID: candidate.gameID, title: candidate.title,
                                members: members, isBundle: true, included: true))
            }
        }
        results = rows
        if cancelled { phase = .done; onClose(); return }
        phase = .confirming
    }

    func setIncluded(_ on: Bool, gameID: Int64) {
        guard let i = results.firstIndex(where: { $0.gameID == gameID }) else { return }
        results[i].included = on
    }

    /// Expand every ticked bundle — one transaction each, collected into ONE undo step. `internal`
    /// and awaitable so a test drives it directly.
    func confirm() async {
        guard phase == .confirming else { return }
        phase = .expanding
        var undos: [BundleExpansionUndo] = []
        var count = 0
        for row in results where row.isBundle && row.included {
            do {
                let result = try await store.expandBundle(
                    gameID: row.gameID, bundleTitle: row.title, members: row.members)
                undos.append(result.undo)
                count += 1
            } catch {
                // A single game failing never aborts the batch (matches the reconcile path).
            }
        }
        undoRecords = undos
        expandedCount = count
        phase = .done
        onFinished(self)
    }

    func cancel() {
        cancelled = true
        if phase == .confirming { phase = .done; onClose() }
    }

    /// Reverse the whole batch (undo): restore each expansion's snapshot. `internal` so a test drives
    /// it directly (`UndoManager.undo()` hangs headless).
    func undoBatch() async {
        for undo in undoRecords.reversed() { try? await store.restoreBundleExpansion(undo) }
    }
}

// MARK: - Sheet

struct BundleBatchExpandSheet: View {
    @Bindable var model: BundleBatchExpandModel

    var body: some View {
        Group {
            switch model.phase {
            case .fetching, .expanding:
                ImportMatchingProgressView(
                    progress: model.progress,
                    phaseLabel: model.phase == .fetching ? "Checking IGDB for members…" : "Expanding…",
                    cancelIdentifier: "bundles.expandAll.cancel",
                    onCancel: { model.cancel() })
            case .confirming:
                confirm
            case .done:
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Expand these bundles").font(.headline)
                Text("Each becomes a compilation of its games. Untick any you want to keep as one "
                     + "game. Games already in your library are linked, not duplicated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            List {
                if !model.bundleRows.isEmpty {
                    Section {
                        ForEach(model.bundleRows) { row in bundleRow(row) }
                    }
                }
                if !model.notBundleRows.isEmpty {
                    Section("Not a bundle (removed from the list)") {
                        ForEach(model.notBundleRows) { row in
                            Text(row.title).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button(model.confirmTitle) { Task { await model.confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.includedCount == 0)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    private func bundleRow(_ row: BundleBatchExpandModel.Row) -> some View {
        Toggle(isOn: Binding(
            get: { row.included },
            set: { model.setIncluded($0, gameID: row.gameID) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).bold()
                Text(row.members.map(\.title).joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .toggleStyle(.checkbox)
    }
}
