import Foundation

/// Pure, deterministic construction of the review sheet's rows and of the drafts a
/// commit inserts (PLAN §6.2 step 5). Foundation only, no I/O — trivially unit-tested.
enum PhotoScanReviewBuilder {

    // MARK: - Rows

    /// Build review rows from every scanned photo, collapsing cross-photo duplicates
    /// (the owner's frames overlap heavily: the same spine appears in several photos).
    /// Two detections collapse when they resolve to the same game **and** platform;
    /// a genuinely different platform/edition stays a separate row (two copies).
    static func rows(from results: [PhotoScanResult]) -> [ScanReviewRow] {
        var groups: [String: [ (photo: String, item: ScannedItem) ]] = [:]
        var order: [String] = []
        for result in results {
            for item in result.items {
                let key = collapseKey(for: item)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append((result.photo, item))
            }
        }

        var rows: [ScanReviewRow] = []
        for key in order {
            guard let members = groups[key], !members.isEmpty else { continue }
            rows.append(row(from: members))
        }
        // Group by bucket (confident → plausible → none), then by title within a bucket.
        return rows.sorted { lhs, rhs in
            if lhs.bucket.order != rhs.bucket.order { return lhs.bucket.order < rhs.bucket.order }
            let lt = (lhs.matchedTitle ?? lhs.printedTitle).lowercased()
            let rt = (rhs.matchedTitle ?? rhs.printedTitle).lowercased()
            if lt != rt { return lt < rt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The identity two detections must share to collapse: matched IGDB id (best) or a
    /// normalised printed title, plus the spine platform.
    static func collapseKey(for item: ScannedItem) -> String {
        let platform = item.platformSlug ?? "?"
        if let igdbID = item.match?.igdbID {
            return "igdb:\(igdbID)|\(platform)"
        }
        let title = TitleNormalizer.normalize(item.printedTitle, level: .articleless)
        return "title:\(title)|\(platform)"
    }

    private static func row(from members: [(photo: String, item: ScannedItem)]) -> ScanReviewRow {
        // Representative: the best-matched read (confident > plausible > none, then the
        // most confident recognition), so the strongest cover/title wins the row.
        let best = members.max { a, b in
            if a.item.matchBucket.order != b.item.matchBucket.order {
                return a.item.matchBucket.order > b.item.matchBucket.order   // lower order = better
            }
            return a.item.recognitionConfidence < b.item.recognitionConfidence
        }!
        let item = best.item
        let alreadyInLibrary = members.contains { $0.item.alreadyInLibrary }
        // De-duplicated, source order preserved.
        var seen: [String] = []
        for member in members where !seen.contains(member.photo) { seen.append(member.photo) }

        let defaultInclude = (item.matchBucket == .confident || item.matchBucket == .plausible) && !alreadyInLibrary
        return ScanReviewRow(
            id: UUID(),
            item: item,
            selectedMatch: item.match,
            alternatives: item.alternatives,
            bucket: item.matchBucket,
            include: defaultInclude,
            played: false,
            platformSlug: item.platformSlug ?? item.match?.platformSlugs.first,
            format: .physical,
            ignored: false,
            alreadyInLibrary: alreadyInLibrary,
            isCompilation: item.isCompilationGuess,
            seenInPhotos: seen
        )
    }

    // MARK: - Drafts

    /// The single-game draft for a committable, non-compilation row (owned ✓, physical
    /// by default, `source: .photo`, PLAN §6.2 step 5).
    static func gameDraft(for row: ScanReviewRow) -> GameDraft {
        let platformIDs = row.platformSlug.map { [$0] } ?? []
        return GameDraft(
            title: row.selectedMatch?.name ?? row.printedTitle,
            igdbID: row.selectedMatch?.igdbID,
            year: row.selectedMatch?.releaseYear,
            altTitles: altTitles(for: row),
            platformIDs: platformIDs,
            owned: !platformIDs.isEmpty,
            played: row.played,
            format: row.format,
            source: .photo
        )
    }

    /// The product side of a compilation row.
    static func productDraft(for row: ScanReviewRow) -> ProductDraft {
        ProductDraft(
            title: row.selectedMatch?.name ?? row.printedTitle,
            platformID: row.platformSlug ?? row.selectedMatch?.platformSlugs.first ?? "",
            format: row.format,
            source: .photo,
            igdbID: row.selectedMatch?.igdbID
        )
    }

    /// The member drafts for a compilation from its IGDB member list.
    static func memberDrafts(from members: [IGDBSearchResult], played: Bool) -> [CompilationMemberDraft] {
        members.enumerated().map { index, member in
            CompilationMemberDraft(
                title: member.name,
                igdbID: member.id,
                year: member.releaseYear,
                altTitles: member.alternativeNames,
                played: played,
                position: index
            )
        }
    }

    /// A `ScanMatch` from a user-picked IGDB search result, scored against the spine's
    /// printed title (so the row's bucket reflects the fuzzy quality).
    static func match(from result: IGDBSearchResult, query: String) -> ScanMatch {
        let names = [result.name] + result.alternativeNames
        var best = 0.0
        var bestName = result.name
        for name in names {
            let score = FuzzyMatch.score(query, name)
            if score > best { best = score; bestName = name }
        }
        return ScanMatch(
            igdbID: result.id,
            name: result.name,
            releaseYear: result.releaseYear,
            coverImageID: result.coverImageID,
            platformSlugs: result.platformSlugs,
            score: best,
            matchedName: bestName
        )
    }

    /// Alt titles carried onto the draft: the matched-name variant and the printed
    /// (French/edition) spine title, when they differ from the primary title.
    private static func altTitles(for row: ScanReviewRow) -> [String] {
        guard let match = row.selectedMatch else { return [] }
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.caseInsensitiveCompare(match.name) != .orderedSame,
                  !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            out.append(t)
        }
        add(match.matchedName)
        add(row.printedTitle)
        return out
    }
}
