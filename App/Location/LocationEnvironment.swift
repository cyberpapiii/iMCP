/// Location's long-lived parts, each made once. The sampler reads friends'
/// fixes through the People gate, and the gate stops the sampler's People
/// work before it reports itself closed, so each is handed the other here
/// rather than reaching for the other's singleton. Each is made on first use
/// and starts nothing by being made. The test host makes the iCloud session
/// and `lifecycle` (the history store, the sampler, and the People gate)
/// through `AppEnvironment`, and nothing there restores the session, opens
/// the store, or samples; it lists no services, so `service` is made only
/// when a test asks.
enum LocationEnvironment {
    /// The app's one iCloud session. The menu, the tools, and the windows all
    /// read this one; a second session would mean a second sign-in.
    @MainActor static let iCloud = ICloudSession(webAuthorizer: FindMyWebKitAuthorizer(), clock: .live)
    static let history = LocationHistoryStore()
    static let venues = VenueLookup()
    /// One queue for the Location window's Maps requests.
    static let mapsPacer = MapsPacer()
    static let router = AppleMapsRouter(pacer: mapsPacer)
    static let sampler: LocationSampler = LocationSampler(
        store: history,
        peopleLoader: { try await peopleReadiness.historyFixes() }
    )
    static let peopleReadiness: FindMyPeopleReadiness = .production(
        quiescePeopleSampling: { await sampler.quiescePeople() },
        resumePeopleSampling: { await sampler.resumePeople() }
    )
    static let lifecycle: LocationDataLifecycle = LocationDataLifecycle(
        history: history,
        readiness: peopleReadiness,
        bootstrap: FindMyPeopleBootstrap(readiness: peopleReadiness)
    )
    static let service: LocationService = LocationService(
        peopleReadiness: peopleReadiness,
        historyStore: history,
        session: { iCloud },
        sampler: sampler,
        venueLookup: venues
    )
}
