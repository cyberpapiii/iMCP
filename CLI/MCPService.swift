import AppKit
import Dispatch
import Foundation
import Logging
import MCP
import Network
import ServiceLifecycle

enum DiscoveryMode: Equatable {
    case preferLoopback
    case bonjourOnly
}

enum ResolvedEndpoint: Equatable {
    case loopback(NWEndpoint)
    case bonjour(NWEndpoint)

    init?(loopback inspection: ListenerEndpointFile.Inspection) {
        guard case .usable(let handoff) = inspection, let port = NWEndpoint.Port(rawValue: handoff.port) else {
            return nil
        }
        self = .loopback(.hostPort(host: "127.0.0.1", port: port))
    }

    var endpoint: NWEndpoint {
        switch self {
        case .loopback(let endpoint), .bonjour(let endpoint):
            return endpoint
        }
    }

    var isLoopback: Bool {
        if case .loopback = self { return true }
        return false
    }

    /// Once a loopback attempt fails to establish, stick to Bonjour until a
    /// session actually connects. Otherwise a stale endpoint file gets retried
    /// every cycle and Bonjour is never reached. A failed Bonjour attempt goes
    /// back to loopback first.
    var discoveryModeAfterFailure: DiscoveryMode {
        isLoopback ? .bonjourOnly : .preferLoopback
    }
}

actor MCPService: Service {
    /// The browser delivers its callbacks here rather than on the main queue,
    /// for the same reason `StdioProxy` gives its connection a dedicated queue:
    /// nothing in the CLI drives a main run loop, so the main queue only puts
    /// discovery behind whatever else the process has scheduled there.
    private let browserQueue = DispatchQueue(label: "me.mattt.iMCP.server.browser")

    private let pairingCode: String?
    private let log: Logger
    private var lastLoopbackInspection: ListenerEndpointFile.Inspection = .missing
    private var lastAppLaunchRequest: Date?

    init(pairingCode: String? = nil, log: Logger) {
        self.pairingCode = pairingCode
        self.log = log
    }

    func run() async throws {
        var discoveryMode = DiscoveryMode.preferLoopback

        while !Task.isShuttingDownGracefully {
            var resolved: ResolvedEndpoint?
            var proxy: StdioProxy?
            do {
                let plan = try await resolveEndpoint(mode: discoveryMode)
                resolved = plan

                log.info("Creating connection to endpoint...")

                let delivery = CLIBootstrap.pairingCodeDelivery(pairingCode, resolvedViaLoopback: plan.isLoopback)
                if delivery == .withheld {
                    log.warning("\(CLIBootstrap.withheldPairingCodeNotice)")
                }

                let newProxy = StdioProxy(
                    endpoint: plan.endpoint,
                    isLoopback: plan.isLoopback,
                    log: log,
                    pairingCode: delivery.code
                )
                proxy = newProxy
                // SIGTERM and SIGINT only raise a graceful-shutdown flag,
                // and a connected proxy never checks it: it sits in socket
                // and stdin reads. Cancelling the socket ends those reads
                // the same way the app quitting does.
                try await withGracefulShutdownHandler {
                    try await newProxy.start()
                } onGracefulShutdown: {
                    Task { await newProxy.stop() }
                }
                if Task.isShuttingDownGracefully { return }
            } catch {
                if Task.isShuttingDownGracefully { return }
                switch CLIBootstrap.recovery(after: error, proxy: proxy) {
                case .terminate:
                    switch error as? StdioProxyError {
                    case .stdinClosed:
                        log.info("Stdin closed by client, terminating...")
                    case .stdinFrameTooLarge:
                        log.critical("\(CLIBootstrap.stdinFrameTooLargeNotice)")
                    case .connectionClosed, nil:
                        log.critical("Connection ended mid-session (\(error)), terminating...")
                    }
                    return
                case .reconnect:
                    discoveryMode = .preferLoopback
                    log.info("Connection closed before the client sent anything, will retry...")
                    try await Task.sleep(for: CLIBootstrap.reconnectDelay)
                case .rediscover:
                    discoveryMode = resolved?.discoveryModeAfterFailure ?? .preferLoopback
                    if discoveryMode == .bonjourOnly {
                        log.warning("Loopback connection failed (\(error)); falling back to Bonjour discovery")
                    }
                    log.error("Connection error: \(error)")
                    log.info("Will retry connection in \(CLIBootstrap.rediscoverDelay.components.seconds) seconds...")
                    try await Task.sleep(for: CLIBootstrap.rediscoverDelay)
                }
            }
        }
    }

    /// Every path into Bonjour discovery means the CLI has no port to talk to.
    /// Waiting for the user's login items to reach iMCP costs a cold-boot client
    /// most of a minute; asking Launch Services costs about a second. The app is
    /// opened without activation so a boot never steals focus.
    private func launchAppIfNotRunning() async {
        let isRunning =
            !NSRunningApplication
            .runningApplications(withBundleIdentifier: WireContract.appBundleIdentifier)
            .isEmpty
        switch CLIBootstrap.appLaunchDecision(
            isAppRunning: isRunning,
            lastRequest: lastAppLaunchRequest,
            now: Date()
        ) {
        case .alreadyRunning, .coolingDown:
            return
        case .launch:
            break
        }
        lastAppLaunchRequest = Date()
        guard
            let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: WireContract.appBundleIdentifier
            )
        else {
            log.warning("iMCP is not running and no installed copy was found to launch")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            log.info("Launched iMCP (pid \(application.processIdentifier)) to serve this client")
        } catch {
            log.warning("Could not launch iMCP at \(applicationURL.path): \(error)")
        }
    }

    private static func inspectEndpointFile() -> ListenerEndpointFile.Inspection {
        ListenerEndpointFile.inspect(isTrustedProcess: AppSigningTrust.isSignedIMCPProcess)
    }

    private func resolveEndpoint(mode: DiscoveryMode) async throws -> ResolvedEndpoint {
        switch mode {
        case .preferLoopback:
            let inspection = Self.inspectEndpointFile()
            lastLoopbackInspection = inspection
            guard case .usable(let handoff) = inspection, let loopback = ResolvedEndpoint(loopback: inspection)
            else {
                log.warning("\(CLIBootstrap.userNotice(for: inspection))")
                return try await discoverEndpointViaBonjour(watchingEndpointFile: true)
            }
            if let zeroServicesNotice = CLIBootstrap.zeroServicesNotice(for: handoff) {
                log.warning("\(zeroServicesNotice)")
            }
            // Loopback is exempt from the macOS Local Network privacy
            // gate; resolving the Bonjour service endpoint hangs in
            // .preparing when that permission is denied for us.
            log.info("Connecting via loopback endpoint file (port \(handoff.port), app pid \(handoff.pid))")
            return loopback
        case .bonjourOnly:
            return try await discoverEndpointViaBonjour(watchingEndpointFile: false)
        }
    }

    private func discoverEndpointViaBonjour(watchingEndpointFile: Bool) async throws -> ResolvedEndpoint {
        let loopbackInspection = lastLoopbackInspection
        let log = self.log
        await launchAppIfNotRunning()
        log.info("Starting Bonjour service discovery...")

        let browser = NWBrowser(
            for: .bonjour(type: WireContract.serviceType, domain: nil),
            using: WireContract.loopbackParameters()
        )

        return try await withCheckedThrowingContinuation {
            continuation in
            let once = OnceFlag()

            let timeoutTask = Task {
                // The app this call may have just launched writes its endpoint
                // file as soon as its listener is up. Loopback needs no Local
                // Network permission, so take it the moment it appears instead
                // of waiting out Bonjour.
                let polls = Int(CLIBootstrap.bonjourDiscoveryTimeout / CLIBootstrap.endpointFilePollInterval)
                for _ in 0 ..< polls {
                    try await Task.sleep(for: CLIBootstrap.endpointFilePollInterval)
                    guard watchingEndpointFile, let loopback = ResolvedEndpoint(loopback: Self.inspectEndpointFile())
                    else { continue }
                    if once.claim() {
                        browser.cancel()
                        log.info("iMCP wrote its endpoint file; connecting via loopback (\(loopback.endpoint))")
                        continuation.resume(returning: loopback)
                    }
                    return
                }

                if once.claim() {
                    let notice = CLIBootstrap.bonjourTimeoutNotice(
                        loopbackInspection: loopbackInspection
                    )
                    log.error("\(notice)")
                    // Cancel the browser like the success/failure
                    // paths do; otherwise each retry cycle leaks a
                    // running NWBrowser.
                    browser.cancel()
                    continuation.resume(throwing: MCPError.internalError(notice))
                }
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    log.error("Browser failed: \(error)")
                    if once.claim() {
                        timeoutTask.cancel()
                        browser.cancel()
                        continuation.resume(throwing: error)
                    }
                case .ready:
                    log.info("Browser is ready and searching for services")
                case .waiting(let error):
                    log.warning("Browser is waiting: \(error)")
                case .setup, .cancelled:
                    log.debug("Browser state changed: \(state)")
                @unknown default:
                    log.debug("Browser state changed: \(state)")
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                log.debug("Found \(results.count) Bonjour services")

                for (index, result) in results.enumerated() {
                    log.debug("Service \(index + 1): \(result.endpoint)")
                }

                guard !results.isEmpty else { return }

                switch bonjourBrowseStep(for: results.map { String(describing: $0.endpoint) }) {
                case .keepBrowsing(let reason):
                    log.info("No single iMCP service in this browse result (\(reason)); still browsing")
                case .connect(let description):
                    guard let selected = results.first(where: { String(describing: $0.endpoint) == description })
                    else { return }
                    if once.claim() {
                        timeoutTask.cancel()
                        browser.cancel()
                        log.info("Selected endpoint: \(selected.endpoint)")
                        continuation.resume(returning: .bonjour(selected.endpoint))
                    }
                }
            }

            browser.start(queue: browserQueue)
        }
    }
}
