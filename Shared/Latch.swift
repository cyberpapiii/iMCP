import struct Foundation.UUID

/// A one-way event that callers can wait on for a bounded time.
///
/// Each waiter has its own deadline and leaves on it, or on cancellation,
/// without disturbing the others; opening the latch releases all of them.
/// Every parked waiter comes back exactly once, which is what keeps a
/// blocked Keychain read, or an app that never sends an auth challenge, from
/// parking a continuation nobody resumes.
actor Latch {
    private(set) var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let parked = waiters.values
        waiters.removeAll()
        for continuation in parked {
            continuation.resume()
        }
    }

    /// Waits until the latch opens, `deadline` passes, or the task is
    /// cancelled, and reports whether it opened.
    ///
    /// The continuation is parked inside the actor before this suspends, so
    /// the deadline task cannot look for the waiter before it exists.
    @discardableResult
    func wait(within deadline: Duration) async -> Bool {
        if isOpen { return true }

        let waiterID = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            await self?.retire(waiterID)
        }
        defer { timeout.cancel() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.retire(waiterID)
            }
        }

        return isOpen
    }

    private func retire(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }
}
