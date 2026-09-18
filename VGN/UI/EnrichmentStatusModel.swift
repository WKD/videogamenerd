import SwiftUI

/// A discreet view model for the background-enrichment indicator (PLAN §9): it
/// mirrors the coordinator's live status ("Fetching metadata · 12 left"), the
/// needs-credentials hint, the offline/retry state, and exposes a "Retry failed"
/// action. Nil coordinator/jobStore (sample mode, DB failure) ⇒ it stays idle.
@MainActor
@Observable
final class EnrichmentStatusModel {
    private(set) var status: EnrichmentStatus = .idle
    private(set) var counts: EnrichmentCounts = EnrichmentCounts()

    private let coordinator: EnrichmentCoordinator?
    private let jobStore: EnrichmentJobStore?

    private var statusTask: Task<Void, Never>?
    private var countsTask: Task<Void, Never>?

    init(coordinator: EnrichmentCoordinator?, jobStore: EnrichmentJobStore?) {
        self.coordinator = coordinator
        self.jobStore = jobStore
    }

    func start() {
        guard let coordinator, statusTask == nil else { return }
        statusTask = Task { [weak self] in
            for await value in await coordinator.statusUpdates() {
                if Task.isCancelled { break }
                self?.status = value
            }
        }
        if let jobStore {
            countsTask = Task { [weak self] in
                do {
                    for try await value in jobStore.counts() {
                        if Task.isCancelled { break }
                        self?.counts = value
                    }
                } catch { /* observation ended */ }
            }
        }
    }

    func stop() {
        statusTask?.cancel(); statusTask = nil
        countsTask?.cancel(); countsTask = nil
    }

    func retryFailed() {
        guard let coordinator else { return }
        Task { await coordinator.retryFailed() }
    }

    // MARK: - Presentation

    /// True when there is anything at all worth showing a chrome row for.
    var isVisible: Bool {
        needsCredentials || hasFailures || displayText != nil
    }

    var needsCredentials: Bool { status == .needsCredentials && counts.remaining > 0 }
    var hasFailures: Bool { counts.failed > 0 }

    /// The one-line status, or nil when idle / needs-credentials (handled apart).
    var displayText: String? {
        switch status {
        case .running(let remaining) where remaining > 0:
            return "Fetching metadata · \(remaining) left"
        case .running:
            return "Fetching metadata…"
        case .offline:
            return counts.remaining > 0 ? "Offline — will retry" : nil
        case .paused:
            return counts.remaining > 0 ? "Enrichment paused" : nil
        case .idle, .needsCredentials:
            return nil
        }
    }

    var isBusy: Bool {
        if case .running = status { return true }
        return false
    }
}

/// The sidebar footer that surfaces the enrichment status (PLAN §9).
struct EnrichmentStatusFooter: View {
    @Bindable var model: EnrichmentStatusModel

    var body: some View {
        if model.isVisible {
            VStack(alignment: .leading, spacing: 6) {
                if model.needsCredentials {
                    SettingsLink {
                        Label("Add IGDB credentials to fetch covers & metadata", systemImage: "key")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if let text = model.displayText {
                    HStack(spacing: 6) {
                        if model.isBusy { ProgressView().controlSize(.small) }
                        Text(text).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
                if model.hasFailures {
                    Button {
                        model.retryFailed()
                    } label: {
                        Label("Retry \(model.counts.failed) failed", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}
