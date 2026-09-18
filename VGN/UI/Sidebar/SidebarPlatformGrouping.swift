import Foundation

/// Pure grouping/sorting of the sidebar's PLATFORMS section (PLAN §8, §5.6):
/// group by `PlatformInfo.group`, sort ascending by `sort` within a group,
/// hide platforms with no games and hide groups left empty, and order the
/// groups in a stable manufacturer order. Kept free of SwiftUI so it can be
/// unit-tested directly.
enum SidebarPlatformGrouping {
    /// Canonical section order (PLAN §5.6). Unknown groups sort alphabetically
    /// after these.
    static let groupOrder = [
        "Sony", "Nintendo", "Sega", "Microsoft",
        "Atari", "NEC", "SNK", "Computer", "Arcade", "Other",
    ]

    struct Group: Identifiable, Hashable {
        let name: String
        let platforms: [PlatformInfo]
        var id: String { name }
    }

    /// Build the ordered, filtered groups. A platform is shown only when its
    /// count is ≥ 1; if counts haven't loaded yet (`perPlatform` empty) the
    /// supplied platforms are shown as-is (they're already the in-use set).
    static func groups(platforms: [PlatformInfo], counts: SidebarCounts) -> [Group] {
        let filterByCount = !counts.perPlatform.isEmpty
        let inUse = platforms.filter { p in
            filterByCount ? (counts.perPlatform[p.id] ?? 0) > 0 : true
        }
        let byGroup = Dictionary(grouping: inUse, by: \.group)

        var result: [Group] = []
        for name in groupOrder {
            if let ps = byGroup[name], !ps.isEmpty {
                result.append(Group(name: name, platforms: ps.sorted { $0.sort < $1.sort }))
            }
        }
        let known = Set(groupOrder)
        for name in byGroup.keys.filter({ !known.contains($0) }).sorted() {
            if let ps = byGroup[name], !ps.isEmpty {
                result.append(Group(name: name, platforms: ps.sorted { $0.sort < $1.sort }))
            }
        }
        return result
    }

    /// SF Symbol for a group header.
    static func icon(for group: String) -> String {
        switch group {
        case "Computer": return "desktopcomputer"
        case "Arcade": return "chair.lounge"
        default: return "gamecontroller"
        }
    }
}
