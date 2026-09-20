import Foundation
import GRDB
@testable import VGN

/// Shared helpers for the Database test suite: an in-memory ``AppDatabase`` with
/// a small, known platform set seeded, plus a ``LibraryStore`` over it.
enum TestDB {
    /// A fixed platform set covering the manufacturers the tests touch.
    static let platforms: [PlatformCatalogEntry] = [
        .init(id: "ps5", name: "PlayStation 5", short: "PS5",
              manufacturer: "Sony", group: "Sony", kind: "console",
              generation: 9, igdbIDs: [167], libretroRepo: nil, sort: 10),
        .init(id: "ps4", name: "PlayStation 4", short: "PS4",
              manufacturer: "Sony", group: "Sony", kind: "console",
              generation: 8, igdbIDs: [48], libretroRepo: nil, sort: 20),
        .init(id: "ps3", name: "PlayStation 3", short: "PS3",
              manufacturer: "Sony", group: "Sony", kind: "console",
              generation: 7, igdbIDs: [9], libretroRepo: "Sony_-_PlayStation_3", sort: 30),
        .init(id: "ps2", name: "PlayStation 2", short: "PS2",
              manufacturer: "Sony", group: "Sony", kind: "console",
              generation: 6, igdbIDs: [8], libretroRepo: "Sony_-_PlayStation_2", sort: 40),
        .init(id: "snes", name: "Super Nintendo", short: "SNES",
              manufacturer: "Nintendo", group: "Nintendo", kind: "console",
              generation: 4, igdbIDs: [19], libretroRepo: "Nintendo_-_SNES", sort: 50),
        .init(id: "pc", name: "PC (Windows)", short: "PC",
              manufacturer: "Microsoft", group: "Computer", kind: "computer",
              generation: nil, igdbIDs: [6], libretroRepo: nil, sort: 10),
    ]

    /// A migrated, in-memory database with the test platforms seeded.
    static func makeSeeded() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try await db.seedPlatforms(from: platforms)
        return db
    }

    /// A ``LibraryStore`` over a freshly seeded in-memory database.
    static func makeStore() async throws -> LibraryStore {
        LibraryStore(try await makeSeeded())
    }
}
