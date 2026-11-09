import Foundation
import OSLog

/// Whether this process is the app or only the host for the test bundle.
/// Decided once, from the launch environment.
enum HostMode {
    case app
    /// The tests are injected into the real app binary. This host must not
    /// open the paired-client store, replay the iCloud session against
    /// Apple, probe this Mac's privacy settings, take focus, or put a second
    /// "iMCP" listener on the machine.
    case testHost

    static let current: HostMode =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ? .testHost : .app
}

/// Everything that differs between the app and the test host.
@MainActor
struct HostDependencies {
    let pairedClientStorage: PairedClientStorage
    let listener: NetworkDiscoveryManager?
    /// The services the menu lists, the tool gate serves, and whose
    /// lifecycle follows their switches.
    let entries: [ServiceEntry]
    let activation: WindowActivation
    /// Whether this process holds Full Disk Access. Nil leaves it unknown.
    let fullDiskAccessGranted: @MainActor () -> Bool?
    let launch: @MainActor (ICloudSession) -> Void

    init(_ hostMode: HostMode) {
        switch hostMode {
        case .app:
            pairedClientStorage = .production
            listener = NetworkDiscoveryManager()
            entries = ServiceRegistry.entries
            activation = .app
            fullDiskAccessGranted = { FullDiskAccess.isGranted }
            launch = { iCloud in
                // A stored session makes the Location tools work at launch
                // without the user opening anything.
                Task { await iCloud.restoreIfNeeded() }
                Logger.server.notice("Full Disk Access granted: \(FullDiskAccess.isGranted, privacy: .public)")
            }
        case .testHost:
            pairedClientStorage = PairedClientStorage(
                calls: KeychainItemCalls(load: { .missing }, save: { _ in false }, delete: { false })
            )
            listener = nil
            entries = []
            activation = .inert
            fullDiskAccessGranted = { nil }
            launch = { _ in }
        }
    }
}

/// The composition root: the app's long-lived objects, each made once and
/// handed what it needs. SwiftUI initializes the `App` struct more than once
/// on macOS, so nothing here may live in it: two server controllers bound two
/// listeners on adjacent ports and registered Bonjour twice, the second under
/// the conflict-renamed `iMCP (2)`.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment(hostMode: .current)

    let activation: WindowActivation
    /// The app's one iCloud session. The Location tools reach the same one
    /// from outside the view hierarchy.
    let iCloud: ICloudSession
    let pairedClients: PairedClientStore
    let locationData = LocationEnvironment.lifecycle
    let serverController: ServerController
    let appStatus: AppStatusModel
    let connectClient: SingleWindowPresenter<ConnectClientWindowController>
    let iCloudSignIn: ICloudSignInPresenter
    /// One controller and one model live for the whole process, so the
    /// window keeps its frame and its address cache; the history itself is
    /// re-read each time it opens.
    let locationWindow: SingleWindowPresenter<LocationWindowController>
    let guidance: GuidanceRouter

    init(hostMode: HostMode) {
        let host = HostDependencies(hostMode)
        activation = host.activation
        let iCloud = LocationEnvironment.iCloud
        self.iCloud = iCloud

        let pairedClients = PairedClientStore(storage: host.pairedClientStorage)
        self.pairedClients = pairedClients
        let pairingCodes = PairingCodeIssuer()

        let approvals = ConnectionApprovalPresenter(
            window: ConnectionApprovalWindowController(activation: host.activation),
            timeout: PhaseDeadline.approvalPrompt,
            clock: .live,
            pairingOutcomes: pairedClients.pairingOutcomes.eraseToAnyPublisher()
        )
        serverController = ServerController(
            networkManager: ServerNetworkManager(
                listener: host.listener,
                pairedClients: pairedClients,
                pairingCodes: pairingCodes,
                entries: host.entries,
                clock: .live,
                prompt: { request in await approvals.present(request) }
            ),
            entries: host.entries
        )
        appStatus = AppStatusModel(
            controller: serverController,
            iCloud: iCloud,
            pairedClients: pairedClients,
            fullDiskAccessGranted: host.fullDiskAccessGranted
        )
        connectClient = SingleWindowPresenter(activation: host.activation) {
            ConnectClientWindowController(
                issuePairingCode: { pairingCodes.issue() },
                pairingCodeEvents: pairingCodes.events.eraseToAnyPublisher(),
                pairedClients: pairedClients
            )
        }
        let iCloudSignIn = ICloudSignInPresenter(session: iCloud, activation: host.activation)
        self.iCloudSignIn = iCloudSignIn
        locationWindow = SingleWindowPresenter(activation: host.activation) {
            LocationWindowController(model: LocationWindowModel.live())
        }
        guidance = GuidanceRouter(status: appStatus, showICloudSignIn: { iCloudSignIn.show() })

        host.launch(iCloud)
    }
}
