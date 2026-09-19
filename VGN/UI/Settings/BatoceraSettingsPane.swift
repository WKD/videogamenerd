import AppKit
import SwiftUI

/// State behind Settings ▸ Batocera (PLAN §15 phase 2): the share folder, sync status,
/// "Sync Now" with progress + cancel, the auto-sync toggle, and the editable skip list.
/// `@MainActor @Observable`. All the actual work goes through a ``BatoceraBackend`` (the inert
/// one outside live), so this model is testable with no `/Volumes`, no database and no network.
@MainActor
@Observable
final class BatoceraSettingsModel {
    private let backend: any BatoceraBackend

    // Preferences, mirrored as observable state.
    private(set) var shareFolderPath: String?
    private(set) var autoSyncEnabled: Bool
    private(set) var skipList: [String]

    // Status.
    private(set) var status: BatoceraCatalogStatus = .empty
    private(set) var shareMounted = false
    private(set) var lastSyncAt: Date?
    private(set) var lastSummary: BatoceraSyncSummary?

    // Sync progress.
    private(set) var isSyncing = false
    private(set) var progress: BatoceraSyncProgress?
    var pendingError: String?

    /// New skip-list entry being typed.
    var newSkipEntry = ""

    // Seams (injectable for tests).
    /// Present an NSOpenPanel to choose the share folder; returns the picked URL or nil.
    @ObservationIgnored var chooseFolder: @MainActor () -> URL? = BatoceraSettingsModel.defaultFolderPicker
    @ObservationIgnored var now: () -> Date = { Date() }
    /// Called after a sync finishes (the container wires the review banner to this).
    @ObservationIgnored var onSyncFinished: (BatoceraSyncSummary) -> Void = { _ in }

    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(backend: any BatoceraBackend) {
        self.backend = backend
        self.shareFolderPath = BatoceraPreferences.shareFolderPath
        self.autoSyncEnabled = BatoceraPreferences.autoSyncAtLaunch
        self.skipList = BatoceraPreferences.effectiveSkipList
    }

    var shareFolderURL: URL? { shareFolderPath.map { URL(fileURLWithPath: $0) } }
    var isConfigured: Bool { shareFolderPath != nil }
    var threshold: String { "played more than 5 minutes, or favourite" }

    /// Refresh the catalogue status + mount state. Called from the pane's `.task` and after a
    /// sync. Never polls (no timer) — the idle-CPU rule (PLAN §8).
    func refresh() async {
        status = await backend.status()
        shareMounted = checkMount()
    }

    /// Whether the share looks reachable right now — a cheap on-demand `stat`, only when live
    /// and configured (never touches `/Volumes` in sample / test).
    private func checkMount() -> Bool {
        guard backend.isLive, let url = shareFolderURL else { return false }
        return (try? BatoceraShare(root: url))?.isReachable ?? false
    }

    // MARK: Share folder

    func pickShareFolder() {
        guard let url = chooseFolder() else { return }
        BatoceraPreferences.shareFolderPath = url.path
        shareFolderPath = url.path
        Task { await refresh() }
    }

    func clearShareFolder() {
        BatoceraPreferences.shareFolderPath = nil
        shareFolderPath = nil
        shareMounted = false
    }

    // MARK: Auto-sync

    func setAutoSync(_ on: Bool) {
        autoSyncEnabled = on
        BatoceraPreferences.autoSyncAtLaunch = on
    }

    // MARK: Skip list

    func addSkip() {
        let entry = newSkipEntry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !entry.isEmpty, !skipList.contains(entry) else { newSkipEntry = ""; return }
        skipList.append(entry)
        skipList.sort()
        persistSkip()
        newSkipEntry = ""
    }

    func removeSkip(_ entry: String) {
        skipList.removeAll { $0 == entry }
        persistSkip()
    }

    func resetSkip() {
        skipList = BatoceraSystems.defaultSkipList
        BatoceraPreferences.skipListOverride = nil
    }

    private func persistSkip() {
        BatoceraPreferences.skipListOverride = skipList
    }

    // MARK: Sync

    func syncNow(force: Bool = false) {
        guard !isSyncing, let root = shareFolderURL else { return }
        isSyncing = true
        pendingError = nil
        progress = nil
        let backend = self.backend
        let skip = Set(skipList.map { $0.lowercased() })
        syncTask = Task { [weak self] in
            let summary = await backend.sync(root: root, force: force, skip: skip) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
            guard let self, !Task.isCancelled else { return }
            self.isSyncing = false
            self.progress = nil
            self.lastSummary = summary
            if summary.shareUnavailable {
                self.pendingError = "Batocera share not mounted."
            } else {
                self.lastSyncAt = self.now()
            }
            await self.refresh()
            self.onSyncFinished(summary)
        }
    }

    func cancelSync() {
        syncTask?.cancel()
        isSyncing = false
        progress = nil
    }

    // MARK: - Default folder picker

    static func defaultFolderPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the Batocera share folder that contains “roms”."
        // Suggest /Volumes/share when it exists (PLAN §15).
        let suggestion = BatoceraPreferences.shareFolderURL
            ?? URL(fileURLWithPath: "/Volumes/share")
        if FileManager.default.fileExists(atPath: suggestion.path) {
            panel.directoryURL = suggestion
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Pane

/// Settings ▸ Batocera pane (PLAN §15). Placed after PlayStation; `settingsPane()`-sized.
struct BatoceraSettingsTab: View {
    @Bindable var model: BatoceraSettingsModel

    var body: some View {
        Form {
            Section {
                BatoceraSettingsPane(model: model)
            } header: {
                Text("Batocera ROM Collection")
            } footer: {
                Text("Read-only. VGN reads your Batocera share (the `gamelist.xml` files under "
                     + "`roms/`) and keeps every ROM in a separate catalogue. Only ROMs you have "
                     + "played or favourited are offered for your library — nothing is added "
                     + "without your review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task { await model.refresh() }
    }
}

struct BatoceraSettingsPane: View {
    @Bindable var model: BatoceraSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            shareRow
            statusBlock
            syncRow
            autoSyncRow
            Divider()
            skipListSection
            thresholdRow
            if let error = model.pendingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var shareRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share folder").font(.subheadline.weight(.medium))
                Text(model.shareFolderPath ?? "Not chosen")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.isConfigured {
                Button("Change…") { model.pickShareFolder() }.controlSize(.small)
                Button("Clear") { model.clearShareFolder() }.controlSize(.small)
            } else {
                Button("Choose…") { model.pickShareFolder() }
                    .controlSize(.small)
                    .accessibilityIdentifier("batocera.chooseFolder")
            }
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: model.shareMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                    .foregroundStyle(model.shareMounted ? .green : .secondary)
                Text(model.shareMounted ? "Mounted" : "Not mounted").font(.caption)
                if let last = model.lastSyncAt {
                    Text("· last sync \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(model.status.systemsCount) systems · \(model.status.totalEntries) games in the catalogue · \(model.status.candidatesWaiting) waiting to review")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var syncRow: some View {
        HStack(spacing: 10) {
            Button("Sync Now") { model.syncNow() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isConfigured || model.isSyncing)
                .accessibilityIdentifier("batocera.syncNow")
            if model.isSyncing {
                ProgressView().controlSize(.small)
                if let p = model.progress {
                    Text(progressLabel(p)).font(.caption).foregroundStyle(.secondary)
                }
                Button("Cancel") { model.cancelSync() }.controlSize(.small)
            } else if let summary = model.lastSummary, !summary.shareUnavailable {
                Text(Self.summaryLine(summary)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var autoSyncRow: some View {
        Toggle("Sync automatically at launch when the share is mounted", isOn: Binding(
            get: { model.autoSyncEnabled },
            set: { model.setAutoSync($0) }))
            .toggleStyle(.checkbox)
            .font(.subheadline)
    }

    private var skipListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Skip these systems").font(.subheadline.weight(.medium))
                Spacer()
                Button("Reset to defaults") { model.resetSkip() }.controlSize(.small)
            }
            Text("Arcade romsets and non-game systems (defaults from Batocera). Editable — remove one to include it.")
                .font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.skipList, id: \.self) { entry in
                        HStack {
                            Text(entry).font(.caption).monospaced()
                            Spacer()
                            Button {
                                model.removeSkip(entry)
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).controlSize(.small)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 1)
                    }
                }
            }
            .frame(maxHeight: 120)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                TextField("Add a system folder name", text: $model.newSkipEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addSkip() }
                Button("Add") { model.addSkip() }.controlSize(.small)
                    .disabled(model.newSkipEntry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var thresholdRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Promotion threshold: \(model.threshold).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func progressLabel(_ p: BatoceraSyncProgress) -> String {
        switch p.phase {
        case .scanning: return "Scanning systems…"
        case .reading: return "Reading \(p.system)… (\(p.completedSystems)/\(p.totalSystems))"
        case .finishing: return "Finishing…"
        }
    }

    static func summaryLine(_ s: BatoceraSyncSummary) -> String {
        if s.cancelled { return "Cancelled." }
        var parts: [String] = []
        parts.append("\(s.systemsRead) read")
        if s.entriesAdded > 0 { parts.append("\(s.entriesAdded) new") }
        if s.entriesUpdated > 0 { parts.append("\(s.entriesUpdated) updated") }
        if s.candidateCount > 0 { parts.append("\(s.candidateCount) to review") }
        if !s.failures.isEmpty { parts.append("\(s.failures.count) unreadable") }
        return parts.joined(separator: " · ")
    }
}
