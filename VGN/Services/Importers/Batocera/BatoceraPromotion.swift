import Foundation

/// The pure promotion rules that decide which catalogue ROMs become library games
/// (PLAN §15/§16). No I/O. A ROM is a promotion candidate when the box says the owner
/// **really played it** (> 10 min total) or marked it a **favourite**; `playcount` alone
/// never promotes (a launch that lasted seconds is a mistake, not a game they play).
enum BatoceraPromotion {

    /// The one threshold, now **The Vault's shared 10-minute gate** (PLAN §16, owner
    /// 2026-09-20 — this raised the earlier 5-minute rule). A total at or below this stays in
    /// the Vault whatever the play count.
    static let playedThresholdSeconds = ImportPolicy.vaultPlaytimeGateSeconds

    /// Whether a ROM counts as **played** for the library (strictly more than the gate).
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
