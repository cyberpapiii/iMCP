import Foundation
import XCTest

/// A count that tests wait on. A wait the count does not reach within
/// `deadline` fails its test and returns, so a hang costs seconds instead of
/// the CI job.
actor CountLatch {
    static let deadline: Duration = .seconds(5)

    private var value = 0
    private var waiting: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]

    /// Moves the count up to `value` and lets every wait it reaches return.
    /// A lower value, arriving late from another task, changes nothing.
    func reach(_ value: Int) {
        self.value = max(self.value, value)
        for (id, waiter) in waiting where waiter.count <= self.value {
            waiting[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    /// Returns once the count reaches `count`, or fails the test after
    /// `deadline` with "<value> of <count> <what> within <deadline>".
    func wait(count: Int, what: String, file: StaticString, line: UInt) async {
        guard value < count else { return }
        let id = UUID()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.deadline)
            await self?.expire(id)
        }
        let reached = await withCheckedContinuation { waiting[id] = (count, $0) }
        deadline.cancel()
        if !reached {
            XCTFail("\(value) of \(count) \(what) within \(Self.deadline)", file: file, line: line)
        }
    }

    private func expire(_ id: UUID) {
        waiting.removeValue(forKey: id)?.continuation.resume(returning: false)
    }
}
