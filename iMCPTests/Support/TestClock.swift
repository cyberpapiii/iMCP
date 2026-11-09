import Foundation

@testable import iMCP

/// Time that moves only when a test says so, through `wallClock`. Its users
/// are `ICloudSession`, `LocationWindowModel`, `NetworkDiscoveryManager`,
/// `ConnectionApprovalPresenter`, and `ServerNetworkManager`'s setup
/// deadline. Work scheduled on it runs on `advance(by:)`, followed by the
/// owner's `settle()` where it has one (`ICloudSession`,
/// `LocationWindowModel`, `LocationSampler`, `NetworkDiscoveryManager`,
/// `ServerController`, `AppStatusModel`), so a test can say exactly what has
/// happened by a given moment, and what has not. `PairedClientStore` has a
/// `settle()` too, for the reload and outcome that follow a pairing.
///
/// This is the one list of both; AGENTS.md points here.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var networkWaitCount = 0

    init(start: Date = Date()) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    /// How many times the session waited for the network.
    var networkWaits: Int { lock.withLock { networkWaitCount } }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current = current.addingTimeInterval(seconds)
            let ready = sleepers.filter { $0.value.deadline <= current }
            ready.keys.forEach { sleepers[$0] = nil }
            return ready.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    func advance(by duration: Duration) {
        let (seconds, attoseconds) = duration.components
        advance(by: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if deadline <= current || Task.isCancelled { return true }
                    sleepers[id] = (deadline, continuation)
                    return false
                }
                guard resumeNow else { return }
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    var wallClock: WallClock {
        WallClock(
            now: { [self] in now },
            sleepUntil: { [self] deadline in try await sleep(until: deadline) }
        )
    }

    /// Stands in for the session's wait for a network path, and counts it.
    func waitForNetwork() {
        lock.withLock { networkWaitCount += 1 }
    }
}
