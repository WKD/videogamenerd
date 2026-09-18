import Foundation

// MARK: - Settings / engine

/// Which recognition engine the user prefers (persisted; PLAN §6.2 step 2/3).
enum ScanEnginePreference: String, Sendable, Equatable, CaseIterable, Codable {
    /// Claude vision through the local CLI, automatically falling back to Apple
    /// Vision OCR when the CLI is missing / not logged in / times out.
    case claudeWithVisionFallback
    /// Never spawn the CLI — offline Apple Vision OCR only.
    case visionOnly

    var label: String {
        switch self {
        case .claudeWithVisionFallback: return "Claude, with Vision fallback"
        case .visionOnly: return "Vision OCR only (offline)"
        }
    }
}

/// The engine actually used for a run (after preflight / fallback resolution).
enum ActiveScanEngine: String, Sendable, Equatable {
    case claude
    case vision
}

/// Persisted photo-scan configuration (Settings → Photo Scan). `model` empty means
/// the CLI default; `binaryOverride` empty means auto-detect.
struct PhotoScanSettings: Sendable, Equatable {
    var binaryOverride: String = ""
    var model: String = ""
    var maxConcurrent: Int = 3
    var enginePreference: ScanEnginePreference = .claudeWithVisionFallback

    /// Clamp the parallelism to the supported 1–4 range (PLAN §6.2 Settings).
    var clampedConcurrency: Int { min(4, max(1, maxConcurrent)) }
}

// MARK: - Per-photo job state

/// A single tile's live progress within a photo (PLAN §6.2: "a progress row per tile").
struct ScanTileProgress: Identifiable, Equatable, Sendable {
    let id: Int          // tileID
    var state: State

    enum State: Equatable, Sendable {
        case queued
        case running
        case done(items: Int)
        case failed(reason: String)

        /// Monotonic rank so out-of-order event delivery never regresses a tile.
        var rank: Int {
            switch self {
            case .queued: return 0
            case .running: return 1
            case .done, .failed: return 2
            }
        }
    }
}

/// The per-photo state machine (PLAN §6.2): queued → tiling → recognising → matching →
/// ready / failed / cancelled.
enum PhotoJobPhase: Equatable, Sendable {
    case queued
    case tiling
    case recognizing
    case matching
    case ready
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .tiling: return "Splitting into tiles…"
        case .recognizing: return "Recognising spines…"
        case .matching: return "Matching to IGDB…"
        case .ready: return "Ready"
        case .failed(let reason): return "Failed — \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// One queued photo and everything the progress UI shows for it.
struct PhotoScanJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    /// Display name, e.g. "IMG_3684".
    let name: String
    var phase: PhotoJobPhase = .queued
    var tileTotal: Int = 0
    var tiles: [ScanTileProgress] = []
    /// Running Claude cost for this photo (sum of per-tile `costUSD`).
    var costUSD: Double = 0
    var startedAt: Date?
    var finishedAt: Date?
    var result: PhotoScanResult?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
    }

    var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var detectedCount: Int { result?.items.count ?? 0 }
}

// MARK: - Review rows

/// One row in the review sheet (PLAN §6.2 step 5). Wraps the pipeline's `ScannedItem`
/// with the user-editable decision (include / played / platform / format / chosen
/// match / ignore) and cross-photo provenance.
struct ScanReviewRow: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The representative scanned item (first photo it was seen in).
    var item: ScannedItem
    /// The currently-chosen IGDB match (starts as `item.match`; changed via the
    /// alternatives menu or an inline IGDB search).
    var selectedMatch: ScanMatch?
    /// Alternatives offered in the menu (the pipeline's, plus any search results).
    var alternatives: [ScanMatch]
    /// The confidence bucket the row is grouped under (recomputed when the match
    /// changes).
    var bucket: ScanConfidenceBucket
    var include: Bool
    var played: Bool
    /// The platform slug an add will use (from the spine, editable).
    var platformSlug: String?
    var format: ProductFormat
    /// "Not a game — ignore": excluded and never committed.
    var ignored: Bool
    /// The matched game+platform is already in the library (greyed out).
    var alreadyInLibrary: Bool
    /// Whether the (chosen) match is a compilation/bundle.
    var isCompilation: Bool
    /// Every source photo this spine was seen in (cross-photo collapse).
    var seenInPhotos: [String]

    /// The printed title as boxed (may be a French/edition title).
    var printedTitle: String { item.printedTitle }
    var matchedTitle: String? { selectedMatch?.name }
    var matchedYear: Int? { selectedMatch?.releaseYear }
    var coverImageID: String? { selectedMatch?.coverImageID }
    /// True when the printed title differs from the matched title (show both).
    var showsPrintedTitle: Bool {
        guard let matched = selectedMatch?.name else { return true }
        return matched.caseInsensitiveCompare(printedTitle) != .orderedSame
    }
    var isCommittable: Bool { include && !ignored }
    var seenCountLabel: String? {
        seenInPhotos.count > 1 ? "seen in \(seenInPhotos.count) photos" : nil
    }
    var alreadyInLibraryLabel: String? {
        guard alreadyInLibrary else { return nil }
        let plat = platformSlug.map(PlatformLabels.short) ?? ""
        let fmt = format.label.lowercased()
        let bits = [plat, fmt].filter { !$0.isEmpty }.joined(separator: " ")
        return bits.isEmpty ? "already in library" : "already in library · \(bits)"
    }
}

/// Presentation order for the three buckets.
extension ScanConfidenceBucket {
    var order: Int {
        switch self {
        case .confident: return 0
        case .plausible: return 1
        case .none: return 2
        }
    }

    var sectionTitle: String {
        switch self {
        case .confident: return "Confident"
        case .plausible: return "Plausible"
        case .none: return "No match"
        }
    }
}

// MARK: - Commit summary

/// The outcome banner after committing (PLAN §6.2 step 5).
struct ScanCommitSummary: Sendable, Equatable {
    var created: Int
    var copies: Int
    var alreadyPresent: Int
    /// The first created game id, for "Show in library".
    var firstGameID: Int64?

    var message: String {
        var bits: [String] = []
        bits.append("\(created) added")
        if copies > 0 { bits.append("\(copies) \(copies == 1 ? "copy" : "copies") added to existing games") }
        if alreadyPresent > 0 { bits.append("\(alreadyPresent) already present") }
        return bits.joined(separator: " · ")
    }

    static func from(outcomes: [AddOutcome]) -> ScanCommitSummary {
        var created = 0, copies = 0, present = 0
        var first: Int64?
        for outcome in outcomes {
            switch outcome {
            case .created(let id): created += 1; if first == nil { first = id }
            case .addedCopy: copies += 1
            case .alreadyPresent: present += 1
            }
        }
        return ScanCommitSummary(created: created, copies: copies, alreadyPresent: present, firstGameID: first)
    }
}
