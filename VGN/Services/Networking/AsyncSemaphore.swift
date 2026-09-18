import Foundation

/// A cancellation-aware counting semaphore for bounding concurrency (PLAN §9:
/// `CoverStore` caps downloads at ≤ 6). Waiters that are cancelled while suspended
/// throw `CancellationError` and do not consume a permit.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    init(permits: Int) {
        precondition(permits >= 0)
        self.permits = permits
    }

    /// Acquire one permit, suspending if none is free.
    func acquire() async throws {
        if permits > 0 {
            permits -= 1
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Release one permit, resuming the oldest waiter if any.
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            permits += 1
        }
    }

    /// Run `body` while holding one permit. Releases on success, throw, or cancel.
    func withPermit<T: Sendable>(_ body: sending () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
