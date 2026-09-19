import Foundation

/// Typed failures for reading a `.deliciouslibrary2` store (PLAN §5.5 — a file import
/// stops-and-reports on anything it does not understand, never guesses). User-facing
/// `message`s are safe to show; they never quote the file's private contents.
enum DeliciousImportError: Error, Sendable, Equatable {
    /// The picked file is not a Delicious Library store at all (expected Core Data
    /// tables absent).
    case notDeliciousFile
    /// The store is a Delicious Library file but its schema is not the DL2 shape this
    /// reader understands (missing `Medium` entity / expected columns).
    case unsupportedVersion
    /// A valid DL2 store with zero `VideoGame` items — nothing to import.
    case noVideoGames
    /// The file could not be opened (permissions, corruption).
    case cannotOpen(String)

    var message: String {
        switch self {
        case .notDeliciousFile:
            return "This file is not a Delicious Library database."
        case .unsupportedVersion:
            return "This Delicious Library file is in a format Video Game Nerd doesn't understand."
        case .noVideoGames:
            return "This Delicious Library has no video games in it."
        case .cannotOpen(let detail):
            return "The Delicious Library file couldn't be opened. \(detail)"
        }
    }
}
