import SwiftUI

/// The one import-progress sheet body, shared by GOG / PSN / Delicious / Batocera
/// (owner 2026-09-20). It has a **fixed width** so the sheet never resizes between
/// phases or as the current title changes: the "Matching N of M" counter is rendered
/// with monospaced digits and never truncated, the game title takes the remaining
/// width and **middle-truncates** on one line, and the resume ("· N already matched")
/// and ETA ("about 3 min left") lines reserve their height even when empty so nothing
/// jumps. The ETA maths lives in the pure ``ImportMatchProgress`` (injected clock, no
/// wall-clock in tests).
struct ImportMatchingProgressView: View {
    let progress: ImportProgress?
    /// The source-specific phase caption ("Fetching your GOG library…", …).
    let phaseLabel: String
    /// The accessibility identifier for the Cancel button (e.g. "psn.sync.cancel").
    var cancelIdentifier: String = "import.sync.cancel"
    var onCancel: () -> Void = {}
    /// Injected for deterministic previews/tests; the app uses the wall clock.
    var now: () -> Date = { Date() }

    /// The fixed sheet width. Wide enough for a long counter before the title truncates.
    static let width: CGFloat = 460

    @State private var matchingStart: Date?

    var body: some View {
        VStack(spacing: 14) {
            if progress?.phase == .matching {
                matchingBody
            } else {
                indeterminateBody
            }
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(cancelIdentifier)
        }
        .padding(28)
        .frame(width: Self.width)
        .onChange(of: progress?.phase) { _, phase in
            if phase == .matching, matchingStart == nil { matchingStart = now() }
        }
    }

    // MARK: Non-matching phases (sign-in, fetch, staging, finishing)

    @ViewBuilder
    private var indeterminateBody: some View {
        ProgressView().controlSize(.large)
        Text(phaseLabel).font(.headline)
        // Reserve the detail line's height so the sheet keeps a constant size.
        Text(detailOrPlaceholder)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .center)
            .opacity((progress?.detail.isEmpty == false) ? 1 : 0)
    }

    private var detailOrPlaceholder: String {
        let d = progress?.detail ?? ""
        return d.isEmpty ? " " : d
    }

    // MARK: Matching phase

    @ViewBuilder
    private var matchingBody: some View {
        let completed = progress?.completed ?? 0
        let total = progress?.total

        if let fraction = ImportMatchProgress.fraction(completed: completed, total: total) {
            ProgressView(value: fraction).controlSize(.large)
        } else {
            ProgressView().controlSize(.large)
        }

        Text(phaseLabel).font(.headline)

        // Counter (never truncated, monospaced digits) + title (middle-truncated).
        HStack(spacing: 6) {
            Text(ImportMatchProgress.counter(completed: completed, total: total))
                .monospacedDigit()
                .fixedSize()
            if !currentTitle.isEmpty {
                Text("· \(currentTitle)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)

        // Resume detail — reserved height.
        Text(resumeText)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .opacity((progress?.alreadyMatched ?? 0) > 0 ? 1 : 0)

        // ETA — reserved height (shown after ~10 titles; hidden text keeps the size).
        Text(etaText ?? " ")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .opacity(etaText == nil ? 0 : 1)
    }

    /// The current title — prefers the dedicated field, falling back to `detail` for any
    /// caller that has not been updated to set it.
    private var currentTitle: String {
        let t = progress?.currentTitle ?? ""
        return t.isEmpty ? (progress?.detail ?? "") : t
    }

    private var resumeText: String {
        let n = progress?.alreadyMatched ?? 0
        return n > 0 ? "· \(n) already matched" : " "
    }

    private var etaText: String? {
        guard progress?.phase == .matching, let start = matchingStart else { return nil }
        return ImportMatchProgress.etaText(completed: progress?.completed ?? 0,
                                           total: progress?.total,
                                           elapsedSeconds: now().timeIntervalSince(start))
    }
}

#if DEBUG
#Preview("Matching — long title") {
    ImportMatchingProgressView(
        progress: ImportProgress(phase: .matching, completed: 137, total: 412,
                                 currentTitle: "The Legend of Zelda: Tears of the Kingdom — Collector's Edition",
                                 alreadyMatched: 24),
        phaseLabel: "Matching to IGDB…")
}

#Preview("Fetching") {
    ImportMatchingProgressView(
        progress: ImportProgress(phase: .fetching, detail: "Reading page 3"),
        phaseLabel: "Fetching your PlayStation library…")
}
#endif
