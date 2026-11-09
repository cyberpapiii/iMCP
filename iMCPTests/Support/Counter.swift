import Foundation

/// A call count that synchronous callbacks, tasks, and the test can all
/// touch without awaiting.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the count including this call.
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}
