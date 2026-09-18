import SwiftUI
import UniformTypeIdentifiers

/// The photo-scan scene (PLAN §6.2). A thin shell over ``PhotoScanModel`` that switches
/// between the input queue, the per-photo progress, the review sheet and the summary.
/// The orchestrator presents this in a window or sheet.
struct PhotoScanView: View {
    @Bindable var model: PhotoScanModel
    /// Called when the user is done (Close / after committing) so the host can dismiss.
    var onClose: () -> Void = {}

    @State private var showingFileImporter = false

    var body: some View {
        Group {
            switch model.presentation {
            case .input:
                PhotoScanInputView(model: model, showingFileImporter: $showingFileImporter,
                                   onClose: onClose)
            case .running:
                PhotoScanProgressView(model: model)
            case .review:
                PhotoScanReviewView(model: model, onClose: onClose)
            case .committed:
                PhotoScanSummaryView(model: model, onClose: onClose)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .accessibilityIdentifier(A11yID.scanSheet)
        .dropDestination(for: URL.self) { urls, _ in
            model.enqueue(urls)
            return model.presentation == .input
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image, .heic, .jpeg, .png],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.enqueue(urls) }
        }
    }
}

// MARK: - Input

private struct PhotoScanInputView: View {
    @Bindable var model: PhotoScanModel
    @Binding var showingFileImporter: Bool
    /// Dismiss the whole sheet. Previously the input state had no working close
    /// control (a hidden Cancel with an empty action), so it could not be
    /// dismissed before queuing a photo — found by the UI smoke suite (flow k).
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan Shelf Photos")
                .font(.title2).bold()

            Label(PhotoScanModel.costNotice, systemImage: "bolt.badge.clock")
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier(A11yID.scanUsageNotice)

            dropZone

            if !model.jobs.isEmpty {
                queuedList
            }

            Spacer()

            HStack {
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)   // esc now actually dismisses
                    .accessibilityIdentifier(A11yID.scanClose)
                Spacer()
                Text(model.jobs.isEmpty ? "" : "\(model.jobs.count) photo\(model.jobs.count == 1 ? "" : "s") queued")
                    .foregroundStyle(.secondary)
                Button("Scan \(model.jobs.count) Photo\(model.jobs.count == 1 ? "" : "s")") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drag shelf photos here")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Choose Files…") { showingFileImporter = true }
                #if canImport(AppKit)
                ContinuityCameraButton(title: "Take Photo") { url in model.enqueue([url]) }
                    .fixedSize()
                #endif
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(.tertiary)
        )
    }

    private var queuedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Queued").font(.headline)
            ForEach(model.jobs) { job in
                HStack {
                    Image(systemName: "photo")
                    Text(job.name)
                    Spacer()
                    Button {
                        model.removeJob(job.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Progress

private struct PhotoScanProgressView: View {
    @Bindable var model: PhotoScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scanning…").font(.title2).bold()
                Spacer()
                if let engine = model.activeEngine {
                    Label(engine == .claude ? "Claude" : "Vision OCR",
                          systemImage: engine == .claude ? "sparkles" : "eye")
                        .foregroundStyle(.secondary)
                }
                if model.totalCost > 0 {
                    Text(String(format: "$%.2f", model.totalCost))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if let note = model.fallbackNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.jobs) { job in
                        PhotoJobRow(job: job) { model.cancel(jobID: job.id) }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel All", role: .destructive) { model.cancelAll() }
            }
        }
        .padding(20)
    }
}

private struct PhotoJobRow: View {
    let job: PhotoScanJob
    var onCancel: () -> Void

    private var doneTiles: Int { job.tiles.filter { $0.state.rank == 2 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.name).bold()
                Spacer()
                if job.costUSD > 0 {
                    Text(String(format: "$%.2f", job.costUSD)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let elapsed = job.elapsed {
                    Text("\(Int(elapsed))s").monospacedDigit().foregroundStyle(.secondary)
                }
                if !job.phase.isTerminal {
                    Button { onCancel() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                statusIcon
                Text(job.phase.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if job.tileTotal > 0 {
                    Text("\(doneTiles)/\(job.tileTotal) tiles").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if job.tileTotal > 0, !job.phase.isTerminal {
                ProgressView(value: Double(doneTiles), total: Double(job.tileTotal))
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.phase {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Summary

private struct PhotoScanSummaryView: View {
    @Bindable var model: PhotoScanModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Import complete").font(.title2).bold()
            if let summary = model.summary {
                Text(summary.message).foregroundStyle(.secondary)
            }
            HStack {
                if model.summary?.firstGameID != nil {
                    Button("Show in Library") { model.showInLibrary(); onClose() }
                }
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Scan — progress") {
    PhotoScanView(model: PhotoScanPreview.runningModel())
}
#endif
