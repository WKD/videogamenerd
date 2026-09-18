import Foundation

/// IGDB cover provider (PLAN §5.2, source 2): the always-available fallback. Turns the
/// game's IGDB cover `image_id` into a single, exact key-art candidate. No network
/// call — the image id already came from the IGDB metadata fetch.
struct IGDBCoverProvider: CoverProvider {
    let id = "igdb"
    private let size: IGDBImageSize

    init(size: IGDBImageSize = .coverBig2x) {
        self.size = size
    }

    func candidates(for query: CoverQuery) async -> [CoverCandidate] {
        guard let imageID = query.igdbCoverImageID,
              let url = IGDBImageURL.cover(imageID: imageID, size: size)
        else { return [] }
        return [CoverCandidate(
            providerID: id,
            remoteURL: url,
            label: "IGDB cover",
            score: 1.0,          // exact key art for this game
            isConfident: true
        )]
    }
}
