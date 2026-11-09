import Foundation
import Network

enum CLIBootstrap {

    // MARK: - Timing

    /// How long a connection may take to become ready before the attempt is
    /// abandoned. A stale Bonjour record otherwise sits in `.waiting` forever.
    static let connectTimeout: Duration = .seconds(15)
    static let bonjourDiscoveryTimeout: Duration = .seconds(30)
    static let endpointFilePollInterval: Duration = .milliseconds(250)
    static let reconnectDelay: Duration = .seconds(1)
    static let rediscoverDelay: Duration = .seconds(5)

    private static func seconds(_ duration: Duration) -> Int64 {
        duration.components.seconds
    }

    // MARK: - Notices

    static func userNotice(for inspection: ListenerEndpointFile.Inspection) -> String {
        switch inspection {
        case .usable:
            return "iMCP is running."
        case .missing:
            return "iMCP is not running. Open iMCP from the menu bar."
        case .processDead:
            return "iMCP is not running. The last session quit. Open iMCP from the menu bar."
        case .processUntrusted:
            return "iMCP endpoint file points at a process that is not the signed iMCP app."
        case .notRegularFile, .untrustedOwner, .loosePermissions:
            return "iMCP endpoint file is not trusted. Reopen iMCP so it can rewrite it."
        case .malformed, .invalidPort:
            return "iMCP endpoint file is stale or unreadable. Reopen iMCP."
        }
    }

    static func zeroServicesNotice(for contents: ListenerEndpointFile.Contents) -> String? {
        guard let enabledServices = contents.enabledServices, enabledServices.isEmpty else { return nil }
        return "iMCP is running, but no services are on. Turn one on in the menu bar."
    }

    static func connectionTimeoutNotice(isLoopback: Bool) -> String {
        if isLoopback {
            return "Could not connect to iMCP on this Mac. Open iMCP from the menu bar."
        }
        return """
            Connection to endpoint timed out after \(seconds(connectTimeout)) seconds. If this repeats, \
            check the macOS Local Network permission for the MCP client. Bonjour resolution hangs \
            when that permission is denied.
            """
    }

    static func bonjourTimeoutNotice(loopbackInspection: ListenerEndpointFile.Inspection) -> String {
        """
        \(userNotice(for: loopbackInspection)) Bonjour discovery also timed out after \
        \(seconds(bonjourDiscoveryTimeout)) seconds; that can happen if Local Network permission is \
        denied for this client.
        """
    }

    static let stdinFrameTooLargeNotice = """
        A client message was larger than the \(WireContract.maxClientMessageDescription) iMCP accepts, \
        so it was not sent. The session ends here; restart the client.
        """

    // MARK: - Pairing code

    enum PairingCodeResolution: Equatable {
        case none
        case value(String)
        case conflict
    }

    enum PairingCodeDelivery: Equatable {
        case none
        case send(String)
        /// There is a code, but the app was found by its Bonjour name.
        case withheld

        var code: String? {
            if case .send(let code) = self { return code }
            return nil
        }
    }

    /// The pairing code is a bearer secret and the preamble does not
    /// authenticate the app to the CLI. It goes only to the listener named by
    /// the owner-only endpoint file whose pid passed the code-signature
    /// check, never to a service chosen by its Bonjour name.
    static func pairingCodeDelivery(_ code: String?, resolvedViaLoopback: Bool) -> PairingCodeDelivery {
        guard let code else { return .none }
        return resolvedViaLoopback ? .send(code) : .withheld
    }

    static let withheldPairingCodeNotice =
        "Not sending the pairing code: iMCP was found by Bonjour, not its endpoint file. Approve this client in iMCP instead."

    /// Resolves `--pair` vs `IMCP_PAIR_CODE` after validation. Disagreeing
    /// sources are `.conflict` so callers can fail closed without preferring env.
    static func pairingCodeResolution(environmentCode: String?, argumentCode: String?) -> PairingCodeResolution {
        let environment = emptyToNil(environmentCode)
        let argument = emptyToNil(argumentCode)
        switch (environment, argument) {
        case (nil, nil):
            return .none
        case (let environment?, nil):
            return .value(validatedPairingCode(environment, source: PairingCode.environmentVariable))
        case (nil, let argument?):
            return .value(validatedPairingCode(argument, source: PairingCode.flag))
        case (let environment?, let argument?):
            let validatedEnvironment = validatedPairingCode(environment, source: PairingCode.environmentVariable)
            let validatedArgument = validatedPairingCode(argument, source: PairingCode.flag)
            if validatedEnvironment != validatedArgument {
                return .conflict
            }
            return .value(validatedEnvironment)
        }
    }

    static func resolvedPairingCode(from arguments: [String] = CommandLine.arguments) -> String? {
        let environmentCode: String?
        if let raw = ProcessInfo.processInfo.environment[PairingCode.environmentVariable], !raw.isEmpty {
            environmentCode = raw
        } else {
            environmentCode = nil
        }

        let argumentCode: String?
        if let pairFlagIndex = arguments.firstIndex(of: PairingCode.flag) {
            let valueIndex = arguments.index(after: pairFlagIndex)
            guard valueIndex < arguments.count, !arguments[valueIndex].isEmpty else {
                fputs("error: \(PairingCode.flag) requires a pairing code\n", stderr)
                exit(1)
            }
            argumentCode = arguments[valueIndex]
        } else {
            argumentCode = nil
        }

        switch pairingCodeResolution(environmentCode: environmentCode, argumentCode: argumentCode) {
        case .none:
            return nil
        case .value(let code):
            return code
        case .conflict:
            fputs("error: \(PairingCode.flag) and \(PairingCode.environmentVariable) disagree\n", stderr)
            exit(1)
        }
    }

    /// A bad code fails here instead of being silently dropped at sign time.
    private static func validatedPairingCode(_ code: String, source: String) -> String {
        let normalized = PairingCode.normalize(code)
        guard PairingCode.isValid(normalized) else {
            fputs("error: \(source) must be \(PairingCode.formatDescription)\n", stderr)
            exit(1)
        }
        return normalized
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Launching the app

    /// At most one launch request per Bonjour discovery timeout. A cycle that
    /// runs to that timeout lasts longer (the rediscover delay follows it), so
    /// it may ask every time; this limits only cycles that fail fast.
    static let appLaunchRequestCooldown = TimeInterval(seconds(bonjourDiscoveryTimeout))

    enum AppLaunchDecision: Equatable {
        case launch
        case alreadyRunning
        case coolingDown
    }

    /// The CLI reaches Bonjour only when the loopback endpoint file was
    /// unusable, and the most common reason for that is an app that is not
    /// running yet. Measured on a cold boot: the CLI was spawned 1.5 seconds
    /// after login and the app did not launch until 48 seconds later, so the
    /// first client request waited the better part of a minute for a login item
    /// that the CLI could have started itself.
    ///
    /// A running app is left alone: in that case the endpoint file is stale or
    /// the connection failed for some other reason, and neither is fixed by
    /// launching what is already there.
    static func appLaunchDecision(
        isAppRunning: Bool,
        lastRequest: Date?,
        now: Date
    ) -> AppLaunchDecision {
        if isAppRunning {
            return .alreadyRunning
        }
        guard let lastRequest else { return .launch }
        return now.timeIntervalSince(lastRequest) >= appLaunchRequestCooldown ? .launch : .coolingDown
    }

    static func runEarlyExitCommandsIfNeeded(arguments: [String] = CommandLine.arguments) {
        if arguments.contains("--fingerprint") {
            guard let signingKey = ClientKeyStore.loadSigningKey() else {
                fputs("error: could not load signing key\n", stderr)
                exit(1)
            }
            print(ClientKeyStore.publicKeyFingerprint(for: signingKey))
            exit(0)
        }

        if arguments.contains("--rotate-key") {
            guard let rotation = ClientKeyStore.rotateSigningKey() else {
                fputs("error: could not rotate signing key\n", stderr)
                exit(1)
            }
            print("old: \(rotation.oldFingerprint)")
            print("new: \(rotation.newFingerprint)")
            fputs(
                """
                Rotated signing key. iMCP treats a new key as a new client, so \
                re-pair using Settings or a pairing code before connecting again.

                """,
                stderr
            )
            exit(0)
        }
    }

    // MARK: - Recovering from a failed connection

    enum ProxyFailureRecovery: Equatable {
        /// End the process. The client sees EOF and restarts the server.
        case terminate
        /// The app closed before the client sent anything: connect again.
        case reconnect
        /// The endpoint could not be reached: choose a discovery mode and retry.
        case rediscover
    }

    /// A proxy that has consumed stdin is never replaced. A new connection
    /// would be a session the client never initialized and the app never
    /// approved, and the client would wait forever on the old one.
    static func recovery(after error: any Error, hasConsumedStdin: Bool) -> ProxyFailureRecovery {
        if hasConsumedStdin { return .terminate }
        switch error as? StdioProxyError {
        case .connectionClosed: return .reconnect
        case .stdinClosed, .stdinFrameTooLarge: return .terminate
        case nil: return .rediscover
        }
    }

    /// The decision for a proxy whose `start()` threw. Sealing stdin first
    /// means a byte the proxy read but never forwarded still counts, and no
    /// byte can be read after the answer.
    static func recovery(after error: any Error, proxy: StdioProxy?) -> ProxyFailureRecovery {
        recovery(after: error, hasConsumedStdin: proxy?.sealStdin() ?? false)
    }
}

enum StdioProxyError: Swift.Error, Equatable {
    case connectionClosed
    case stdinClosed
    /// One message exceeded `WireContract.maxClientMessageBytes`. Terminal:
    /// reconnecting would resume mid-message and send the app garbage.
    case stdinFrameTooLarge

    /// ENODATA ("No message available on STREAM") counts as a close: Network
    /// framework has been seen to report a peer's graceful close with it
    /// instead of `isComplete` (Apple Developer Forums thread 718709), and a
    /// read retried after it only fails again.
    init?(networkReadFailure error: any Error) {
        guard isClosedSocketError(error) || (error as? NWError) == .posix(.ENODATA) else { return nil }
        self = .connectionClosed
    }
}
