import Foundation
import Logging
import ServiceLifecycle

// This process only ever creates one file, the Debug signing key. Create it,
// and any directory made for it, owner-only from the start rather than
// tightening the mode after the write.
umask(0o077)

var log = Logger(label: "me.mattt.iMCP.server") { StreamLogHandler.standardError(label: $0) }
#if DEBUG
    log.logLevel = .debug
#else
    log.logLevel = .warning
#endif

CLIBootstrap.runEarlyExitCommandsIfNeeded()

let cliPairingCode = CLIBootstrap.resolvedPairingCode()

// Both `.gracefullyShutdownGroup` behaviors are load-bearing. `MCPService.run()`
// returns when the connection to the menubar app drops, and under the library
// default of `.cancelGroup` that return raises `ServiceGroupError` at the top
// level, which the Swift runtime turns into a fatal error.
let lifecycle = ServiceGroup(
    configuration: .init(
        services: [
            .init(
                service: MCPService(pairingCode: cliPairingCode, log: log),
                successTerminationBehavior: .gracefullyShutdownGroup,
                failureTerminationBehavior: .gracefullyShutdownGroup
            )
        ],
        gracefulShutdownSignals: [.sigint, .sigterm],
        logger: log
    )
)

try await lifecycle.run()
