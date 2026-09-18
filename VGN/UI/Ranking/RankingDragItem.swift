import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A private drag payload carrying the game ids being dragged on the Tier Board
/// / The Top (PLAN §2 — reordering on macOS 15 is `draggable` / `dropDestination`
/// with a `Transferable`). Ids only: the drop target already has the board model,
/// so nothing heavier needs to cross the pasteboard, and the custom UTType keeps
/// these drags from being mistaken for text or accepted by other apps.
struct RankingDragItem: Codable, Transferable, Hashable, Sendable {
    /// The dragged game ids, in the order they should keep relative to each other.
    var gameIDs: [Int64]
    /// The tier the drag originated from (so a within-tier reorder can do the
    /// forward/backward index correction without re-searching the board).
    var sourceTierID: Int64?

    init(gameIDs: [Int64], sourceTierID: Int64? = nil) {
        self.gameIDs = gameIDs
        self.sourceTierID = sourceTierID
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .vgnRankingItem)
    }
}

extension UTType {
    /// Private, in-app-only drag type for ranking tiles / rows.
    static let vgnRankingItem = UTType(exportedAs: "com.videogamenerd.ranking-item")
}
