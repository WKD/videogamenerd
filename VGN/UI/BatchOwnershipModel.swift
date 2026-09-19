import Foundation
import Observation

/// One game's row in the ask-once "Mark Owned" batch sheet (PLAN §8): a game that
/// is not yet owned and will get one physical/digital/ROM copy on `platformID`.
struct BatchOwnershipRow: Identifiable, Equatable, Sendable {
    var gameID: Int64
    var title: String
    /// The game's own platforms (the picker choices for this row).
    var platformOptions: [String]
    /// The platform the copy will land on (default = the primary platform).
    var platformID: String

    var id: Int64 { gameID }
    /// More than one platform → the owner should confirm which copy to add.
    var isAmbiguous: Bool { platformOptions.count > 1 }
}

/// Where the batch sheet's sticky **format** lives (default of the format picker),
/// injected so tests can assert persistence without touching real `UserDefaults`.
protocol BatchOwnershipPreferenceStoring: Sendable {
    func loadFormat() -> ProductFormat
    func saveFormat(_ format: ProductFormat)
}

/// `AppPreferences.defaults`-backed sticky format (never raw `UserDefaults.standard`
/// — that would be the owner's real prefs under the test host).
struct UserDefaultsBatchOwnershipPreferences: BatchOwnershipPreferenceStoring {
    nonisolated(unsafe) let defaults: UserDefaults
    private let formatKey = "VGNBatchOwned.format"

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

    func loadFormat() -> ProductFormat {
        guard let raw = defaults.string(forKey: formatKey),
              let format = ProductFormat(rawValue: raw) else { return .physical }
        return format
    }
    func saveFormat(_ format: ProductFormat) { defaults.set(format.rawValue, forKey: formatKey) }
}

/// In-memory format store for tests/previews.
final class InMemoryBatchOwnershipPreferences: BatchOwnershipPreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var format: ProductFormat
    init(_ format: ProductFormat = .physical) { self.format = format }
    func loadFormat() -> ProductFormat { lock.withLock { format } }
    func saveFormat(_ format: ProductFormat) { lock.withLock { self.format = format } }
}

/// The decision model behind the ask-once "Mark N Games as Owned" sheet (owner
/// decision 2026-09-19; PLAN §8). Pure and window-free: it takes the selected
/// games, works out which are **already owned** (skipped, only counted), which
/// have **no platform** (can't be owned, skipped), and which are **pending**
/// (ambiguous ones — several platforms — first, so the owner can fix them). The
/// format picker applies to the whole batch and its choice persists.
///
/// Confirming resolves one ``BatchCopySpec`` per pending row and hands them to
/// ``LibraryActions`` for a single-transaction write.
@MainActor
@Observable
final class BatchOwnershipModel: Identifiable {
    let id = UUID()

    /// Pending rows (not owned, has a platform), ambiguous ones first.
    private(set) var rows: [BatchOwnershipRow]
    /// Selected games that were already owned (unchanged, only reported).
    let alreadyOwnedCount: Int
    /// Selected games with no platform at all (can't add a copy, skipped).
    let noPlatformCount: Int

    /// The batch's format (segmented picker). Persisted on confirm.
    var format: ProductFormat

    private let allPlatforms: [PlatformInfo]
    private let prefs: any BatchOwnershipPreferenceStoring
    private let onConfirm: ([BatchCopySpec]) -> Void

    init(
        games: [GameSummary],
        allPlatforms: [PlatformInfo],
        preferences: any BatchOwnershipPreferenceStoring = UserDefaultsBatchOwnershipPreferences(),
        onConfirm: @escaping ([BatchCopySpec]) -> Void
    ) {
        self.allPlatforms = allPlatforms
        self.prefs = preferences
        self.onConfirm = onConfirm
        self.format = preferences.loadFormat()
        self.alreadyOwnedCount = games.filter(\.owned).count
        self.noPlatformCount = games.filter { !$0.owned && $0.platformIDs.isEmpty }.count

        // Pending = not owned and has at least one platform; ambiguous first,
        // otherwise stable (a game's own selection order is preserved).
        let pending = games.filter { !$0.owned && !$0.platformIDs.isEmpty }
        self.rows = pending
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.platformIDs.count > 1
                let r = rhs.element.platformIDs.count > 1
                if l != r { return l && !r }
                return lhs.offset < rhs.offset
            }
            .map { _, game in
                BatchOwnershipRow(gameID: game.id, title: game.title,
                                  platformOptions: game.platformIDs,
                                  platformID: game.platformIDs.first ?? "")
            }
    }

    // MARK: Presentation

    var title: String { "Mark ^[\(rows.count) Game](inflect: true) as Owned" }
    var ambiguousRows: [BatchOwnershipRow] { rows.filter(\.isAmbiguous) }
    var simpleRows: [BatchOwnershipRow] { rows.filter { !$0.isAmbiguous } }
    var canConfirm: Bool { rows.contains { !$0.platformID.isEmpty } }

    /// Whether this batch actually needs the sheet — false ⇒ the caller shows a
    /// banner (all already owned / nothing to do) instead of an empty sheet.
    static func hasPendingGames(_ games: [GameSummary]) -> Bool {
        games.contains { !$0.owned && !$0.platformIDs.isEmpty }
    }

    /// A platform's display name (catalog first, then the bundled labels, then the
    /// slug itself as a last resort).
    func platformName(_ slug: String) -> String {
        allPlatforms.first { $0.id == slug }?.name
            ?? PlatformLabels.info(slug)?.name
            ?? slug
    }

    /// The `PlatformInfo`s a row's popup offers (its own platforms).
    func options(for row: BatchOwnershipRow) -> [PlatformInfo] {
        row.platformOptions.map { slug in
            allPlatforms.first { $0.id == slug }
                ?? PlatformLabels.info(slug)
                ?? PlatformInfo(id: slug, name: slug, short: slug, manufacturer: "", kind: .console)
        }
    }

    // MARK: Mutation (only from the sheet's controls — never a body)

    func setPlatform(_ platformID: String, for gameID: Int64) {
        guard let i = rows.firstIndex(where: { $0.gameID == gameID }) else { return }
        rows[i].platformID = platformID
    }

    /// One ``BatchCopySpec`` per pending row that has a platform.
    func resolvedSpecs() -> [BatchCopySpec] {
        rows.compactMap { row in
            row.platformID.isEmpty ? nil
                : BatchCopySpec(gameID: row.gameID, platformID: row.platformID, format: format)
        }
    }

    /// Persist the format and hand the resolved copies to the write side.
    func confirm() {
        prefs.saveFormat(format)
        onConfirm(resolvedSpecs())
    }
}
