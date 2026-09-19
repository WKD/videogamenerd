import SwiftUI

/// One row of the import review sheet (PLAN §14.3): the persisted staging decision
/// (`matchedGameID` / `ignored` / `platform`) merged with the transient mapping hints
/// (release year, Mac availability, Linux-only note, noise reason) and the IGDB match
/// proposal. Source-agnostic (GOG now, PSN later).
struct ImportReviewRow: Identifiable, Equatable, Sendable {
    let externalID: String
    let sourceTitle: String
    var platform: String?
    var include: Bool
    var ignored: Bool
    var matchedGameID: Int64?
    var proposedMatch: ScanMatch?
    var alternatives: [ScanMatch]
    var confidence: ScanConfidenceBucket
    var ignoreReason: ImportIgnoreReason?
    var releaseYear: Int?
    var macAvailable: Bool
    var linuxOnly: Bool

    var id: String { externalID }

    var bucket: ImportReviewBucket {
        if ignored { return .ignored }
        return matchedGameID == nil ? .new : .alreadyMatched
    }
    var isCommittable: Bool { include && !ignored }
    var matchedTitle: String? { proposedMatch?.name }
    var showsSourceTitle: Bool {
        guard let matched = proposedMatch?.name else { return true }
        return matched.caseInsensitiveCompare(sourceTitle) != .orderedSame
    }
}

/// State behind the shared import review sheet (PLAN §14.3). Merges the sync result with
/// the persisted staging decisions, re-maps platforms on the policy switch, persists
/// ignore/restore, and commits through ``ImportStagingStore/commit(_:)`` in one
/// transaction. `@MainActor @Observable`; built with fakes in tests (no network).
@MainActor
@Observable
final class ImportReviewModel {
    let source: String
    let sourceLabel: String
    private let staging: ImportStagingStore
    private let onLibraryChanged: () -> Void

    let summary: ImportSyncSummary
    private(set) var rows: [ImportReviewRow] = []
    var platformPolicy: ImportPlatformPolicy {
        didSet { if platformPolicy != oldValue { remapPlatforms() } }
    }

    private(set) var isCommitting = false
    private(set) var committed = false
    private(set) var successMessage: String?
    private(set) var commitError: String?

    @ObservationIgnored private let transientByID: [String: ImportStagingRow]
    @ObservationIgnored private let matchByID: [String: ScanMatchOutcome]

    init(source: String,
         sourceLabel: String,
         staging: ImportStagingStore,
         result: ImportSyncResult,
         platformPolicy: ImportPlatformPolicy = .macWhenAvailable,
         onLibraryChanged: @escaping () -> Void = {}) {
        self.source = source
        self.sourceLabel = sourceLabel
        self.staging = staging
        self.summary = result.summary
        self.platformPolicy = platformPolicy
        self.onLibraryChanged = onLibraryChanged
        self.transientByID = Dictionary(result.rows.map { ($0.externalID, $0) }, uniquingKeysWith: { a, _ in a })
        self.matchByID = Dictionary(
            result.matches.map { ($0.externalID, $0.outcome) }, uniquingKeysWith: { a, _ in a })
    }

    /// Read the staged titles and build the review rows. Call once when the sheet opens.
    func load() async {
        let titles = (try? await staging.titles(source: source)) ?? []
        rows = titles.map { makeRow(from: $0) }
    }

    private func makeRow(from title: ImportStagedTitle) -> ImportReviewRow {
        let transient = transientByID[title.externalID]
        let outcome = matchByID[title.externalID]
        let bucket = title.ignored ? ImportReviewBucket.ignored
            : (title.matchedGameID == nil ? .new : .alreadyMatched)
        let confidence = outcome?.bucket ?? .none
        // Confident, still-New matches are pre-ticked; the rest wait (PLAN §14.3).
        let include = bucket == .new && confidence == .confident
        return ImportReviewRow(
            externalID: title.externalID,
            sourceTitle: title.name,
            platform: title.platform,
            include: include,
            ignored: title.ignored,
            matchedGameID: title.matchedGameID,
            proposedMatch: outcome?.best,
            alternatives: outcome?.alternatives ?? [],
            confidence: confidence,
            ignoreReason: transient?.ignoreReason,
            releaseYear: transient?.releaseYear ?? outcome?.best?.releaseYear,
            macAvailable: transient?.macAvailable ?? false,
            linuxOnly: transient?.linuxOnly ?? false)
    }

    // MARK: Buckets

    func rows(in bucket: ImportReviewBucket) -> [ImportReviewRow] { rows.filter { $0.bucket == bucket } }
    var presentBuckets: [ImportReviewBucket] {
        [.new, .alreadyMatched, .ignored].filter { b in rows.contains { $0.bucket == b } }
    }
    var committableCount: Int { rows.filter(\.isCommittable).count }
    var canCommit: Bool { !committed && !isCommitting && committableCount > 0 }
    var commitButtonTitle: String { "Import \(committableCount) Game\(committableCount == 1 ? "" : "s")" }

    // MARK: Edits

    private func mutate(_ externalID: String, _ transform: (inout ImportReviewRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.externalID == externalID }) else { return }
        transform(&rows[index])
    }

    func setInclude(_ include: Bool, externalID: String) {
        mutate(externalID) { if !$0.ignored { $0.include = include } }
    }

    func setPlatform(_ slug: String, externalID: String) {
        mutate(externalID) { $0.platform = slug }
    }

    func ignore(_ externalID: String) {
        mutate(externalID) { $0.ignored = true; $0.include = false }
        persist(externalID, .ignore)
    }

    func restore(_ externalID: String) {
        mutate(externalID) { $0.ignored = false }
        persist(externalID, .restore)
    }

    func chooseAlternative(_ match: ScanMatch, externalID: String) {
        mutate(externalID) { row in
            row.proposedMatch = match
            var bucket = ScanMatching.bucket(for: match.score)
            if bucket == .none { bucket = .plausible }   // an explicit pick is at least plausible
            row.confidence = bucket
            if !row.ignored { row.include = true }
        }
    }

    /// Re-map every pending row's platform under the current policy (PLAN §14.3).
    private func remapPlatforms() {
        for i in rows.indices {
            rows[i].platform = platformPolicy == .alwaysPC ? "pc" : (rows[i].macAvailable ? "mac" : "pc")
        }
    }

    func selectAll(in bucket: ImportReviewBucket) { setInclude(true, bucket: bucket) }
    func selectNone(in bucket: ImportReviewBucket) { setInclude(false, bucket: bucket) }
    private func setInclude(_ include: Bool, bucket: ImportReviewBucket) {
        for i in rows.indices where rows[i].bucket == bucket && !rows[i].ignored {
            rows[i].include = include
        }
    }

    private func persist(_ externalID: String, _ decision: ImportDecision) {
        let store = staging, src = source
        Task { try? await store.setDecision(source: src, externalID: externalID, decision) }
    }

    // MARK: Commit

    /// The commit payload for the ticked rows (pure — asserted directly in tests). A row
    /// tied to an existing library game commits as `.existingGame`; otherwise a new game
    /// is created (`LibraryStore` dedupes by IGDB id, so a game already present is not
    /// duplicated). Games land owned, not played (PLAN §14.3).
    func commitItems() -> [ImportCommitItem] {
        rows.filter(\.isCommittable).map { row in
            let platformID = row.platform ?? "pc"
            let target: ImportCommitItem.Target
            if let gameID = row.matchedGameID {
                target = .existingGame(gameID: gameID)
            } else {
                let title = row.proposedMatch?.name ?? row.sourceTitle
                let alts = (row.proposedMatch != nil && row.showsSourceTitle) ? [row.sourceTitle] : []
                target = .newGame(ImportNewGameSpec(
                    title: title, igdbID: row.proposedMatch?.igdbID,
                    releaseYear: row.releaseYear, altTitles: alts))
            }
            return ImportCommitItem(
                source: source, externalID: row.externalID, platformID: platformID,
                format: .digital, target: target)
        }
    }

    func commit() {
        guard canCommit else { return }
        isCommitting = true
        commitError = nil
        let items = commitItems()
        let store = staging
        Task {
            do {
                let result = try await store.commit(items)
                successMessage = Self.successMessage(from: result, sourceLabel: sourceLabel)
                committed = true
                onLibraryChanged()
            } catch {
                commitError = "Couldn't import the games — nothing was changed."
            }
            isCommitting = false
        }
    }

    static func successMessage(from result: ImportCommitResult, sourceLabel: String) -> String {
        let imported = result.gamesCreated + result.productsAdded
        var bits = ["\(imported) game\(imported == 1 ? "" : "s") imported from \(sourceLabel)"]
        if result.skippedExisting > 0 {
            bits.append("\(result.skippedExisting) already in your library")
        }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Sheet

/// The shared import review sheet (PLAN §14.3): header summary + platform switch, three
/// buckets (*New / Already matched / Ignored*), one commit.
struct ImportReviewSheet: View {
    @Bindable var model: ImportReviewModel
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await model.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from \(model.sourceLabel)").font(.headline)
                Text(model.summary.networkSummaryLine).font(.caption).foregroundStyle(.secondary)
                if let note = model.summary.ownedGapNote {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Platform", selection: $model.platformPolicy) {
                ForEach(ImportPlatformPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(12)
    }

    private var list: some View {
        List {
            ForEach(model.presentBuckets, id: \.self) { bucket in
                Section {
                    ForEach(model.rows(in: bucket)) { row in
                        ImportReviewRowView(model: model, row: row)
                    }
                } header: {
                    bucketHeader(bucket)
                }
            }
        }
        .listStyle(.inset)
    }

    private func bucketHeader(_ bucket: ImportReviewBucket) -> some View {
        HStack {
            Text(bucket.label).font(.headline)
            Text("\(model.rows(in: bucket).count)").foregroundStyle(.secondary)
            Spacer()
            if bucket != .ignored {
                Button("All") { model.selectAll(in: bucket) }.controlSize(.small)
                Button("None") { model.selectNone(in: bucket) }.controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let message = model.successMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("\(model.committableCount) selected").foregroundStyle(.secondary)
            }
            if let error = model.commitError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Spacer()
            if model.committed {
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button(model.commitButtonTitle) { model.commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canCommit)
                    .overlay(alignment: .trailing) {
                        if model.isCommitting { ProgressView().controlSize(.small).offset(x: 22) }
                    }
            }
        }
        .padding(12)
    }
}

// MARK: - Row

private struct ImportReviewRowView: View {
    @Bindable var model: ImportReviewModel
    let row: ImportReviewRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.bucket != .ignored { includeCheckbox }
            ImportCoverThumb(imageID: row.proposedMatch?.coverImageID)
            titleBlock
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var includeCheckbox: some View {
        Button {
            model.setInclude(!row.include, externalID: row.externalID)
        } label: {
            Image(systemName: row.include ? "checkmark.square.fill" : "square")
                .foregroundStyle(row.include ? Color.accentColor : .secondary)
                .font(.title3)
        }
        .buttonStyle(.borderless)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.matchedTitle ?? row.sourceTitle).bold()
                if let year = row.releaseYear { Text(String(year)).foregroundStyle(.secondary) }
                confidenceBadge
            }
            if row.showsSourceTitle, row.matchedTitle != nil {
                Text("GOG: \(row.sourceTitle)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                platformMenu
                if row.linuxOnly {
                    Text("Linux-only → PC").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("This title runs only on Linux; imported as a PC game.")
                }
                if let reason = row.ignoreReason, row.bucket == .ignored {
                    Text(reason.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var confidenceBadge: some View {
        Group {
            if let score = row.proposedMatch?.score {
                Text("\(Int(score * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var platformMenu: some View {
        Menu {
            ForEach(["pc", "mac"], id: \.self) { slug in
                Button(PlatformLabels.short(slug)) { model.setPlatform(slug, externalID: row.externalID) }
            }
        } label: {
            Text(row.platform.map(PlatformLabels.short) ?? "platform?")
                .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .background(.tint.opacity(0.2), in: Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            Menu {
                MatchAlternativesSection(alternatives: row.alternatives) { alt in
                    model.chooseAlternative(alt, externalID: row.externalID)
                }
                Divider()
                if row.bucket == .ignored {
                    Button("Restore") { model.restore(row.externalID) }
                } else {
                    Button("Ignore", role: .destructive) { model.ignore(row.externalID) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

// MARK: - Cover thumb

private struct ImportCoverThumb: View {
    let imageID: String?

    var body: some View {
        Group {
            if let imageID, let url = IGDBImageURL.cover(imageID: imageID, size: .coverSmall) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: 30, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            .overlay(Image(systemName: "gamecontroller").foregroundStyle(.secondary).font(.caption2))
    }
}
