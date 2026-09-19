import Foundation
import GRDB

/// One product whose format was changed, kept so the batch is exactly reversible
/// (undo restores each product's previous format verbatim).
struct CopyFormatChange: Sendable, Equatable {
    var productID: Int64
    var previousFormat: ProductFormat
}

/// The outcome of a bulk "Change Copy Format" (PLAN §13.3 — "Physical or digital?").
struct ChangeCopyFormatResult: Sendable, Equatable {
    /// Games whose single owned copy was reformatted.
    var changed: Int = 0
    /// Games skipped because they own **several** non-subscription copies (ambiguous —
    /// which copy?), surfaced in the banner.
    var skipped: Int = 0
    /// The prior format of every product changed, for a single-step undo.
    var reverts: [CopyFormatChange] = []
}

extension LibraryStore {

    /// Bulk-set the ownership format of the selected games' copies (PLAN §13.3). Applies
    /// **only** to a game that owns exactly ONE non-subscription **single** copy (a PSN
    /// digital purchase the owner wants to reclassify as physical, etc.); a game with
    /// several such copies is ambiguous and is skipped (counted for the banner). A
    /// subscription (PS Plus) copy is never reformatted and never counts toward the "one
    /// copy" test — its format is meaningless. One transaction, one undo step; a copy that
    /// is already the target format is left untouched and not counted as changed.
    func changeCopyFormat(gameIDs: [Int64], to format: ProductFormat) async throws -> ChangeCopyFormatResult {
        guard !gameIDs.isEmpty else { return ChangeCopyFormatResult() }
        return try await dbWriter.write { db in
            var result = ChangeCopyFormatResult()
            let now = Date()
            for gameID in gameIDs {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.id AS pid, p.format AS format
                    FROM products p JOIN product_games pg ON pg.product_id = p.id
                    WHERE pg.game_id = ? AND p.subscription IS NULL AND p.kind = 'single'
                    """, arguments: [gameID])
                if rows.count >= 2 {
                    result.skipped += 1
                    continue
                }
                guard rows.count == 1 else { continue }        // 0 copies → nothing to do
                let pid: Int64 = rows[0]["pid"]
                let old = ProductFormat(rawValue: rows[0]["format"]) ?? .physical
                guard old != format else { continue }          // already that format
                try db.execute(sql: "UPDATE products SET format = ?, updated_at = ? WHERE id = ?",
                               arguments: [format.rawValue, now, pid])
                result.reverts.append(CopyFormatChange(productID: pid, previousFormat: old))
                result.changed += 1
            }
            return result
        }
    }

    /// Restore each product's format to the given value (the inverse of a
    /// ``changeCopyFormat(gameIDs:to:)`` batch — one transaction, for undo/redo).
    func restoreCopyFormats(_ changes: [CopyFormatChange]) async throws {
        guard !changes.isEmpty else { return }
        try await dbWriter.write { db in
            let now = Date()
            for change in changes {
                try db.execute(sql: "UPDATE products SET format = ?, updated_at = ? WHERE id = ?",
                               arguments: [change.previousFormat.rawValue, now, change.productID])
            }
        }
    }
}
