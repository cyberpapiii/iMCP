import Foundation
import Network

@testable import iMCP

/// A connected loopback socket: a client and the app's end of its
/// connection, not yet started, accepted by the listener every pair shares.
struct LoopbackSocketPair: @unchecked Sendable {
    let client: NWConnection
    let appEnd: NWConnection

    /// The listener's port, which every client connects to.
    static var listenerPort: NWEndpoint.Port {
        get async throws { try await SharedLoopbackListener.shared.value.port }
    }

    /// Every wait is bounded by `deadline`. A client whose connect collides
    /// with a closing connection's ports (`NWError.isLocalAddressCollision`)
    /// is replaced: the next one gets the next local port.
    static func open(queue: DispatchQueue, deadline: Duration) async throws -> LoopbackSocketPair {
        let listener = try await SharedLoopbackListener.shared.value
        var attemptsLeft = 3
        while true {
            attemptsLeft -= 1
            do {
                return try await listener.connect(queue: queue, deadline: deadline)
            } catch let error as NWError where error.isLocalAddressCollision && attemptsLeft > 0 {
                continue
            }
        }
    }
}

/// One listener for the whole test run. With a listener per connection, the
/// kernel can give a new listener the port of a client that just closed and
/// the new client that client's listener port: the ports of a connection still
/// in TIME_WAIT, so the connect fails with EADDRINUSE, often many times in a
/// row. See docs/solutions/integrations/loopback-connect-port-collision.md.
private final class SharedLoopbackListener: @unchecked Sendable {
    static let shared = Task {
        let shared = try SharedLoopbackListener()
        shared.port = try await shared.listener.startUntilReady(queue: DispatchQueue(label: "SharedLoopbackListener"))
        return shared
    }

    private(set) var port: NWEndpoint.Port = .any
    private let listener: NWListener
    private let lock = NSLock()
    /// Accepted connections, and connects waiting for theirs, by client port.
    private var unclaimed: [UInt16: NWConnection] = [:]
    private var claims: [UInt16: @Sendable (Result<NWConnection, Error>) -> Void] = [:]

    private init() throws {
        listener = try NWListener(using: WireContract.loopbackParameters())
        listener.newConnectionHandler = { [weak self] in self?.accepted($0) }
    }

    func connect(queue: DispatchQueue, deadline: Duration) async throws -> LoopbackSocketPair {
        let client = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: WireContract.loopbackParameters()
        )
        do {
            try await client.startUntilReady(queue: queue, timeout: deadline)
            guard case .hostPort(_, let clientPort)? = client.currentPath?.localEndpoint else {
                throw NWError.posix(.EADDRNOTAVAIL)
            }
            let appEnd = try await appEnd(forClientPort: clientPort.rawValue, deadline: deadline)
            return LoopbackSocketPair(client: client, appEnd: appEnd)
        } catch {
            client.cancel()
            throw error
        }
    }

    private func appEnd(forClientPort port: UInt16, deadline: Duration) async throws -> NWConnection {
        try await withDeadline(
            deadline,
            throwing: NWError.posix(.ETIMEDOUT),
            onTimeout: { [self] in lock.withLock { _ = claims.removeValue(forKey: port) } }
        ) { report in
            let waiting = lock.withLock { () -> NWConnection? in
                if let connection = unclaimed.removeValue(forKey: port) { return connection }
                claims[port] = report
                return nil
            }
            if let waiting {
                report(.success(waiting))
            }
        }
    }

    private func accepted(_ connection: NWConnection) {
        guard case .hostPort(_, let clientPort) = connection.endpoint else {
            connection.cancel()
            return
        }
        let claim = lock.withLock { () -> (@Sendable (Result<NWConnection, Error>) -> Void)? in
            if let claim = claims.removeValue(forKey: clientPort.rawValue) { return claim }
            unclaimed[clientPort.rawValue] = connection
            return nil
        }
        claim?(.success(connection))
    }
}
