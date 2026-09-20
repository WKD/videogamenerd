import Foundation

/// The two sources that feed **The Vault** (PLAN §16): the Batocera ROM set (§15) and the
/// barely-touched PS Plus games (§13). Both live in the same `rom_catalog` table, told apart
/// by its `source` column, so this raw value is exactly that column's value.
///
/// A plain `Sendable` value type (Foundation only) — the sidebar, the browser and the
/// "From the vault" row all key off it, and its `sidebarID` is the stable selection id.
enum VaultSource: String, Hashable, Sendable, Identifiable, CaseIterable {
    case batocera
    case psn
    /// A GOG game the owner sent to the Vault by hand (PLAN §16 "Send to the Vault") — really
    /// owned, browsable, suggested by "From the vault", but never a PS Plus subscription claim.
    case gog
    /// A Delicious Library game sent to the Vault by hand (PLAN §16).
    case delicious

    var id: String { rawValue }

    /// The `rom_catalog.source` column value for this source.
    var storage: String { rawValue }

    /// The sidebar row title under **THE VAULT** (PLAN §16).
    var rowTitle: String {
        switch self {
        case .batocera: return "Batocera ROMs"
        case .psn: return "PS Plus"
        case .gog: return "GOG"
        case .delicious: return "Delicious"
        }
    }

    /// The SF Symbol for the sidebar row.
    var icon: String {
        switch self {
        case .batocera: return "externaldrive"
        case .psn: return "playstation.logo"
        case .gog: return "g.circle"
        case .delicious: return "fork.knife"
        }
    }

    /// The stable sidebar selection id (`vault:batocera`, `vault:psn`, PLAN §16).
    var sidebarID: String { "vault:\(rawValue)" }

    /// Build a source from a `rom_catalog.source` value, or nil for an unknown source.
    init?(storage: String) { self.init(rawValue: storage) }
}

/// Present-entry counts for the two Vault sources (PLAN §16), produced by one observation so
/// the sidebar's two rows and their visibility never touch the library's counts stream.
struct VaultSourceCounts: Hashable, Sendable {
    var batocera: Int = 0
    var psn: Int = 0
    var gog: Int = 0
    var delicious: Int = 0

    /// The count for one source.
    func count(_ source: VaultSource) -> Int {
        switch source {
        case .batocera: return batocera
        case .psn: return psn
        case .gog: return gog
        case .delicious: return delicious
        }
    }

    /// Set the count for one source (from a `GROUP BY source` read).
    mutating func setCount(_ n: Int, for source: VaultSource) {
        switch source {
        case .batocera: batocera = n
        case .psn: psn = n
        case .gog: gog = n
        case .delicious: delicious = n
        }
    }

    /// Total across all sources.
    var total: Int { batocera + psn + gog + delicious }

    /// The sources with at least one present entry, in display order (PLAN §16 — a row is
    /// shown only when non-empty).
    var nonEmptySources: [VaultSource] {
        VaultSource.allCases.filter { count($0) > 0 }
    }
}
