import Foundation
import CoreGraphics

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
            isConfident: true,
            region: nil,
            kind: "cover",
            pixelSize: Self.pixelSize(for: size)
        )]
    }

    /// Fixed pixel dimensions of IGDB's named cover sizes, so the "Choose Cover…"
    /// sheet can label the tile before the image is fetched. `nil` for non-cover
    /// tokens whose dimensions vary.
    static func pixelSize(for size: IGDBImageSize) -> CGSize? {
        switch size {
        case .coverSmall: return CGSize(width: 90, height: 128)
        case .coverBig: return CGSize(width: 264, height: 374)
        case .coverBig2x: return CGSize(width: 528, height: 748)
        case .thumb: return CGSize(width: 90, height: 90)
        default: return nil
        }
    }
}
