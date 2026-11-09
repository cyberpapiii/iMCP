import Dispatch

/// A value from a call that may never return, surfaced with a deadline.
///
/// `SecItemCopyMatching` blocks indefinitely while macOS waits for the user to
/// answer a Keychain authorization prompt, and a task awaiting a non-throwing
/// `Task.value` cannot be cancelled out of that wait. Commit `08d26ce` cost 21
/// consecutive client connections to exactly this mistake, in the CLI.
///
/// The read runs on `queue`, never on a Swift concurrency thread: that pool
/// has one thread per core and does not grow, so a few blocked reads on it
/// starve every task in the process, the deadline timers included. A blocked
/// read then costs the caller its deadline and nothing more.
///
/// The read runs at most once. A caller that timed out and comes back later
/// sees the result if it has since arrived.
actor DeadlinedValue<Value: Sendable> {
    private let queue: DispatchQueue
    private let read: @Sendable () -> Value
    private let arrival = Latch()
    private var value: Value?
    private var didStart = false

    init(
        on queue: DispatchQueue = DispatchQueue(label: "co.dododo.iMCP.deadlined-value", qos: .userInitiated),
        _ read: @escaping @Sendable () -> Value
    ) {
        self.queue = queue
        self.read = read
    }

    func value(within deadline: Duration) async -> Value? {
        start()
        guard await arrival.wait(within: deadline) else { return nil }
        return value
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        let read = self.read
        queue.async { [weak self] in
            let produced = read()
            Task { [weak self] in await self?.store(produced) }
        }
    }

    private func store(_ produced: Value) async {
        value = produced
        await arrival.open()
    }
}
