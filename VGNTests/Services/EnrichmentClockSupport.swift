import Foundation

/// A wall-clock `Date` source tests move by hand (drives the job-store backoff and
/// the catalogue cache's staleness, which are Date-based, not the monotonic
/// `ServiceClock`). Thread-safe so it satisfies `Sendable` for `@Sendable` closures.
final class MutableDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.value = now }
    var now: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value += seconds } }
    func set(_ date: Date) { lock.withLock { value = date } }
}
