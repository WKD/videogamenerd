import Foundation
@testable import VGN

// MARK: - Fixture loading

/// Anchors `Bundle(for:)` to the test target so flattened fixtures resolve by name.
private final class FixtureBundleToken {}

enum Fixtures {
    enum FixtureError: Error { case missing(String) }

    static func url(_ name: String) throws -> URL {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        guard let url = Bundle(for: FixtureBundleToken.self).url(forResource: base, withExtension: ext) else {
            throw FixtureError.missing(name)
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try url(name))
    }
}

// MARK: - HTTP transport stub

/// Deterministic `HTTPTransport` for tests: scripts responses per URL (with a default),
/// records every request, tracks peak concurrency, and can add a small delay so
/// concurrency caps are observable. Thread-safe.
final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String]
        init(status: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var byURLPrefix: [(prefix: String, stub: Stub)] = []
    private var defaultStub: Stub
    private var recordedRequests: [URLRequest] = []
    private var activeCount = 0
    private var peakConcurrency = 0
    private var errorFactory: (@Sendable () -> Error)?
    private let perRequestDelay: TimeInterval

    init(defaultStub: Stub = Stub(status: 200, body: Data("[]".utf8)), perRequestDelay: TimeInterval = 0) {
        self.defaultStub = defaultStub
        self.perRequestDelay = perRequestDelay
    }

    /// Make every subsequent request throw the error the factory produces (or clear it
    /// with `nil`). Simulates a cancelled / transient network op.
    func setThrow(_ factory: (@Sendable () -> Error)?) { lock.withLock { errorFactory = factory } }

    /// Route requests whose URL contains `prefix` to `stub`.
    func on(urlContains prefix: String, _ stub: Stub) {
        lock.withLock { byURLPrefix.append((prefix, stub)) }
    }

    func setDefault(_ stub: Stub) { lock.withLock { defaultStub = stub } }

    var requestCount: Int { lock.withLock { recordedRequests.count } }
    var maxConcurrency: Int { lock.withLock { peakConcurrency } }
    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var lastBody: String? {
        lock.withLock { recordedRequests.last?.httpBody.map { String(decoding: $0, as: UTF8.self) } }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let outcome: (stub: Stub, error: Error?) = lock.withLock {
            recordedRequests.append(request)
            activeCount += 1
            peakConcurrency = max(peakConcurrency, activeCount)
            let urlString = request.url?.absoluteString ?? ""
            let stub = byURLPrefix.first(where: { urlString.contains($0.prefix) })?.stub ?? defaultStub
            return (stub, errorFactory?())
        }
        if perRequestDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(perRequestDelay * 1_000_000_000))
        }
        lock.withLock { activeCount -= 1 }
        if let error = outcome.error { throw error }
        let stub = outcome.stub
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: stub.headers
        )!
        return (stub.body, http)
    }
}

// MARK: - Clocks

/// A clock whose `sleep` returns immediately but records the deadlines it was asked to
/// wait until — lets tests assert token-bucket / backoff timing without any real wait.
final class RecordingImmediateClock: ServiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private let fixedNow: TimeInterval
    private var _deadlines: [TimeInterval] = []

    init(now: TimeInterval = 0) { self.fixedNow = now }

    var now: TimeInterval { fixedNow }
    var deadlines: [TimeInterval] { lock.withLock { _deadlines } }

    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { _deadlines.append(deadline) }
    }
}

/// A controllable virtual clock: `sleep` parks until `advance` moves time past the
/// deadline (or the task is cancelled). No real time passes.
final class ManualClock: ServiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TimeInterval
    private var nextID: UInt64 = 0
    private var sleepers: [(id: UInt64, deadline: TimeInterval, cont: CheckedContinuation<Void, Error>)] = []

    init(now: TimeInterval = 0) { self._now = now }

    var now: TimeInterval { lock.withLock { _now } }
    var pendingCount: Int { lock.withLock { sleepers.count } }

    /// Suspend until `pendingCount` reaches `count` (a task has parked).
    func waitForSleepers(count: Int) async {
        while pendingCount < count { await Task.yield() }
    }

    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        let id: UInt64 = lock.withLock { let v = nextID; nextID += 1; return v }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if _now >= deadline {
                    lock.unlock()
                    cont.resume()
                } else {
                    sleepers.append((id, deadline, cont))
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        _now += delta
        let due = sleepers.filter { $0.deadline <= _now }
        sleepers.removeAll { $0.deadline <= _now }
        lock.unlock()
        for sleeper in due { sleeper.cont.resume() }
    }

    private func cancel(_ id: UInt64) {
        lock.lock()
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let sleeper = sleepers.remove(at: index)
        lock.unlock()
        sleeper.cont.resume(throwing: CancellationError())
    }
}

// MARK: - Misc

/// Thread-safe counter for asserting call counts from `@Sendable` closures.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}
