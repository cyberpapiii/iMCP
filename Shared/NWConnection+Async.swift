import Foundation
import MCP
import Network

extension NWConnection {
    /// One read of up to `maximumLength` bytes.
    ///
    /// `NWConnection.receive` is not cancellation-aware: without the handoff
    /// below, a task awaiting a read the peer never answers hangs until the
    /// peer next sends bytes. Cancelling the task throws `CancellationError`
    /// at once, and a chunk that arrives after that is dropped, which is safe
    /// because callers cancel only to tear the connection down.
    ///
    /// The completion resumes its continuation unconditionally, never behind a
    /// `guard let self`, so a read can neither hang forever nor resume twice.
    /// swift-sdk #214 is the cautionary tale for both.
    func receiveChunk(maximumLength: Int) async throws -> (data: Data, isComplete: Bool) {
        let handoff = ReceiveHandoff()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: ReceiveHandoff.Continuation) in
                handoff.set(continuation)
                receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    guard let continuation = handoff.take() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (data ?? Data(), isComplete))
                    }
                }
            }
        } onCancel: {
            handoff.cancel()?.resume(throwing: CancellationError())
        }
    }
}

extension NWConnection {
    /// Sends `data` and returns once Network framework has taken all of it,
    /// throwing the send's error.
    ///
    /// The completion runs exactly once, including after a cancel, so
    /// resuming unconditionally can neither double-resume nor strand the
    /// caller.
    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}

struct NWConnectionReadyTimeout: Error {}

extension NWConnection {
    /// Starts the connection on `queue` and returns once it is ready. Throws
    /// its failure, `CancellationError` if it is cancelled first, or, after
    /// `timeout`, cancels it and throws `NWConnectionReadyTimeout`: an endpoint
    /// can sit in `.waiting` forever (a stale Bonjour record, say), and
    /// Network framework would retry it indefinitely. A wait that cannot end
    /// (see `NWError.isLocalAddressCollision`) cancels it and throws at once.
    ///
    /// The handler is installed before `start` so a fast transition on the
    /// queue cannot be dropped. With `onState`, it stays and passes on every
    /// state, before and after ready; without, it is removed once ready.
    func startUntilReady(
        queue: DispatchQueue,
        timeout: Duration? = nil,
        onState: (@Sendable (NWConnection.State) -> Void)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            stateUpdateHandler = { [weak self] state in
                let outcome: Result<Void, Error>?
                switch state {
                case .ready: outcome = .success(())
                case .failed(let error): outcome = .failure(error)
                case .waiting(let error) where error.isLocalAddressCollision: outcome = .failure(error)
                case .cancelled: outcome = .failure(CancellationError())
                default: outcome = nil
                }
                if let outcome, once.claim() {
                    if case .waiting = state {
                        self?.cancel()
                    }
                    continuation.resume(with: outcome)
                }
                onState?(state)
            }
            start(queue: queue)

            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    if once.claim() {
                        self?.cancel()
                        continuation.resume(throwing: NWConnectionReadyTimeout())
                    }
                }
            }
        }
        if onState == nil {
            stateUpdateHandler = nil
        }
    }
}

extension NWError {
    /// connectx's EADDRINUSE: the new connection's two ports are those of a
    /// recent connection that has not finished closing (TIME_WAIT lasts 30
    /// seconds on macOS); on loopback the same ports with the roles swapped
    /// count too. Network framework parks such a connection in `.waiting`
    /// and never tries again, and a new connection to the same endpoint is
    /// often given the same local port, so waiting cannot help.
    var isLocalAddressCollision: Bool {
        self == .posix(.EADDRINUSE)
    }
}

func isClosedSocketError(_ error: any Error) -> Bool {
    var underlying = error
    if case MCPError.transportError(let wrapped) = error {
        underlying = wrapped
    }
    guard let nwError = underlying as? NWError, case .posix(let code) = nwError else { return false }
    return code == .ENOTCONN || code == .ECONNRESET
}

/// Hands one receive continuation between the read callback and task
/// cancellation so exactly one of them resumes it.
private final class ReceiveHandoff: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<(data: Data, isComplete: Bool), any Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var isCancelled = false

    func set(_ continuation: Continuation) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func take() -> Continuation? {
        lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
    }

    func cancel() -> Continuation? {
        lock.withLock {
            isCancelled = true
            let taken = continuation
            continuation = nil
            return taken
        }
    }
}
