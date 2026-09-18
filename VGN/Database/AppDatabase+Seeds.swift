import Foundation
import GRDB

/// The Codable shape of one entry in `Resources/platforms.json` (EXECUTION
/// contract): `id, name, short, manufacturer, group, kind, generation?,
/// igdbIDs, libretroRepo?, sort`.
struct PlatformSeed: Codable, Sendable {
    var id: String
    var name: String
    var short: String
    var manufacturer: String
    var group: String
    var kind: String
    var generation: Int?
    var igdbIDs: [Int]
    var libretroRepo: String?
    var sort: Int
}

extension AppDatabase {
    // MARK: - Platform seeding

    /// Upsert every platform from the decoded `platforms.json` (PLAN §5.6).
    ///
    /// Runs on every launch so editing the JSON updates names/short/group/sort
    /// without a migration. Never deletes a platform — in particular one that
    /// still has games — it only inserts new rows and refreshes existing ones.
    /// Idempotent.
    @discardableResult
    func seedPlatforms(from seeds: [PlatformSeed]) async throws -> Int {
        try await dbWriter.write { db in
            var inserted = 0
            for seed in seeds {
                let igdbJSON = String(
                    data: (try? JSONEncoder().encode(seed.igdbIDs)) ?? Data("[]".utf8),
                    encoding: .utf8
                ) ?? "[]"
                let record = PlatformRecord(
                    id: seed.id,
                    name: seed.name,
                    short: seed.short,
                    manufacturer: seed.manufacturer,
                    group: seed.group,
                    kind: seed.kind,
                    generation: seed.generation,
                    igdbIDsJSON: igdbJSON,
                    libretroRepo: seed.libretroRepo,
                    sort: seed.sort
                )
                let existed = try PlatformRecord.exists(db, key: seed.id)
                // save() = insert or update on the primary key. Preserves games.
                try record.save(db)
                if !existed { inserted += 1 }
            }
            return inserted
        }
    }

    /// Convenience: decode the bundled `platforms.json` and upsert it. The app
    /// calls this at start-up. Bundle resources are flattened, so the file is at
    /// the bundle root.
    @discardableResult
    func seedPlatformsFromBundle(_ bundle: Bundle = .main) async throws -> Int {
        guard let url = bundle.url(forResource: "platforms", withExtension: "json") else {
            throw AppDatabaseError.resourceMissing("platforms.json")
        }
        let data = try Data(contentsOf: url)
        let seeds = try JSONDecoder().decode([PlatformSeed].self, from: data)
        return try await seedPlatforms(from: seeds)
    }

    /// Re-apply the default tier ladder if it is missing (idempotent). Tiers are
    /// normally seeded inside migration v1; this exists for callers that build a
    /// writer some other way.
    func seedTiersIfNeeded() async throws {
        try await dbWriter.write { db in
            try Migrations.seedTiers(db)
        }
    }
}

/// Errors surfaced by the database layer.
enum AppDatabaseError: Error, Sendable, Equatable {
    case resourceMissing(String)
}
