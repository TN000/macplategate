import Foundation

/// Tiny counting gate for OCR workers with runtime-adjustable maximum.
///
/// `DispatchSemaphore` cannot safely change its capacity while workers are in
/// flight. This gate keeps only an in-flight counter, so callers can pass a new
/// `maxConcurrent` on every tick without leaking permits.
final class AdaptiveConcurrencyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Int = 0

    func tryAcquire(maxConcurrent: Int) -> Bool {
        let limit = max(1, maxConcurrent)
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    func release() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        inFlight = 0
        lock.unlock()
    }

    var currentInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }
}
