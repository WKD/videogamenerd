import Foundation
import Testing
@testable import VGN

/// The photo-scan **accuracy harness** (PLAN §6.2, milestone 6 "done when"). It runs
/// the *real* pipeline (tiler → `ClaudeShelfRecognizer` over the local `claude` CLI →
/// merge → real `IGDBClient` match) on the original shelf photos, compares against the
/// owner-verified `docs/shelf-truth-draft.json`, and writes `docs/recognition-accuracy.md`.
///
/// It is **excluded from the normal test run**: it spends real Claude subscription
/// usage and IGDB calls, so it does nothing unless a sentinel file exists
/// (`<worktree>/.build/vgn-live-scan`, created by `scripts/scan-accuracy.sh`). Under a
/// normal `xcodebuild test` the sentinel is absent and this test returns immediately.
struct RecognitionAccuracyHarness {

    @Test("Live photo-scan accuracy run (skipped unless the sentinel is present)")
    func run() async throws {
        guard let config = Self.liveConfig() else { return }   // normal runs: no-op
        try await Self.execute(config)
    }

    // MARK: - Config

    struct Config {
        var photos: [String]
        var model: String?
        var maxConcurrent: Int
    }

    /// Read `<worktree>/.build/vgn-live-scan`. Absent → nil (skip). Optional lines:
    /// `photos:IMG_3686,IMG_3687`, `model:opus`, `concurrent:3`.
    static func liveConfig() -> Config? {
        let sentinel = worktreeRoot().appendingPathComponent(".build/vgn-live-scan")
        guard let text = try? String(contentsOf: sentinel, encoding: .utf8) else {
            if ProcessInfo.processInfo.environment["VGN_LIVE_SCAN"] != "1" { return nil }
            return Config(photos: allPhotos, model: nil, maxConcurrent: 3)
        }
        var photos = allPhotos
        var model: String? = nil
        var concurrent = 3
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            switch parts[0] {
            case "photos": photos = parts[1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            case "model": model = parts[1]
            case "concurrent": concurrent = Int(parts[1]) ?? 3
            default: break
            }
        }
        return Config(photos: photos, model: model, maxConcurrent: concurrent)
    }

    static let allPhotos = ["IMG_3683", "IMG_3684", "IMG_3685", "IMG_3686", "IMG_3687"]

    // MARK: - Paths

    static func worktreeRoot() -> URL {
        // <worktree>/VGNTests/Services/RecognitionAccuracyHarness.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func samplesDir() -> URL {
        worktreeRoot().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("samples")
    }
    static func docsDir() -> URL { worktreeRoot().appendingPathComponent("docs") }

    // MARK: - Execution

    static func execute(_ config: Config) async throws {
        let catalog = try loadCatalog()
        let credentials = try loadCredentials()
        let transport = URLSessionTransport()
        let igdb = IGDBClient(transport: transport, credentials: { credentials }, catalog: catalog)

        let costs = CostBox()
        let recognizer = ClaudeShelfRecognizer(
            runner: ClaudeProcessRunner(),
            model: config.model,
            maxConcurrent: config.maxConcurrent
        ) { tileID, metrics in costs.record(tileID: tileID, metrics: metrics) }

        let pipeline = ScanPipeline(recognizer: recognizer, searcher: igdb, catalog: catalog)
        let truth = try loadTruth()

        var reports: [PhotoReport] = []
        let overallStart = Date()
        for photo in config.photos {
            guard let truthPhoto = truth.photos.first(where: { $0.photo == photo }) else { continue }
            let url = samplesDir().appendingPathComponent("\(photo).png")
            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("missing sample \(url.path)"); continue
            }
            let start = Date()
            let result = try await pipeline.scan(photoAt: url, photoName: photo)
            let wall = Date().timeIntervalSince(start)
            reports.append(evaluate(photo: photo, truth: truthPhoto, result: result, wall: wall, costs: costs))
        }
        let totalWall = Date().timeIntervalSince(overallStart)

        let markdown = renderReport(reports: reports, config: config, totalWall: totalWall, costs: costs)
        let out = docsDir().appendingPathComponent("recognition-accuracy.md")
        try markdown.write(to: out, atomically: true, encoding: .utf8)
        print("Wrote \(out.path)")
    }

    // MARK: - Evaluation

    static func evaluate(photo: String, truth: TruthPhoto, result: PhotoScanResult, wall: TimeInterval, costs: CostBox) -> PhotoReport {
        var truthItems = truth.items
        var scanned = result.items
        var matchedTruth = Set<Int>()
        var matchedScan = Set<Int>()
        var pairs: [(truthIdx: Int, scanIdx: Int)] = []

        // Greedy title matching (same normaliser via FuzzyMatch).
        for (ti, t) in truthItems.enumerated() {
            var bestScore = 0.0, bestIdx = -1
            for (si, s) in scanned.enumerated() where !matchedScan.contains(si) {
                let score = titleScore(scan: s, truth: t)
                if score > bestScore { bestScore = score; bestIdx = si }
            }
            if bestScore >= titleThreshold, bestIdx >= 0 {
                matchedTruth.insert(ti); matchedScan.insert(bestIdx)
                pairs.append((ti, bestIdx))
            }
        }

        let recallHits = matchedTruth.count
        let falsePositives = scanned.enumerated().filter { !matchedScan.contains($0.offset) }.map { $0.element.printedTitle }
        var platformCorrect = 0, igdbCorrect = 0
        for pair in pairs {
            let t = truthItems[pair.truthIdx], s = scanned[pair.scanIdx]
            if s.platformSlug == t.platform { platformCorrect += 1 }
            if let match = s.match, s.matchBucket != .none,
               FuzzyMatch.score(match.name, t.title) >= titleThreshold { igdbCorrect += 1 }
        }

        // Per row = per platform group within the photo (the answer key is
        // platform-contiguous per shelf row).
        var rowRecall: [String: (found: Int, total: Int)] = [:]
        for (ti, t) in truthItems.enumerated() {
            var entry = rowRecall[t.platform] ?? (0, 0)
            entry.total += 1
            if matchedTruth.contains(ti) { entry.found += 1 }
            rowRecall[t.platform] = entry
        }

        let missed = truthItems.enumerated().filter { !matchedTruth.contains($0.offset) }.map { "\($0.element.title) [\($0.element.platform)]" }

        return PhotoReport(
            photo: photo,
            truthCount: truthItems.count,
            detectedCount: scanned.count,
            recallHits: recallHits,
            falsePositives: falsePositives,
            missed: missed,
            platformCorrect: platformCorrect,
            igdbCorrect: igdbCorrect,
            rowRecall: rowRecall,
            tileCount: result.tileCount,
            failedTiles: result.failedTileIDs.count,
            wall: wall
        )
    }

    static let titleThreshold = 0.86

    static func titleScore(scan: ScannedItem, truth: TruthItem) -> Double {
        var scanNames = [scan.printedTitle]
        if let n = scan.normalizedGuess { scanNames.append(n) }
        if let m = scan.match { scanNames.append(m.name) }
        var truthNames = [truth.title]
        if let p = truth.printedTitle { truthNames.append(p) }
        var best = 0.0
        for a in scanNames { for b in truthNames { best = max(best, FuzzyMatch.score(a, b)) } }
        return best
    }

    // MARK: - Loading

    static func loadCatalog() throws -> PlatformCatalog {
        if let catalog = try? PlatformCatalog.loadFromBundle(.main) { return catalog }
        let url = worktreeRoot().appendingPathComponent("VGN/Resources/platforms.json")
        return try PlatformCatalog.load(from: try Data(contentsOf: url))
    }

    static func loadCredentials() throws -> IGDBCredentials {
        let path = ("~/.config/vgn/igdb.env" as NSString).expandingTildeInPath
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var dict: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            dict[key] = value
        }
        guard let id = dict["IGDB_CLIENT_ID"], let secret = dict["IGDB_CLIENT_SECRET"] else {
            throw HarnessError.missingCredentials
        }
        return IGDBCredentials(clientID: id, secret: secret)
    }

    static func loadTruth() throws -> TruthFile {
        let url = docsDir().appendingPathComponent("shelf-truth-draft.json")
        return try JSONDecoder().decode(TruthFile.self, from: try Data(contentsOf: url))
    }

    enum HarnessError: Error { case missingCredentials }

    // MARK: - Truth model

    struct TruthFile: Decodable { let photos: [TruthPhoto] }
    struct TruthPhoto: Decodable { let photo: String; let items: [TruthItem] }
    struct TruthItem: Decodable { let title: String; let platform: String; let printedTitle: String? }

    // MARK: - Report model

    struct PhotoReport {
        var photo: String
        var truthCount: Int
        var detectedCount: Int
        var recallHits: Int
        var falsePositives: [String]
        var missed: [String]
        var platformCorrect: Int
        var igdbCorrect: Int
        var rowRecall: [String: (found: Int, total: Int)]
        var tileCount: Int
        var failedTiles: Int
        var wall: TimeInterval
    }

    /// Thread-safe per-tile cost/timing accumulator.
    final class CostBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _totalCost = 0.0
        private var _durations: [Double] = []
        private var _model: String?
        func record(tileID: Int, metrics: ClaudeRunMetrics) {
            lock.withLock {
                _totalCost += metrics.costUSD ?? 0
                if let ms = metrics.durationMS { _durations.append(Double(ms) / 1000.0) }
                if _model == nil { _model = metrics.model }
            }
        }
        var totalCost: Double { lock.withLock { _totalCost } }
        var tileCalls: Int { lock.withLock { _durations.count } }
        var avgTileSeconds: Double { lock.withLock { _durations.isEmpty ? 0 : _durations.reduce(0, +) / Double(_durations.count) } }
        var maxTileSeconds: Double { lock.withLock { _durations.max() ?? 0 } }
        var model: String? { lock.withLock { _model } }
    }

    // MARK: - Rendering

    static func renderReport(reports: [PhotoReport], config: Config, totalWall: TimeInterval, costs: CostBox) -> String {
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "—" : String(format: "%.0f%%", 100.0 * Double(n) / Double(d)) }
        let totalTruth = reports.reduce(0) { $0 + $1.truthCount }
        let totalHits = reports.reduce(0) { $0 + $1.recallHits }
        let totalDetected = reports.reduce(0) { $0 + $1.detectedCount }
        let totalFP = reports.reduce(0) { $0 + $1.falsePositives.count }
        let totalPlatform = reports.reduce(0) { $0 + $1.platformCorrect }
        let totalIGDB = reports.reduce(0) { $0 + $1.igdbCorrect }

        var md = """
        # Photo-scan recognition accuracy

        Generated by `RecognitionAccuracyHarness` (run via `scripts/scan-accuracy.sh`) —
        the real pipeline (tiler → Claude CLI recogniser → overlap merge → IGDB match)
        over the owner-verified answer key `docs/shelf-truth-draft.json`.

        - **Model:** \(costs.model ?? config.model ?? "CLI default")
        - **Photos:** \(config.photos.joined(separator: ", "))
        - **Tile CLI calls:** \(costs.tileCalls) · **avg** \(String(format: "%.1f", costs.avgTileSeconds)) s/tile · **max** \(String(format: "%.1f", costs.maxTileSeconds)) s
        - **Total wall time:** \(String(format: "%.0f", totalWall)) s · **Claude usage:** $\(String(format: "%.2f", costs.totalCost))
        - **Recall:** \(pct(totalHits, totalTruth)) (\(totalHits)/\(totalTruth)) · **Precision:** \(pct(totalHits, totalDetected)) (\(totalHits)/\(totalDetected)) · **False positives:** \(totalFP)
        - **Platform accuracy:** \(pct(totalPlatform, totalHits)) · **IGDB pre-match rate:** \(pct(totalIGDB, totalHits)) (target ≥ 90%)

        > Recall = answer-key games identified; precision = detections matching a real game;
        > per-row = per platform group within a photo (the key is platform-contiguous per
        > shelf row). The two unreadable spines in the `skip` list are not in the key and
        > should be neither credited nor penalised; a hallucinated title there would show
        > as a false positive below.

        ## Per photo

        | Photo | Tiles | Truth | Detected | Recall | Precision | FP | Platform | IGDB pre-match | Time |
        |---|--:|--:|--:|--:|--:|--:|--:|--:|--:|

        """
        for r in reports {
            md += "| \(r.photo) | \(r.tileCount) | \(r.truthCount) | \(r.detectedCount) | \(pct(r.recallHits, r.truthCount)) | \(pct(r.recallHits, r.detectedCount)) | \(r.falsePositives.count) | \(pct(r.platformCorrect, r.recallHits)) | \(pct(r.igdbCorrect, r.recallHits)) | \(String(format: "%.0f", r.wall))s |\n"
        }

        md += "\n## Per shelf row (platform group)\n\n| Photo | Row (platform) | Recall |\n|---|---|--:|\n"
        for r in reports {
            for (platform, rc) in r.rowRecall.sorted(by: { $0.key < $1.key }) {
                md += "| \(r.photo) | \(platform) | \(pct(rc.found, rc.total)) (\(rc.found)/\(rc.total)) |\n"
            }
        }

        md += "\n## Misses and false positives\n\n"
        for r in reports {
            md += "### \(r.photo)\n\n"
            md += "- **Missed (\(r.missed.count)):** " + (r.missed.isEmpty ? "none" : r.missed.joined(separator: "; ")) + "\n"
            md += "- **False positives (\(r.falsePositives.count)):** " + (r.falsePositives.isEmpty ? "none" : r.falsePositives.joined(separator: "; ")) + "\n\n"
        }

        md += "\n_Regenerate: `scripts/scan-accuracy.sh`. Cross-photo duplicates are expected (frames overlap) and correct._\n"
        return md
    }
}
