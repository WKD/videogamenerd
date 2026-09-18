import Foundation

/// A compact, persisted set of the field names a user has **manually edited** on a
/// game (PLAN §7b enrichment request: "refresh untouched fields while protecting
/// edited ones"). Stored in `games.user_edited` as a comma-separated string, e.g.
/// `"cover,summary"`. An edited field is never overwritten by background
/// enrichment — not even by an explicit `refresh(gameID:)`.
///
/// Pure value type (Foundation only): the DB reads/writes the `raw` string, the
/// enrichment guard tests membership, and `LibraryStore` writes that represent a
/// user edit add the relevant field.
struct UserEditedFields: Hashable, Sendable, Codable {
    private var fields: Set<String>

    init() { fields = [] }

    /// Parse the stored `games.user_edited` string (comma-separated, order- and
    /// whitespace-insensitive). Empty/blank entries are ignored.
    init(raw: String) {
        fields = Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    init<S: Sequence>(_ names: S) where S.Element == String {
        fields = Set(names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// The canonical stored form: names sorted for stability, comma-joined.
    var raw: String { fields.sorted().joined(separator: ",") }

    var isEmpty: Bool { fields.isEmpty }

    func contains(_ field: Field) -> Bool { fields.contains(field.rawValue) }
    func contains(_ name: String) -> Bool { fields.contains(name) }

    /// A copy with `field` marked edited.
    func inserting(_ field: Field) -> UserEditedFields {
        var copy = self
        copy.fields.insert(field.rawValue)
        return copy
    }

    /// A copy with `field` cleared (an edit reverted / re-synced from IGDB).
    func removing(_ field: Field) -> UserEditedFields {
        var copy = self
        copy.fields.remove(field.rawValue)
        return copy
    }

    /// The known, guardable field names. String-backed so unknown names round-trip
    /// harmlessly, but the guard and the write sites use these constants.
    enum Field: String, CaseIterable, Sendable {
        case title
        case year          // covers release_date + year
        case summary
        case genres
        case cover         // manual cover import / choose-cover (protects cover_file + igdb_cover_image_id)
        case altTitles = "alt_titles"
        case traits
        case rating
    }
}
