import Foundation
import XCTest

/// Holds every caller of `wait()` until `open()`, so a test can stop work at
/// a chosen point and act while it is parked there.
///
/// `waitUntilWaiting(count:)` is how a test learns that work has reached the
/// gate, instead of polling or yielding in a loop. It fails the test if the
/// work does not get there within `CountLatch.deadline`.
actor AsyncGate {
    private var isOpen = false
    private var arrivals = 0
    private var parked: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let arrived = CountLatch()

    /// Returns when the gate opens, or as soon as the calling task is
    /// cancelled. A cancelled caller should check `Task.isCancelled` itself.
    func wait() async {
        arrivals += 1
        await arrived.reach(arrivals)
        guard !isOpen else { return }

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOpen || Task.isCancelled {
                    continuation.resume()
                } else {
                    parked[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    /// Returns once `count` calls to `wait()` have arrived, open or not.
    func waitUntilWaiting(count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        await arrived.wait(count: count, what: "calls to wait() arrived", file: file, line: line)
    }

    func open() {
        isOpen = true
        let continuations = parked.values
        parked.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func release(_ id: UUID) {
        parked.removeValue(forKey: id)?.resume()
    }
}
