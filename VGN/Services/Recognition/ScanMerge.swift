import Foundation

/// One detection after overlap merging: the best representative of a spine that may
/// have been seen in several overlapping tiles.
struct MergedDetection: Sendable, Equatable, Identifiable {
    let id: Int
    var printedTitle: String
    var normalizedTitle: String?
    var platform: String?
    var editionHints: [String]
    var isCompilation: Bool
    var confidence: Double
    var sourceRect: SourceRect
    /// The tile the representative detection came from.
    var tileID: Int
    var serialCode: SpineSerialCode?
    /// How many raw detections merged into this one.
    var memberCount: Int
}

/// Merges overlapping-tile detections within a single photo (PLAN §6.2 step 5:
/// "same spine seen twice = one item; two genuinely different copies side by side stay
/// two"). Purely geometric + fuzzy-title; Foundation only, deterministic.
enum ScanMerge {

    /// - Parameters:
    ///   - titleThreshold: fuzzy score above which two titles are "the same game".
    ///   - centerTolerance: max horizontal-centre distance (px) for two detections to
    ///     be the *same spine*. Overlapping tiles map one spine to nearly the same
    ///     absolute source x, so genuine duplicates are close; two side-by-side copies
    ///     sit far apart and stay separate.
    static func merge(
        _ detections: [AnchoredDetection],
        titleThreshold: Double = FuzzyMatch.confidentThreshold,
        centerTolerance: Int = 140
    ) -> [MergedDetection] {
        guard !detections.isEmpty else { return [] }
        let n = detections.count

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        for i in 0..<n {
            for j in (i + 1)..<n {
                if sameSpine(detections[i], detections[j], titleThreshold: titleThreshold, centerTolerance: centerTolerance) {
                    union(i, j)
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(i) }

        var merged: [MergedDetection] = []
        for (_, indices) in groups {
            let members = indices.map { detections[$0] }
            merged.append(representative(of: members))
        }
        // Deterministic order: left→right by source x, then title.
        return merged
            .sorted { ($0.sourceRect.x, $0.printedTitle) < ($1.sourceRect.x, $1.printedTitle) }
            .enumerated()
            .map { index, d in
                MergedDetection(
                    id: index, printedTitle: d.printedTitle, normalizedTitle: d.normalizedTitle,
                    platform: d.platform, editionHints: d.editionHints, isCompilation: d.isCompilation,
                    confidence: d.confidence, sourceRect: d.sourceRect, tileID: d.tileID,
                    serialCode: d.serialCode, memberCount: d.memberCount)
            }
    }

    /// Attach a serial code (and, if the detection had no platform, its platform) from
    /// a set of serial-bearing detections (e.g. a Vision pass) to any detection whose
    /// source rect overlaps positionally. A cross-engine platform/region booster.
    static func fuseSerials(
        into detections: [MergedDetection],
        from serialSources: [AnchoredDetection]
    ) -> [MergedDetection] {
        let sources = serialSources.filter { $0.serialCode != nil }
        guard !sources.isEmpty else { return detections }
        return detections.map { detection in
            guard detection.serialCode == nil,
                  let match = sources.first(where: { $0.sourceRect.horizontalOverlap(with: detection.sourceRect) > 0 }),
                  let serial = match.serialCode
            else { return detection }
            var d = detection
            d.serialCode = serial
            if d.platform == nil { d.platform = serial.platformSlug }
            return d
        }
    }

    // MARK: - Predicates

    static func sameSpine(
        _ a: AnchoredDetection,
        _ b: AnchoredDetection,
        titleThreshold: Double,
        centerTolerance: Int
    ) -> Bool {
        guard platformsCompatible(a.platform, b.platform) else { return false }
        let overlap = a.sourceRect.horizontalOverlap(with: b.sourceRect)
        let close = overlap > 0 || abs(Int(a.sourceRect.midX) - Int(b.sourceRect.midX)) <= centerTolerance
        guard close else { return false }
        let names_a = [a.printedTitle] + [a.detection.normalizedTitle].compactMap { $0 }
        let names_b = [b.printedTitle] + [b.detection.normalizedTitle].compactMap { $0 }
        var best = 0.0
        for na in names_a { best = max(best, FuzzyMatch.bestScore(query: na, names: names_b)) }
        if best >= titleThreshold { return true }
        // Prefix-aware merge (PLAN §6.2 / docs/recognition-accuracy.md): a spine sitting
        // on a tile boundary is read in full in one tile and as a truncated edge-cut
        // fragment ("God of W…", "…IE TWICE") in the neighbour. Those fragments score
        // below the fuzzy threshold, so merge them into the complete read here. The
        // geometry guard above already establishes "same spine", which is what keeps
        // genuinely different sequels apart ("Final Fantasy X" / "Final Fantasy X-2").
        return isTruncation(of: a.printedTitle, fragment: b.printedTitle)
            || isTruncation(of: b.printedTitle, fragment: a.printedTitle)
    }

    static func platformsCompatible(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return true }   // an unknown platform is compatible
        return a == b
    }

    // MARK: - Truncation (edge-cut spine fragments)

    /// Minimum length of a fragment's core (marker-stripped) text for it to be trusted
    /// as a truncation of a fuller title (PLAN §6.2: "≥ 3 characters"). Below this a
    /// stub like "DA…" is too ambiguous to fold in.
    static let minFragmentCore = 3

    /// Whether `fragment` is an edge-cut truncation of `whole` — the same spine read
    /// only partially in a neighbouring tile.
    ///
    /// Three signals, most specific first:
    ///  1. A trailing ellipsis (`…` / `...`) whose core is a prefix of `whole`
    ///     ("God of W…" → "God of War III").
    ///  2. A leading ellipsis whose core is a suffix of `whole`
    ///     ("…IE TWICE" → "Sekiro: Shadows Die Twice").
    ///  3. No marker, but the fragment is a strict prefix/suffix of `whole` that cuts
    ///     **through the middle of a word** — the continuing character in `whole` is a
    ///     letter or digit ("God of Wa|r"). A cut at a token boundary is *not* a
    ///     truncation, so "Final Fantasy X" (+"-2") and "Yakuza Kiwami" (+" 2") are
    ///     refused: those are complete titles that merely share a prefix.
    static func isTruncation(of whole: String, fragment: String) -> Bool {
        let w = normalizedForTruncation(whole)
        guard !w.isEmpty else { return false }

        let rawFragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTrailing = hasTrailingEllipsis(rawFragment)
        let hasLeading = hasLeadingEllipsis(rawFragment)
        let core = normalizedForTruncation(strippingEllipsis(rawFragment))
        guard core.count >= minFragmentCore else { return false }

        if hasTrailing { return w.hasPrefix(core) && core != w }
        if hasLeading { return w.hasSuffix(core) && core != w }

        // Marker-less: only a mid-word cut counts as a truncation.
        guard core.count < w.count else { return false }
        if w.hasPrefix(core) {
            let next = w[w.index(w.startIndex, offsetBy: core.count)]
            return next.isLetter || next.isNumber
        }
        if w.hasSuffix(core) {
            let prev = w[w.index(w.endIndex, offsetBy: -core.count - 1)]
            return prev.isLetter || prev.isNumber
        }
        return false
    }

    /// True if `title` carries an ellipsis truncation marker at either end.
    static func hasEllipsisMarker(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasTrailingEllipsis(t) || hasLeadingEllipsis(t)
    }

    private static func hasTrailingEllipsis(_ s: String) -> Bool {
        s.hasSuffix("…") || s.hasSuffix("...")
    }

    private static func hasLeadingEllipsis(_ s: String) -> Bool {
        s.hasPrefix("…") || s.hasPrefix("...")
    }

    private static func strippingEllipsis(_ s: String) -> String {
        var out = s
        while out.hasSuffix("…") { out.removeLast() }
        while out.hasPrefix("…") { out.removeFirst() }
        while out.hasSuffix("...") { out.removeLast(3) }
        while out.hasPrefix("...") { out.removeFirst(3) }
        return out
    }

    /// Lowercased, whitespace-collapsed form for prefix/suffix comparison. Punctuation
    /// is preserved so the mid-word check can see the character that continues a word.
    private static func normalizedForTruncation(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Representative

    private static func representative(of members: [AnchoredDetection]) -> MergedDetection {
        // Highest confidence wins the title; deterministic tie-break by id.
        let ordered = members.sorted { $0.detection.confidence != $1.detection.confidence
            ? $0.detection.confidence > $1.detection.confidence
            : $0.id < $1.id }
        // The complete read must win the title, even if an edge-cut fragment scored
        // higher: a member that carries an ellipsis marker or is a prefix/suffix of a
        // sibling is a truncation. Pick the representative from the complete members
        // (highest-confidence among them); fall back to `ordered` if all are truncated.
        func isTruncated(_ member: AnchoredDetection) -> Bool {
            if hasEllipsisMarker(member.printedTitle) { return true }
            return members.contains { other in
                other.id != member.id && isTruncation(of: other.printedTitle, fragment: member.printedTitle)
            }
        }
        let complete = ordered.filter { !isTruncated($0) }
        let rep = complete.first ?? ordered[0]
        // Prefer a non-nil platform (serial-derived preferred), union edition hints.
        let platform = ordered.compactMap { $0.platform }.first
        let serial = ordered.compactMap { $0.serialCode }.first
        var hints: [String] = []
        for member in ordered {
            for hint in member.detection.editionHints where !hints.contains(hint) { hints.append(hint) }
        }
        let isCompilation = ordered.contains { $0.detection.isCompilation }
        let normalized = ordered.compactMap { $0.detection.normalizedTitle }.first
        return MergedDetection(
            id: rep.id,
            printedTitle: rep.printedTitle,
            normalizedTitle: normalized,
            platform: platform,
            editionHints: hints,
            isCompilation: isCompilation,
            confidence: rep.detection.confidence,
            sourceRect: rep.sourceRect,
            tileID: rep.tileID,
            serialCode: serial,
            memberCount: members.count
        )
    }
}
