import Foundation

// MARK: - Effective play time (PLAN §7b "Scheduled 2026-09-25", v17)

extension LibraryQuery {

    /// The ONE SQL fragment for a game's **effective play time**: the owner's manual
    /// `my_playtime_s` when set, else the larger of the two imported times
    /// (`psn_playtime_s`, `batocera_playtime_s`) — they measure the same act on different
    /// machines, so they are **never summed**. NULL when none is known.
    ///
    /// SQLite's scalar `MAX(a, b)` is NULL as soon as one argument is NULL, hence the two
    /// trailing fallbacks. Every reader of play time uses this (grid sort / playtime filter,
    /// Stats, Play Next remaining time, the CSV export); ``EffectivePlaytime`` is its pure
    /// Swift mirror (parity-tested).
    ///
    /// - Parameter alias: the `games` table alias (`"g"`), or `nil` for bare column names.
    static func effectivePlaytimeSQL(alias: String? = "g") -> String {
        let p = alias.map { "\($0)." } ?? ""
        return "COALESCE(\(p)my_playtime_s, MAX(\(p)psn_playtime_s, \(p)batocera_playtime_s), "
            + "\(p)psn_playtime_s, \(p)batocera_playtime_s)"
    }
}
