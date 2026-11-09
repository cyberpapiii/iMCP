import Foundation
import OSLog

private let log = Logger.service("location.sampler")

/// What the sampler has managed lately. Read by the tools so an answer can
/// say whether the history it is derived from is still being written.
struct LocationSamplerStatus: Sendable, Equatable {
    var isRunning: Bool
    var lastSuccessAt: Date?
    /// The last failure's own words, cleared by the next success.
    var lastFailure: String?
}

/// Refreshes the current user's active iPhone while the app runs and appends
/// its fixes to the history store.
///
/// Apple keeps no history, so a position not recorded as it happens is gone.
/// Each tick asks Apple to locate the one phone being tracked (a fresh fix,
/// which does wake it) and nothing else: waking every device every ten
/// minutes would drain their batteries to record positions nobody asked for.
actor LocationSampler {
    static let interval: Duration = .seconds(LocationPolicy.sampleInterval)

    /// How long a tick trusts the phone an earlier tick chose. Choosing it
    /// costs a request of its own, and the phone rarely changes, so most
    /// ticks go straight to locating it. The limit still lets the sampler
    /// follow the user to a newly active iPhone within the hour.
    static let phoneReuseSeconds: TimeInterval = 3600

    private let store: LocationHistoryStore
    private let peopleLoader: @Sendable () async throws -> [FindMyFriendHistoryFix]
    private let now: @Sendable () -> Date
    private var trackedPhone: (id: String, chosenAt: Date)?
    private var task: Task<Void, Never>?
    private var peopleTasks: [UUID: Task<Void, Never>] = [:]
    private var peopleSamplingAllowed = true
    private var status = LocationSamplerStatus(isRunning: false)

    func currentStatus() -> LocationSamplerStatus { status }

    /// `peopleLoader` reads friends' fixes through the People gate, which in
    /// turn stops this sampler's People work when it closes; the composition
    /// root hands each the other.
    init(
        store: LocationHistoryStore,
        peopleLoader: @escaping @Sendable () async throws -> [FindMyFriendHistoryFix],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.peopleLoader = peopleLoader
        self.now = now
    }

    func start(webClient: FindMyClient?) {
        task?.cancel()
        // A new client has no server context yet, and Apple ignores a locate
        // request without one, so the first tick has to list devices anyway.
        trackedPhone = nil
        status.isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce(webClient: webClient)
                do {
                    try await Task.sleep(for: Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        status.isRunning = false
        status.lastFailure = nil
    }

    /// Prevents new People work and waits until a currently loaded fix can no
    /// longer reach persistence. Web sampling remains independently enabled.
    func quiescePeople() async {
        peopleSamplingAllowed = false
        let inFlight = Array(peopleTasks.values)
        inFlight.forEach { $0.cancel() }
        for task in inFlight {
            await task.value
        }
    }

    func resumePeople() {
        peopleSamplingAllowed = true
    }

    /// One poll. Separate from the loop so a test can drive it directly.
    func sampleOnce(webClient: FindMyClient?) async {
        if let webClient {
            await sampleWeb(client: webClient)
        }
        guard peopleSamplingAllowed, !Task.isCancelled else { return }
        let id = UUID()
        let store = store
        let peopleLoader = peopleLoader
        let peopleTask = Task {
            do {
                let fixes = try await peopleLoader()
                try Task.checkCancellation()
                let written = try await store.record(Self.samples(from: fixes))
                log.debug("Recorded \(written) new local People location samples")
            } catch is CancellationError {
                // Revocation and sampler shutdown deliberately discard a read
                // that has not yet crossed the persistence boundary.
            } catch let error as FindMyPeopleToolError where error.readinessState != nil {
                // People is independently optional. A disabled or incomplete local
                // provider must not stop valid web-device samples.
                log.debug("Local People sampling skipped: \(String(describing: error), privacy: .public)")
            } catch {
                log.error("Local People location sampling failed")
            }
        }
        peopleTasks[id] = peopleTask
        await withTaskCancellationHandler {
            await peopleTask.value
        } onCancel: {
            peopleTask.cancel()
        }
        peopleTasks[id] = nil
    }

    private func sampleWeb(client: FindMyClient) async {
        do {
            let phoneID: String
            if let trackedPhone, now().timeIntervalSince(trackedPhone.chosenAt) < Self.phoneReuseSeconds {
                phoneID = trackedPhone.id
            } else {
                let cached = try await client.snapshot(locate: false)
                try Task.checkCancellation()
                guard let phone = Self.phoneToTrack(in: cached) else {
                    trackedPhone = nil
                    log.error("No current-user iPhone is available for location history")
                    status.lastFailure = "No iPhone of the signed-in user is visible in Find My."
                    return
                }
                phoneID = phone.id
                trackedPhone = (phone.id, now())
            }
            let snapshot = try await client.snapshot(locate: true, selectedDeviceID: phoneID)
            // `start` and `stop` cancel this task without waiting for it. A
            // superseded tick discards what it read, as the People path does.
            try Task.checkCancellation()
            // The located snapshot lists every device again. If it no longer
            // agrees on the phone, the next tick chooses afresh.
            if Self.phoneToTrack(in: snapshot)?.id != phoneID {
                trackedPhone = nil
            }
            let written = try await store.record(Self.samples(from: snapshot))
            status.lastSuccessAt = now()
            status.lastFailure = nil
            log.debug("Recorded \(written) new iPhone location samples")
        } catch ICloudAuthError.trustExpired where !Task.isCancelled {
            // The client has already told the session, which renews it on its
            // own task and hands the sampler the renewed client.
            status.lastFailure = "The iCloud session was rejected; renewing it."
            log.notice("Location sampling session expired; the session is renewing it")
        } catch {
            // A cancelled tick has nothing to report: `start` or `stop`
            // already owns the status.
            guard !Task.isCancelled else { return }
            // A sampler that stopped on the first network hiccup would leave a
            // silent hole in the history. The next tick tries again.
            let reason = sanitizedToolErrorMessage(for: error, fallback: errorTypeName(for: error))
            status.lastFailure = reason
            log.error("Location sampling failed: \(reason, privacy: .public) \(error.localizedDescription)")
        }
    }

    static func samples(from snapshot: FindMySnapshot) -> [LocationSample] {
        let owners = snapshot.owners
        guard let phone = phoneToTrack(in: snapshot) else { return [] }
        return [phone].compactMap { device in
            guard let fix = device.location else { return nil }
            let owner = owners[device.id]
            return LocationSample(
                provider: LocationSampleProvider.web,
                subjectID: device.id,
                subjectKind: LocationSubjectKind.device,
                sourceDeviceID: device.id,
                deviceID: device.id,
                deviceName: device.name,
                personName: owner?.name ?? "Unknown",
                isMe: owner?.isMe ?? false,
                latitude: fix.latitude,
                longitude: fix.longitude,
                accuracyMeters: fix.horizontalAccuracy,
                positionType: fix.positionType,
                timestamp: fix.timestamp
            )
        }
    }

    static func phoneToTrack(in snapshot: FindMySnapshot) -> FindMyDevice? {
        let currentUserDeviceIDs = Set(
            snapshot.people.first(where: \.isMe)?.devices.map(\.id) ?? []
        )
        return snapshot.devices
            .filter {
                currentUserDeviceIDs.contains($0.id)
                    && $0.deviceClass?.caseInsensitiveCompare("iPhone") == .orderedSame
            }
            .max {
                ($0.location?.timestamp ?? .distantPast) < ($1.location?.timestamp ?? .distantPast)
            }
    }

    static func samples(from fixes: [FindMyFriendHistoryFix]) -> [LocationSample] {
        fixes.map { fix in
            LocationSample(
                provider: LocationSampleProvider.people,
                subjectID: fix.identifier,
                subjectKind: LocationSubjectKind.person,
                sourceDeviceID: nil,
                deviceID: fix.identifier,
                deviceName: "Find My People",
                personName: fix.name,
                isMe: false,
                latitude: fix.latitude,
                longitude: fix.longitude,
                accuracyMeters: fix.horizontalAccuracyMeters,
                positionType: nil,
                timestamp: fix.timestamp
            )
        }
    }
}

/// Runs the sampler while Location is switched on, on whichever Find My
/// client the iCloud session has. Each switch and each client change is
/// applied in the order it happened: one task follows the session's client
/// changes, and the next one starts only after the last has stopped.
@MainActor
final class LocationSampling {
    private nonisolated let clientChanges: @MainActor @Sendable () -> AsyncStream<FindMyClient?>
    private nonisolated let start: @Sendable (FindMyClient?) async -> Void
    private nonisolated let stop: @Sendable () async -> Void
    private var following: Task<Void, Never>?
    private var last: Task<Void, Never>?

    nonisolated init(
        clientChanges: @escaping @MainActor @Sendable () -> AsyncStream<FindMyClient?>,
        start: @escaping @Sendable (FindMyClient?) async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.clientChanges = clientChanges
        self.start = start
        self.stop = stop
    }

    nonisolated convenience init(
        sampler: LocationSampler,
        session: @escaping @MainActor @Sendable () -> ICloudSession
    ) {
        self.init(
            clientChanges: { session().liveClientChanges() },
            start: { await sampler.start(webClient: $0) },
            stop: { await sampler.stop() }
        )
    }

    func setEnabled(_ enabled: Bool) {
        let previous = last
        if enabled {
            guard following == nil else { return }
            let changes = clientChanges()
            let start = start
            following = Task {
                await previous?.value
                for await client in changes {
                    await start(client)
                }
            }
            last = following
        } else {
            guard let following else { return }
            following.cancel()
            self.following = nil
            let stop = stop
            last = Task {
                await following.value
                await stop()
            }
        }
    }

    /// Returns once the last switch-off has been applied.
    func settle() async {
        guard following == nil else { return }
        await last?.value
    }
}
