import Foundation

/// A hard per-sync request budget (PLAN §14.1 rule 2 / §13.1 rule 3). Each network
/// request consumes one unit; the moment the cap is reached ``consume()`` throws
/// ``ImportError/budgetExceeded(limit:)`` and the sync aborts — it never "just
/// continues". A plain value the serial client mutates in place, so it is fully
/// deterministic and unit-testable without any concurrency.
struct ImportRequestBudget: Sendable, Equatable {
    let limit: Int
    private(set) var used: Int = 0

    init(limit: Int) {
        precondition(limit >= 0)
        self.limit = limit
    }

    var remaining: Int { max(0, limit - used) }

    /// Consume one request. Throws once the budget is exhausted (before, not after,
    /// the request goes out).
    mutating func consume() throws {
        guard used < limit else { throw ImportError.budgetExceeded(limit: limit) }
        used += 1
    }
}
