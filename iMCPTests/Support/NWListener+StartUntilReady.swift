import Network
import os

/// Compiled into both test bundles (the project lists it for
/// `imcp-serverTests` too), so it imports nothing from the app or the CLI.
extension NWListener {
    /// Starts the listener on `queue` and returns its port once it is ready.
    /// A listener that waits fails: a test has no reason to wait for one.
    func startUntilReady(queue: DispatchQueue) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let claim = {
                resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
            }
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard claim() else { return }
                    if let port = self?.port {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                    }
                case .failed(let error), .waiting(let error):
                    guard claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            start(queue: queue)
        }
    }
}
