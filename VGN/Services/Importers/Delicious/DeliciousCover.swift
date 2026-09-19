import Foundation
import ImageIO

/// Delicious box-art covers (PLAN §5.5). The blobs in the store are plain JPEG
/// (`ZLAZYCOVERIMAGEDATA.ZCOMPRESSEDIMAGEDATA`), so they decode straight through ImageIO.
enum DeliciousCover {
    /// Whether `data` is an image ImageIO can decode (a cheap header check).
    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

/// Applies a Delicious store's own covers to imported games that ended up without one —
/// live only, after commit. Uses the same file path a user-dropped image takes
/// (`CoverStore.importCover`) but records the cover **without** the user-chosen marker
/// (``LibraryStore/setImportedCoverIfEmpty``), so enrichment may still upgrade it later.
struct DeliciousCoverApplier: Sendable {
    let reader: DeliciousLibraryReader
    let store: LibraryStore
    let coverStore: CoverStore

    /// Fill covers for the games just imported (by row id) that have none. Best-effort:
    /// any read/decode/write failure is skipped silently — a missing cover is never fatal.
    func apply(affectedGameIDs: [Int64]) async {
        let targets = (try? await store.coverFallbackTargets(
            gameIDs: affectedGameIDs, source: ImportSourceID.delicious)) ?? []
        guard !targets.isEmpty else { return }

        // uuid → coverImagePK, from a fresh read of the file.
        guard let games = try? reader.readGames() else { return }
        let coverPKByUUID = Dictionary(games.compactMap { g in g.coverImagePK.map { (g.uuid, $0) } },
                                       uniquingKeysWith: { a, _ in a })
        let neededPKs = targets.compactMap { coverPKByUUID[$0.externalID] }
        guard let blobs = try? reader.coverJPEGData(forCoverImagePKs: neededPKs), !blobs.isEmpty else { return }

        for target in targets {
            guard let pk = coverPKByUUID[target.externalID],
                  let data = blobs[pk], DeliciousCover.isDecodableImage(data) else { continue }
            guard let temp = writeTemp(data) else { continue }
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let stored = try await coverStore.importCover(from: temp, gameID: target.gameID)
                try await store.setImportedCoverIfEmpty(gameID: target.gameID, coverFile: stored.coverFile)
            } catch { continue }
        }
    }

    private func writeTemp(_ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-cover-\(UUID().uuidString).jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }
}
