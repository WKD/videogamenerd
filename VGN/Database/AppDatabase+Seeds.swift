import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Platform seeding

    /// Upsert every platform from the shared ``PlatformCatalogEntry`` model
    /// (decoded from `platforms.json`, PLAN §5.6).
    ///
    /// Runs on every launch so editing the JSON updates names/short/group/sort
    /// without a migration. Never deletes a platform — in particular one that
    /// still has games — it only inserts new rows and refreshes existing ones.
    /// Idempotent.
    @discardableResult
    func seedPlatforms(from entries: [PlatformCatalogEntry]) async throws -> Int {
        try await dbWriter.write { db in
            var inserted = 0
            for entry in entries {
                let igdbJSON = String(
                    data: (try? JSONEncoder().encode(entry.igdbIDs)) ?? Data("[]".utf8),
                    encoding: .utf8
                ) ?? "[]"
                let record = PlatformRecord(
                    id: entry.id,
                    name: entry.name,
                    short: entry.short,
                    manufacturer: entry.manufacturer,
                    group: entry.group,
                    kind: entry.kind,
                    generation: entry.generation,
                    igdbIDsJSON: igdbJSON,
                    libretroRepo: entry.libretroRepo,
                    sort: entry.sort
                )
                let existed = try PlatformRecord.exists(db, key: entry.id)
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
        do {
            return try await seedPlatforms(from: PlatformCatalog.entriesFromBundle(bundle))
        } catch PlatformCatalog.LoadError.resourceMissing {
            throw AppDatabaseError.resourceMissing("platforms.json")
        }
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
