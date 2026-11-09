import Foundation
import os

/// What a Keychain read found. Only `missing` is absence: an item that could
/// not be read, or not decoded, or did not answer in time, is `unavailable`,
/// and a caller that treated it as absent would overwrite a live secret.
enum KeychainReadResult<Value: Equatable & Sendable>: Equatable, Sendable {
    case missing
    case found(Value)
    case unavailable
}

/// Every Keychain call for one item, run one at a time on that item's own
/// serial queue, with reads that wait at most a deadline.
///
/// `SecItemCopyMatching` blocks while macOS waits for the user to answer an
/// authorization prompt. Nothing here blocks a Swift concurrency thread: that
/// pool does not grow, so a few calls blocked on it starve every task in the
/// process, deadline timers included. A blocked call holds up only later
/// calls for the same queue.
///
/// The serialization is per queue, so build one per item: each storage's
/// `production` is a single shared instance.
///
/// A reader waits at most its deadline and is told `unavailable`; the read
/// carries on, and every reader that comes while it is still pending waits on
/// that same read instead of queueing another behind the same prompt. Once it
/// finishes the next reader reads afresh, unless `keepsFound` and it found the
/// item, in which case the value is kept until a write.
final class KeychainItemQueue<Value: Equatable & Sendable>: @unchecked Sendable {
    typealias Result = KeychainReadResult<Value>

    /// The item as one queued call sees it, valid only inside that call.
    /// A save or delete, whether or not it succeeds, drops the read in hand.
    struct Access {
        fileprivate let owner: KeychainItemQueue

        /// The definitive value, read now.
        func read() -> Result { owner.readNow() }

        func save(_ value: Value) -> Bool {
            defer { owner.forgetRead() }
            guard let data = owner.encode(value) else { return false }
            return owner.calls.save(data)
        }

        func delete() -> Bool {
            defer { owner.forgetRead() }
            return owner.calls.delete()
        }
    }

    private let queue: DispatchQueue
    private let calls: KeychainItemCalls
    private let decode: @Sendable (Data) -> Value?
    private let encode: @Sendable (Value) -> Data?
    private let keepsFound: Bool
    private let lock = NSLock()
    private var current: (id: UUID, reader: DeadlinedValue<Result>)?

    init(
        label: String,
        keepsFound: Bool = false,
        calls: KeychainItemCalls,
        decode: @escaping @Sendable (Data) -> Value?,
        encode: @escaping @Sendable (Value) -> Data?
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.calls = calls
        self.decode = decode
        self.encode = encode
        self.keepsFound = keepsFound
    }

    func load(within deadline: Duration = KeychainItemQueue<Never>.promptDeadline) async -> Result {
        let reader = lock.withLock { () -> DeadlinedValue<Result> in
            if let current { return current.reader }
            let id = UUID()
            let reader = DeadlinedValue<Result>(on: queue) { [weak self] in
                guard let self else { return .unavailable }
                let result = self.readNow()
                self.finished(id, with: result)
                return result
            }
            current = (id, reader)
            return reader
        }
        // Waited on detached, so a cancelled caller cannot turn a live item
        // into `unavailable`.
        return await Task.detached { await reader.value(within: deadline) }.value ?? .unavailable
    }

    /// Runs `work` after every call queued before it, however long a call
    /// ahead of it is held by a prompt. The caller suspends; no thread waits.
    func perform<T: Sendable>(_ work: @escaping @Sendable (Access) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work(Access(owner: self))) }
        }
    }

    /// Runs `work` after every call queued before it, waiting at most
    /// `deadline`; nil when it had not finished by then. Work that had not
    /// started by then never runs, so a write the caller was told failed
    /// does not land later behind an answered prompt. Work that had started
    /// finishes unseen.
    func run<T: Sendable>(
        within deadline: Duration = KeychainItemQueue<Never>.promptDeadline,
        _ work: @escaping @Sendable (Access) -> T
    ) async -> T? {
        let claim = OSAllocatedUnfairLock(initialState: Claim.pending)
        let outcome = DeadlinedValue<T?>(on: queue) { [weak self] in
            let starts = claim.withLock { state -> Bool in
                guard state == .pending else { return false }
                state = .started
                return true
            }
            guard starts, let self else { return nil }
            return work(Access(owner: self))
        }
        // Detached for the same reason as `load`.
        let finished = await Task.detached { await outcome.value(within: deadline) }.value
        guard let finished else {
            claim.withLock { state in
                if state == .pending { state = .abandoned }
            }
            return nil
        }
        return finished
    }

    /// Blocks the calling thread until the item has been read, however long
    /// a call ahead of it is held by a prompt. Only for a one-shot command
    /// that has nothing else to do and no concurrency to starve.
    func loadBlocking() -> Result {
        queue.sync { readNow() }
    }

    private enum Claim {
        case pending
        case started
        case abandoned
    }

    /// Called on `queue`.
    private func readNow() -> Result {
        switch calls.load() {
        case .missing: return .missing
        case .failed: return .unavailable
        case .data(let data): return decode(data).map { .found($0) } ?? .unavailable
        }
    }

    private func forgetRead() {
        lock.withLock { current = nil }
    }

    private func finished(_ id: UUID, with result: Result) {
        if keepsFound, case .found = result { return }
        lock.withLock {
            if current?.id == id { current = nil }
        }
    }
}

extension KeychainItemQueue where Value == Never {
    /// How long a caller waits on the Keychain before it gives up and says
    /// so, unless it has a reason to wait less. Generous, because the honest
    /// case is a user walking back to their machine to answer an
    /// authorization prompt. Declared where `Value` is `Never` so callers
    /// name it with no type argument.
    static var promptDeadline: Duration { .seconds(10) }
}

extension KeychainItemQueue where Value == Data {
    /// An item that holds raw bytes.
    convenience init(label: String, keepsFound: Bool = false, calls: KeychainItemCalls) {
        self.init(label: label, keepsFound: keepsFound, calls: calls, decode: { $0 }, encode: { $0 })
    }
}

extension KeychainItemQueue where Value: Codable {
    /// An item that holds `Value` as JSON. Data that does not decode is
    /// `unavailable`, never `missing`.
    convenience init(label: String, keepsFound: Bool = false, json calls: KeychainItemCalls) {
        self.init(
            label: label,
            keepsFound: keepsFound,
            calls: calls,
            decode: { try? JSONDecoder().decode(Value.self, from: $0) },
            encode: { value in
                do {
                    return try JSONEncoder().encode(value)
                } catch {
                    assertionFailure("Failed to encode a Keychain item: \(error)")
                    return nil
                }
            }
        )
    }
}
