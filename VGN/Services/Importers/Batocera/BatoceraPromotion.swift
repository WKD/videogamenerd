import Foundation

/// The pure promotion rules that decide which catalogue ROMs become library games
/// (PLAN §15). No I/O. A ROM is a promotion candidate when the box says the owner
/// **really played it** (> 5 min total) or marked it a **favourite**; `playcount` alone
/// never promotes (a launch that lasted seconds is a mistake, not a game they play).
enum BatoceraPromotion {

    /// The one threshold (PLAN §15 — `gametime > 300 s`). A total below this stays in the
    /// catalogue whatever the play count.
    static let playedThresholdSeconds = 300

    /// Whether a ROM counts as **played** for the library (> 5 min).
    static func isPlayed(gameTimeSeconds: Int) -> Bool {
        gameTimeSeconds > playedThresholdSeconds
    }

    /// Whether a ROM is a promotion candidate: played, or a favourite.
    static func isCandidate(gameTimeSeconds: Int, isFavorite: Bool) -> Bool {
        isPlayed(gameTimeSeconds: gameTimeSeconds) || isFavorite
    }

    /// Convenience over a ``BatoceraGame``.
    static func isCandidate(_ game: BatoceraGame) -> Bool {
        isCandidate(gameTimeSeconds: game.gameTimeSeconds, isFavorite: game.isFavorite)
    }
}
