import AppKit
import Combine

/// The app's one answer to "is it fine", and to whether each service can
/// reach its data. Holds the current `AppStatus` and republishes it only when
/// it changes, so the menu-bar icon is not redrawn for news that says nothing
/// new.
///
/// Nothing here polls. The status is worked out again when something it is
/// made of says it changed, when the app comes to the front, and when a view
/// asks because it is about to be looked at.
@MainActor
final class AppStatusModel: ObservableObject {
    /// What the model reads each time it works the status out.
    struct Sources {
        /// Every service's switch. The ones that are on are asked whether
        /// they can reach their data.
        var switches: @MainActor () -> [ServiceSwitch]
        var locationEnabled: @MainActor () -> Bool
        var iCloud: @MainActor (_ now: Date) -> ICloudStatus.Report
        var pairedClientCount: @MainActor () -> Int?
        /// Whether this process holds the Full Disk Access grant. Nil leaves
        /// Full Disk Access unknown.
        var fullDiskAccessGranted: @MainActor () -> Bool?
        var listenerFailed: @MainActor () -> Bool
    }

    @Published private(set) var status: AppStatus

    private let sources: Sources
    private var observers: Set<AnyCancellable> = []
    private var fullDiskAccessGranted: Bool?
    private var serviceAccess: [String: Bool] = [:]
    private var scheduledUpdate: Task<Void, Never>?
    private var accessCheck: Task<Void, Never>?

    /// `factsChanged` fires when a row's inputs changed; `grantMayHaveChanged`
    /// fires when a service's access or the Full Disk Access grant may have
    /// too.
    init(
        sources: Sources,
        factsChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        grantMayHaveChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.sources = sources
        self.status = Self.status(from: sources, fullDiskAccessGranted: nil, serviceAccess: [:])
        // `objectWillChange` arrives before the new value is stored, so the
        // read waits for the next turn of the main actor.
        factsChanged
            .sink { [weak self] in self?.scheduleUpdate() }
            .store(in: &observers)
        grantMayHaveChanged
            .sink { [weak self] in self?.refresh() }
            .store(in: &observers)
        refresh()
    }

    /// The app's status, made of the controller's switches, the iCloud
    /// session, and the paired clients.
    convenience init(
        controller: ServerController,
        iCloud: ICloudSession,
        pairedClients: PairedClientStore,
        fullDiskAccessGranted: @escaping @MainActor () -> Bool?
    ) {
        self.init(
            sources: Sources(
                switches: { controller.serviceSwitches },
                locationEnabled: { controller.isLocationEnabled },
                iCloud: { now in ICloudStatus.report(of: iCloud, now: now) },
                pairedClientCount: { pairedClients.clients?.count },
                fullDiskAccessGranted: fullDiskAccessGranted,
                listenerFailed: { controller.isListenerFailed }
            ),
            factsChanged: iCloud.objectWillChange
                .merge(with: pairedClients.objectWillChange)
                .eraseToAnyPublisher(),
            // The controller publishes when a service is switched on or off,
            // and when the listener fails or recovers.
            grantMayHaveChanged: controller.objectWillChange
                .merge(
                    with: NotificationCenter.default
                        .publisher(for: NSApplication.didBecomeActiveNotification)
                        .map { _ in }
                )
                .eraseToAnyPublisher()
        )
    }

    /// Works the whole status out again, asking every service that is on
    /// whether it can reach its data. Views call it when they are about to
    /// be read, which also brings "renewed 4m ago" up to date.
    func refresh() {
        scheduleUpdate()
        accessCheck?.cancel()
        accessCheck = Task { [weak self, sources] in
            let granted = sources.fullDiskAccessGranted()
            var access: [String: Bool] = [:]
            for serviceSwitch in sources.switches() where serviceSwitch.isEnabled {
                access[serviceSwitch.id] = await serviceSwitch.isActivated
            }
            guard !Task.isCancelled, let self else { return }
            self.fullDiskAccessGranted = granted
            self.serviceAccess = access
            self.update()
        }
    }

    /// Runs the service's `activate()`, which may raise a system prompt or
    /// the database picker, and records what it found. The menu toggle and
    /// every Grant button go through here, so a grant made in one place
    /// reaches the badge, the Settings rows, and the Full Disk Access row at
    /// once.
    func requestAccess(for serviceSwitch: ServiceSwitch) async -> ServiceSwitch.AccessRequest {
        let request = await serviceSwitch.requestAccess()
        // A check already under way read the service before the grant.
        refresh()
        serviceAccess[serviceSwitch.id] = request.isActivated
        update()
        return request
    }

    /// Returns once every check and update started so far has finished.
    func settle() async {
        while let pending = scheduledUpdate ?? accessCheck {
            await pending.value
            if scheduledUpdate == pending { scheduledUpdate = nil }
            if accessCheck == pending { accessCheck = nil }
        }
    }

    private func scheduleUpdate() {
        guard scheduledUpdate == nil else { return }
        scheduledUpdate = Task { [weak self] in
            self?.scheduledUpdate = nil
            self?.update()
        }
    }

    private func update() {
        let status = Self.status(
            from: sources,
            fullDiskAccessGranted: fullDiskAccessGranted,
            serviceAccess: serviceAccess
        )
        if status != self.status { self.status = status }
    }

    private static func status(
        from sources: Sources,
        fullDiskAccessGranted: Bool?,
        serviceAccess: [String: Bool]
    ) -> AppStatus {
        let switches = sources.switches()
        let enabled = switches.filter(\.isEnabled)
        let enabledIDs = Set(enabled.map(\.id))
        let access = serviceAccess.filter { enabledIDs.contains($0.key) }
        let dependents = enabled.filter(\.permission.requiresFullDiskAccess)
        // A database bookmark for every dependent service is as good as the grant.
        let everyDependentReachesItsData = !dependents.isEmpty && dependents.allSatisfy { access[$0.id] == true }
        return AppStatus(
            fullDiskAccessGranted: fullDiskAccessGranted.map { $0 || everyDependentReachesItsData },
            serviceAccess: access,
            fullDiskAccessNames: dependents.map(\.name),
            fullDiskAccessCapableNames: ServiceSwitch.fullDiskAccessNames(from: switches),
            locationEnabled: sources.locationEnabled(),
            listenerFailed: sources.listenerFailed(),
            iCloud: sources.iCloud(Date()),
            clients: ClientsStatus.summary(pairedCount: sources.pairedClientCount())
        )
    }
}
