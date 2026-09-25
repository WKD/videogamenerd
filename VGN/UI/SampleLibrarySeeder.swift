import Foundation

/// Seeds a throwaway in-memory database with a small, representative library
/// **through ``LibraryStore`` writes** (never by touching the schema directly),
/// so the `-VGNSampleData YES` launch mode exercises the real add/own/play/tier
/// paths. Also used by tests. Not DEBUG-gated so demos work in any build.
enum SampleLibrarySeeder {

    /// The sample games as store drafts. Tier ids match the migration's ladder
    /// (S = 1 … F = 6). A tier implies played; `owned` creates a single copy.
    static var drafts: [GameDraft] {
        [
            GameDraft(title: "Bloodborne", year: 2015, platformIDs: ["ps4"],
                      owned: true, played: true, tierID: 1, status: .completed),
            GameDraft(title: "Elden Ring", year: 2022, platformIDs: ["ps5", "ps4"],
                      owned: true, played: true, tierID: 1, status: .finished),
            GameDraft(title: "Metal Gear Solid 3: Snake Eater", year: 2004, platformIDs: ["ps2"],
                      owned: true, played: true, tierID: 2, status: .finished),
            GameDraft(title: "Hollow Knight", year: 2017, platformIDs: ["pc"],
                      owned: false, played: true, tierID: 2),
            GameDraft(title: "Broken Sword", year: 1996, platformIDs: ["pc"],
                      owned: false, played: true),
            GameDraft(title: "Chrono Trigger", year: 1995, platformIDs: ["snes"],
                      owned: true, played: true, tierID: 1, status: .completed),
            GameDraft(title: "Hollow Knight: Silksong", year: 2025, platformIDs: ["ps5"],
                      owned: true, played: false),
            GameDraft(title: "Shadow of the Colossus", year: 2005, platformIDs: ["ps2"],
                      owned: true, played: true, tierID: 2),
            GameDraft(title: "Disco Elysium", year: 2019, platformIDs: ["pc"],
                      owned: true, played: false),
        ]
    }

    /// The sample "Holds up today?" marks, by title (played games only).
    static let sampleHoldsUp: [(String, HoldsUp)] = [
        ("Bloodborne", .holdsUp),
        ("Chrono Trigger", .holdsUp),
        ("Broken Sword", .ofItsTime),
        ("Metal Gear Solid 3: Snake Eater", .ofItsTime),
    ]

    /// Sample time-to-beat estimates (hours: hastily / normally / completely), by title, for
    /// the owned, unplayed backlog — so sample mode's Play Next has measured candidates and
    /// shows a hero pick (with no estimate every candidate sits in the unknown-length lane
    /// and the page shows its empty state). Rough public averages, written as `igdb` times
    /// through the ordinary enrichment write path.
    static let sampleTimeToBeat: [(String, hastily: Int, normally: Int, completely: Int)] = [
        ("Disco Elysium", 21, 32, 45),
        ("Hollow Knight: Silksong", 25, 35, 55),
        ("Metal Gear Solid 4: Guns of the Patriots", 17, 22, 40),
    ]

    /// The compilation used to demonstrate all-or-nothing ownership (PLAN §8).
    static var compilation: (product: ProductDraft, members: [CompilationMemberDraft]) {
        (
            ProductDraft(title: "Metal Gear Solid: The Legacy Collection", platformID: "ps3"),
            [
                CompilationMemberDraft(title: "Metal Gear Solid 2: Sons of Liberty",
                                       year: 2001, played: true, position: 0),
                CompilationMemberDraft(title: "Metal Gear Solid 4: Guns of the Patriots",
                                       year: 2008, played: false, position: 1),
            ]
        )
    }

    static func seed(into store: LibraryStore) async {
        do {
            let outcomes = try await store.addGames(drafts)
            // A few "Holds up today?" marks (PLAN §7b) so the demo shows every state; the
            // other played games stay Unrated and fill the "Needs a 'Holds Up' Rating" list.
            let ids = Dictionary(zip(drafts.map(\.title), outcomes.map(\.gameID)),
                                 uniquingKeysWith: { a, _ in a })
            for (title, mark) in sampleHoldsUp {
                if let id = ids[title] { try await store.setHoldsUp(mark, for: [id]) }
            }
            let comp = compilation
            let added = try await store.addCompilation(product: comp.product, members: comp.members)
            var allIDs = ids
            for (member, outcome) in zip(comp.members, added.members) {
                allIDs[member.title] = outcome.gameID
            }
            for (title, h, n, c) in sampleTimeToBeat {
                guard let id = allIDs[title] else { continue }
                try await store.updateMetadata(gameID: id, MetadataPatch(
                    ttbHastilyS: h * 3600, ttbNormallyS: n * 3600, ttbCompletelyS: c * 3600,
                    ttbSource: "igdb"))
            }
        } catch {
            NSLog("VGN: sample library seed failed: \(error)")
        }
    }
}
