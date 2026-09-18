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
            _ = try await store.addGames(drafts)
            let comp = compilation
            _ = try await store.addCompilation(product: comp.product, members: comp.members)
        } catch {
            NSLog("VGN: sample library seed failed: \(error)")
        }
    }
}
