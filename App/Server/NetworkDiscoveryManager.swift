import Network
import OSLog

/// Owns the Bonjour listener: starts it, stops it, and replaces it when it
/// fails or is cancelled from outside, for as long as it is meant to run.
actor NetworkDiscoveryManager {
    enum State: Equatable, Sendable {
        case stopped
        /// Meant to run, and not yet ready.
        case starting
        case listening(port: UInt16)
        /// A listener could not be made. Nothing is listening until the next `start`.
        case failed
    }

    static let failureRecoveryDelay: Duration = .seconds(1)

    private let makeListener: @Sendable () throws -> NWListener
    private let clock: WallClock
    private(set) var listener: NWListener?
    private(set) var state = State.stopped
    private var onChange: (@Sendable () -> Void)?
    private var onConnection: (@Sendable (NWConnection) -> Void)?
    /// Counts listeners made, so an event from one already replaced or
    /// stopped is told apart from the current one's: NWListener delivers
    /// state changes on its queue after `cancel()` returns.
    private var generation = 0
    private var recovery: Task<Void, Never>?

    init(
        clock: WallClock = .live,
        makeListener: @escaping @Sendable () throws -> NWListener = NetworkDiscoveryManager.makeListener
    ) {
        self.clock = clock
        self.makeListener = makeListener
    }

    /// The listener asks for no particular port, so each one binds a free
    /// ephemeral port and a replacement can never collide with an old one.
    @Sendable static func makeListener() throws -> NWListener {
        let listener = try NWListener(using: WireContract.loopbackParameters())
        listener.service = NWListener.Service(
            name: WireContract.bonjourInstanceName,
            type: WireContract.serviceType,
            domain: WireContract.serviceDomain
        )
        return listener
    }

    /// Starts listening unless already meant to. `onChange` is called after
    /// each change of `state`; read `state` then for the new one.
    func start(
        onChange: @escaping @Sendable () -> Void,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) {
        guard state == .stopped || state == .failed else { return }
        self.onChange = onChange
        self.onConnection = onConnection
        replaceListener()
        Logger.server.info("Started network advertisement")
    }

    func stop() {
        guard state != .stopped else { return }
        retireListener()
        set(.stopped)
        Logger.server.info("Stopped network advertisement")
    }

    /// Returns once a recovery that was waiting has run, or been called off.
    func settle() async {
        await recovery?.value
    }

    /// A cancelled NWListener cannot be started again, so every start and
    /// every recovery makes a new one.
    private func replaceListener() {
        retireListener()
        set(.starting)
        let made: NWListener
        do {
            made = try makeListener()
        } catch {
            Logger.server.error("Failed to create listener: \(error)")
            set(.failed)
            return
        }
        let generation = generation
        made.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerStateChanged(state, generation: generation) }
        }
        made.newConnectionHandler = onConnection
        made.start(queue: .main)
        listener = made
    }

    /// Cancels the current listener, and any recovery of it, without its
    /// cancel reading as one to recover from.
    private func retireListener() {
        generation += 1
        recovery?.cancel()
        recovery = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onChange?()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && state != .stopped
    }

    private func listenerStateChanged(_ listenerState: NWListener.State, generation: Int) {
        guard isCurrent(generation) else { return }
        switch listenerState {
        case .ready:
            if let port = listener?.port?.rawValue {
                Logger.server.info("Server ready and advertising via Bonjour on port \(port)")
                set(.listening(port: port))
            }
        case .setup:
            Logger.server.debug("Server setting up...")
        case .waiting(let error):
            Logger.server.warning("Server waiting: \(error)")
        case .failed(let error):
            Logger.server.error("Server failed: \(error)")
            set(.starting)
            let clock = clock
            let dueAt = clock.date(after: Self.failureRecoveryDelay)
            recovery = Task { [weak self] in
                // Cancelled by a stop or a replacement while it waited.
                guard (try? await clock.sleepUntil(dueAt)) != nil else { return }
                await self?.recover(generation)
            }
        case .cancelled:
            Logger.server.info("Attempting to recover from unexpected listener cancellation")
            replaceListener()
        @unknown default:
            Logger.server.warning("Unknown server state")
        }
    }

    private func recover(_ generation: Int) {
        guard isCurrent(generation) else { return }
        Logger.server.info("Attempting to recover from server failure")
        replaceListener()
    }
}
