import CoreLocation
import Foundation
import MapKit

/// How much of the history the window shows, ending on the selected day.
/// The raw value is the number of days.
enum LocationPeriod: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30
    /// Everything the store keeps.
    case all = 90

    var id: Int { rawValue }
    var days: Int { rawValue }

    var name: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }
}

/// What the window knows. Read through `LocationTrack`, `LocationHealth`,
/// and the store the tools use, so the map and `location_timeline` choose
/// the same device, draw the same stays, and judge recording the same way.
@MainActor
final class LocationWindowModel: ObservableObject {
    struct Health: Equatable {
        var level: StatusSummary.Level
        var iCloud: String
        var recording: String
        var lastSeen: String
        var failure: String?

        /// The status strip's one line.
        var line: String { [iCloud, recording, lastSeen].joined(separator: " · ") }
    }

    /// Everything the map draws, worked out once per reload and replaced only
    /// when it differs, so a reload that found nothing new leaves the map alone.
    struct MapScene: Equatable {
        var range: Range<Date>
        var colourRuns: [LocationTimelineItems.ColourRun]
        /// The same journeys as whole paths, for the heat map: drawn in one
        /// colour, so where they overlap they build up.
        var heatPaths: [LocationTimelineItems.Segment]
        /// Steps taken by air, each an arc, drawn apart from the journeys.
        var flights: [LocationTimelineItems.Segment]
        /// Where time was spent, for the heat map's density layer.
        var heatPoints: [LocationTimelineItems.HeatPoint]
        var gapSpans: [LocationTimelineItems.GapSpan]
        /// The owner's places; labels are not drawn.
        var places: [NamedPlace]
        var stops: [LocationTimelineItems.StopPin]
        var trackSpan: ClosedRange<Date>?
        var hasPositions: Bool

        /// Everything drawn, journeys, flights and stops, as one rectangle
        /// of the flat map, so the camera can open on all of it.
        var bounds: MKMapRect? {
            let points =
                heatPaths.flatMap(\.points) + flights.flatMap(\.points)
                + stops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            guard let first = points.first else { return nil }
            return points.dropFirst().reduce(MKMapRect(origin: MKMapPoint(first), size: MKMapSize())) {
                $0.union(MKMapRect(origin: MKMapPoint($1), size: MKMapSize()))
            }
        }
    }

    struct LatestFix: Equatable {
        var coordinate: CLLocationCoordinate2D
        var accuracyMeters: Double?
        var at: Date
        var deviceName: String

        static func == (lhs: LatestFix, rhs: LatestFix) -> Bool {
            lhs.at == rhs.at && lhs.deviceName == rhs.deviceName
        }
    }

    /// The place sheet on show. One at a time; editing a place opens over
    /// the list (`editingPlace`).
    enum PlaceSheet: Identifiable, Equatable {
        case naming(Visit)
        case adding
        case listing

        var id: String {
            switch self {
            case .naming(let visit): return visit.id
            case .adding: return "adding"
            case .listing: return "listing"
            }
        }
    }

    @Published var selectedDay: Date
    @Published var period: LocationPeriod
    @Published private(set) var timeline: DeviceTimeline?
    @Published private(set) var items: [LocationTimelineItems.Item] = []
    /// Nil until the first reload has read the history.
    @Published private(set) var scene: MapScene?
    @Published private(set) var latest: LatestFix?
    /// Nil until the first reload has asked iCloud and the sampler.
    @Published private(set) var health: Health?
    @Published private(set) var loadError: String?
    /// True from the moment a reload the owner asked for starts until its
    /// history is on show. The address and venue lookups that follow fill
    /// rows that are already in place, so they do not count.
    @Published private(set) var isLoading = false
    @Published var selectedItemID: String?
    /// Opening or closing a sheet clears `placeError`; opening one clears
    /// `savedPlace`.
    @Published var sheet: PlaceSheet? { didSet { sheetChanged(opened: sheet != nil) } }
    @Published var editingPlace: NamedPlace? { didSet { sheetChanged(opened: editingPlace != nil) } }
    @Published private(set) var places: [NamedPlace] = []
    /// What was looked up about each unnamed stop, keyed by item id. A stop
    /// that is not in here yet is still being looked up.
    @Published private(set) var lookups: [String: LocationTimelineItems.StopLookup] = [:]
    /// Why the last save or delete in a sheet did not happen, in words for
    /// that sheet.
    @Published private(set) var placeError: String?
    /// The new place the open sheet has just saved. The sheet marks it and
    /// closes itself a moment later.
    @Published private(set) var savedPlace: String?
    /// The street each named place sits on, keyed by place id. A place that
    /// is not in here yet is still being looked up.
    @Published private(set) var placeAddresses: [String: LocationTimelineItems.PlaceAddress] = [:]

    private let store: LocationHistoryStore
    private let venueLookup: VenueLookup
    private let addressLoader: ReverseGeocoder.Loader
    private let router: RouteMatching.Router
    /// Spaces this window's Maps lookups with its route requests. Nil asks
    /// at once, for tests.
    private let pacer: MapsPacer?
    private let savePeriod: (LocationPeriod) -> Void
    /// Maps' answers for the steps seen so far, by leg key.
    private var routes: [String: RouteMatching.Answer] = [:]
    /// The shown track before it is shaped, kept to reshape it as routes
    /// arrive.
    private var shownTrack: (segments: [LocationTimelineItems.Segment], samples: [LocationSample])?
    private var addressCache: [String: String] = [:]
    private let session: @MainActor () -> ICloudSession
    private let samplerStatus: @Sendable () async -> LocationSamplerStatus
    private let clock: WallClock
    private let refreshSeconds: TimeInterval
    private var isRefreshing = false
    private var scheduledTick: (dueAt: Date, task: Task<Void, Never>)?
    private var reloadTask: Task<Void, Never>?
    /// The store's revision when the shown history was read.
    private var loadedRevision: Int?
    private var loadedAt = Date.distantPast

    /// The app's window model, over the same store, session, and sampler the
    /// tools use.
    static func live() -> LocationWindowModel {
        LocationWindowModel(
            store: LocationEnvironment.history,
            venueLookup: LocationEnvironment.venues,
            router: LocationEnvironment.router.router,
            pacer: LocationEnvironment.mapsPacer,
            period: LocationPeriod(rawValue: UserDefaults.standard.integer(forKey: PreferenceKey.locationPeriod))
                ?? .day,
            savePeriod: { UserDefaults.standard.set($0.rawValue, forKey: PreferenceKey.locationPeriod) },
            session: { LocationEnvironment.iCloud },
            samplerStatus: { await LocationEnvironment.sampler.currentStatus() }
        )
    }

    init(
        store: LocationHistoryStore,
        venueLookup: VenueLookup,
        addressLoader: ReverseGeocoder.Loader? = nil,
        router: @escaping RouteMatching.Router = RouteMatching.offline,
        pacer: MapsPacer? = nil,
        period: LocationPeriod = .day,
        savePeriod: @escaping (LocationPeriod) -> Void = { _ in },
        session: @escaping @MainActor () -> ICloudSession,
        samplerStatus: @escaping @Sendable () async -> LocationSamplerStatus,
        clock: WallClock = .live,
        refreshSeconds: TimeInterval = 60
    ) {
        self.store = store
        self.venueLookup = venueLookup
        self.addressLoader = addressLoader ?? ReverseGeocoder.appleMaps(.street)
        self.router = router
        self.pacer = pacer
        self.period = period
        self.savePeriod = savePeriod
        self.session = session
        self.samplerStatus = samplerStatus
        self.clock = clock
        self.refreshSeconds = refreshSeconds
        self.selectedDay = Calendar.current.startOfDay(for: clock.now())
    }

    private func sheetChanged(opened: Bool) {
        placeError = nil
        if opened { savedPlace = nil }
    }

    /// The window's range: the period's days ending at the end of
    /// `selectedDay`.
    var range: Range<Date> {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDay)
        let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let start = calendar.date(byAdding: .day, value: -(period.days - 1), to: dayStart) ?? dayStart
        return start ..< end
    }

    var isToday: Bool { Calendar.current.isDate(selectedDay, inSameDayAs: clock.now()) }

    private var today: Date { Calendar.current.startOfDay(for: clock.now()) }

    /// Whether there is an earlier or later period to step to. All of the
    /// history is already on show, so it has neither.
    var canStep: Bool { period != .all }

    /// Steps by whole periods: a week back from this week is last week.
    func step(by periods: Int) {
        guard
            canStep,
            let next = Calendar.current.date(byAdding: .day, value: periods * period.days, to: selectedDay)
        else { return }
        selectedDay = min(next, today)
        Task { await reload() }
    }

    func showToday() {
        selectedDay = today
        Task { await reload() }
    }

    func setPeriod(_ period: LocationPeriod) {
        self.period = period
        savePeriod(period)
        // All of it ends today; stepping back from there shows nothing.
        if period == .all { selectedDay = today }
        Task { await reload() }
    }

    func startRefreshing() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // The model outlives the window, so an open days later must not
        // resume on the day it was closed on.
        selectedDay = today
        loadedAt = .distantPast
        scheduleTick(at: clock.now())
    }

    func stopRefreshing() {
        isRefreshing = false
        scheduledTick?.task.cancel()
        scheduledTick = nil
    }

    private func scheduleTick(at dueAt: Date) {
        let clock = clock
        let task = Task { [weak self] in
            guard (try? await clock.sleepUntil(dueAt)) != nil else { return }
            guard let self, !Task.isCancelled else { return }
            await self.tick()
            guard !Task.isCancelled, self.isRefreshing else { return }
            self.scheduleTick(at: clock.now().addingTimeInterval(self.refreshSeconds))
        }
        scheduledTick = (dueAt, task)
    }

    /// Returns once nothing the model started is due: every tick whose time
    /// has come has run, and so has the reload in flight. Tests move the
    /// clock and call this instead of sleeping.
    func settle() async {
        while let scheduled = scheduledTick, scheduled.dueAt <= clock.now() {
            await scheduled.task.value
            if scheduledTick?.task == scheduled.task { break }
        }
        await reloadTask?.value
    }

    /// One refresh tick. The sampler writes every ten minutes, so most
    /// ticks only re-age the status strip. The full reload runs when the
    /// store changed, or when the last one is a sampler interval old (the
    /// timeline's trailing gap depends on the clock, not only on samples).
    private func tick() async {
        let now = clock.now()
        if await store.revision != loadedRevision || now.timeIntervalSince(loadedAt) >= LocationPolicy.sampleInterval {
            loadedAt = now
            await reload(showsProgress: false)
        } else {
            let health = await currentHealth(now: now)
            guard !Task.isCancelled, health != self.health else { return }
            self.health = health
        }
    }

    /// Reloads the window, replacing any reload still in flight. An older
    /// reload can then never finish last and overwrite a newer range. The
    /// refresh loop reloads without the working state: nobody asked for it.
    func reload(showsProgress: Bool = true) async {
        reloadTask?.cancel()
        if showsProgress { isLoading = true }
        let task = Task { [self] in await load() }
        reloadTask = task
        await task.value
    }

    private func load() async {
        let now = clock.now()
        var range = self.range
        do {
            loadedRevision = await store.revision
            let recording = try await store.deviceRecording()
            try Task.checkCancellation()
            // All of it starts at the first fix, not 90 days back with a
            // fortnight of "no data" before it.
            if period == .all, let began = recording?.began, began > range.lowerBound, began < range.upperBound {
                range = began ..< range.upperBound
            }
            let places = try await store.places(includePeople: false)
            try Task.checkCancellation()
            let track = try await LocationTrack.read(from: store, range: range, now: now, places: places)
            try Task.checkCancellation()

            // A month of stays, so "seen 6 times" means something even when
            // the window is looking at one day.
            let monthStart = now.addingTimeInterval(
                -LocationPolicy.Lookback.seconds(days: LocationPolicy.Lookback.recurrenceDays)
            )
            let month = try await LocationTrack.read(
                from: store,
                range: monthStart ..< now,
                now: now,
                places: places,
                fallbackDevice: track.timeline.deviceID
            )
            try Task.checkCancellation()
            let timeline = track.timeline
            let recurrence = VisitInference.recurrence(of: timeline.visits, in: month.timeline.visits)

            let deviceSamples = track.deviceSamples
            var items = LocationTimelineItems.items(from: timeline, recurrence: recurrence)
            // All of it begins with this device's first fix; the silence
            // before it is not a gap in anything.
            if period == .all, case .gap = items.first {
                items.removeFirst(items.prefix { if case .gap = $0 { return true } else { return false } }.count)
            }
            let pins = LocationTimelineItems.stopPins(from: items)
            var anchors: [String: CLLocationCoordinate2D] = [:]
            for pin in pins {
                for id in pin.ids {
                    anchors[id] = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
                }
            }
            let segments = LocationTimelineItems.collapsingStays(
                LocationTimelineItems.solidSegments(samples: deviceSamples),
                visits: timeline.visits,
                anchors: anchors
            )
            let shaped = RouteMatching.shape(segments, routes: routes)
            let gapSpans = LocationTimelineItems.gapSpans(samples: deviceSamples, gaps: timeline.gaps)
            let scene = MapScene(
                range: timeline.range,
                colourRuns: LocationTimelineItems.colourRuns(segments: shaped.ground),
                heatPaths: shaped.ground,
                flights: shaped.flights + Self.flights(across: gapSpans),
                heatPoints: LocationTimelineItems.heatPoints(samples: deviceSamples, paths: shaped.ground),
                gapSpans: gapSpans,
                places: places.filter(\.isNotable),
                stops: pins,
                trackSpan: LocationTimelineItems.trackSpan(of: segments),
                hasPositions: timeline.sampleCount > 0
            )
            let latest = recording.map { recording in
                LatestFix(
                    coordinate: CLLocationCoordinate2D(
                        latitude: recording.latest.latitude,
                        longitude: recording.latest.longitude
                    ),
                    accuracyMeters: recording.latest.accuracyMeters,
                    at: recording.latest.timestamp,
                    deviceName: recording.latest.deviceName
                )
            }

            // Every value is published only when it differs, so a reload that
            // found nothing new redraws nothing.
            if timeline != self.timeline { self.timeline = timeline }
            if places != self.places { self.places = places }
            if scene != self.scene { self.scene = scene }
            self.shownTrack = (segments: segments, samples: deviceSamples)
            if items != self.items { self.items = items }
            if latest != self.latest { self.latest = latest }
            if loadError != nil { loadError = nil }
            let unnamed = Set(Self.unnamedStops(in: items).map(\.id))
            let kept = lookups.filter { unnamed.contains($0.key) }
            if kept.count != lookups.count { lookups = kept }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.loadError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        if isLoading { isLoading = false }
        let health = await currentHealth(now: now)
        guard !Task.isCancelled else { return }
        if health != self.health { self.health = health }
        async let stops: Void = lookUpStops()
        async let streets: Void = matchRoutes()
        _ = await (stops, streets)
    }

    /// Asks Maps how each step of the shown track was travelled, the steps
    /// it has not been asked about before, and redraws the track along the
    /// streets as answers arrive: at most every couple of seconds, so a
    /// first look at a busy week fills in without the map redrawing for
    /// every street.
    private func matchRoutes() async {
        guard let track = shownTrack else { return }
        let legs = RouteMatching.legs(in: track.segments)
        let unknown = legs.map(\.key).filter { routes[$0] == nil }
        if !unknown.isEmpty, let saved = try? await store.routes(for: unknown) {
            routes.merge(saved) { _, new in new }
            redrawTrack()
        }
        var drawnAt = ContinuousClock.now
        func keep(_ answer: RouteMatching.Answer, for leg: RouteMatching.Leg) async {
            routes[leg.key] = answer
            try? await store.saveRoute(answer, for: leg.key)
            if ContinuousClock.now - drawnAt > .seconds(2) {
                redrawTrack()
                drawnAt = .now
            }
        }
        for leg in legs where routes[leg.key] == nil {
            guard !Task.isCancelled else { return }
            guard let answer = await router(leg) else { continue }
            await keep(answer, for: leg)
        }
        redrawTrack()
    }

    /// The holes in the record that were flown, as arcs: a phone in flight
    /// mode records nothing between the airports.
    private static func flights(across gaps: [LocationTimelineItems.GapSpan]) -> [LocationTimelineItems.Segment] {
        gaps.filter(\.isFlight).map {
            LocationTimelineItems.Segment(points: RouteMatching.greatCircle(from: $0.from, to: $0.to))
        }
    }

    private func redrawTrack() {
        guard let track = shownTrack, var scene else { return }
        let shaped = RouteMatching.shape(track.segments, routes: routes)
        scene.colourRuns = LocationTimelineItems.colourRuns(segments: shaped.ground)
        scene.heatPaths = shaped.ground
        scene.flights = shaped.flights + Self.flights(across: scene.gapSpans)
        scene.heatPoints = LocationTimelineItems.heatPoints(samples: track.samples, paths: shaped.ground)
        if scene != self.scene { self.scene = scene }
    }

    private static func unnamedStops(in items: [LocationTimelineItems.Item]) -> [(id: String, visit: Visit)] {
        items.compactMap { item in
            guard case .visit(let visit, _) = item, visit.place == nil else { return nil }
            return (item.id, visit)
        }
    }

    private func currentHealth(now: Date) async -> Health {
        let session = session()
        let icloud = ICloudStatus.summary(
            state: session.state,
            lastRenewedAt: session.lastRenewedAt,
            pauseReason: session.pauseReason,
            now: now
        )
        let health = LocationHealth(session: session, sampler: await samplerStatus(), latestFixAt: latest?.at, now: now)
        var level = icloud.level
        if health.recordingNeedsAttention, level == .ok { level = .attention }
        return Health(
            level: level,
            iCloud: "iCloud: \(icloud.detail)",
            recording: health.recordingText,
            lastSeen: LocationTimelineItems.lastSeenText(
                at: latest?.at,
                accuracyMeters: latest?.accuracyMeters,
                now: now
            ),
            failure: health.sampler.lastFailure ?? session.problem
        )
    }

    /// Looks up the venues and street at each unnamed stop, once per spot:
    /// stays at the same building share one answer. Answers are kept in the
    /// history store, so a period seen before fills in at once; the rest are
    /// asked of Maps in turn, each row filling in where it already sits.
    private func lookUpStops() async {
        var stopsAt: [String: [(id: String, visit: Visit)]] = [:]
        var order: [String] = []
        for stop in Self.unnamedStops(in: items) where lookups[stop.id] == nil {
            let key = ReverseGeocoder.buildingKey(latitude: stop.visit.latitude, longitude: stop.visit.longitude)
            if stopsAt[key] == nil { order.append(key) }
            stopsAt[key, default: []].append(stop)
        }
        guard !order.isEmpty else { return }
        func show(_ spot: SpotLookup, at key: String) {
            let lookup = LocationTimelineItems.StopLookup(
                address: spot.address,
                venues: spot.venues,
                suggestion: LocationTimelineItems.suggestion(from: spot.venues)
            )
            for stop in stopsAt[key] ?? [] where lookups[stop.id] != lookup { lookups[stop.id] = lookup }
        }
        let saved = (try? await store.spots(for: order)) ?? [:]
        guard !Task.isCancelled else { return }
        for (key, spot) in saved { show(spot, at: key) }

        for key in order where saved[key] == nil {
            guard !Task.isCancelled, let visit = stopsAt[key]?.first?.visit else { return }
            var found = await venueLookup.cached(latitude: visit.latitude, longitude: visit.longitude, limit: 5)
            if found == nil {
                if let pacer, !(await pacer.turn()) { return }
                found = await venueLookup.lookUp(latitude: visit.latitude, longitude: visit.longitude, limit: 5)
            }
            guard let venues = found else {
                // Maps refused or did not answer: this spot is asked again
                // on a later load, and the queue waits before the next.
                await pacer?.refused()
                continue
            }
            guard !Task.isCancelled else { return }
            if cachedStreet(latitude: visit.latitude, longitude: visit.longitude) == nil, let pacer,
                !(await pacer.turn())
            {
                return
            }
            let address = await street(latitude: visit.latitude, longitude: visit.longitude)
            guard !Task.isCancelled else { return }
            let spot = SpotLookup(venues: venues, address: address)
            // No street may be Maps refusing, not the spot having none; that
            // one is kept for this run only and asked again next time.
            if address != nil { try? await store.saveSpot(spot, for: key) }
            show(spot, at: key)
        }
    }

    /// Looks up the street of each named place for the places sheet, one at a
    /// time, publishing each as it arrives. Shares the stops' address cache,
    /// so a place the sidebar already looked up costs nothing. A place Maps
    /// had no street for is asked about again each time the sheet opens.
    func lookUpPlaceAddresses() async {
        let known = Set(places.map(\.id))
        let kept = placeAddresses.filter { known.contains($0.key) }
        if kept.count != placeAddresses.count { placeAddresses = kept }
        for place in places {
            if case .street = placeAddresses[place.id] { continue }
            let street = await street(latitude: place.latitude, longitude: place.longitude)
            guard !Task.isCancelled else { return }
            let address = street.map(LocationTimelineItems.PlaceAddress.street) ?? .unknown
            if placeAddresses[place.id] != address { placeAddresses[place.id] = address }
        }
    }

    /// The street at a spot, asked for once per spot for as long as the app
    /// runs. A spot with no answer is asked again next time.
    private func street(latitude: Double, longitude: Double) async -> String? {
        let key = ReverseGeocoder.buildingKey(latitude: latitude, longitude: longitude)
        if let cached = addressCache[key] { return cached }
        let street = await addressLoader(latitude, longitude)
        guard !Task.isCancelled else { return nil }
        addressCache[key] = street
        return street
    }

    /// The street already looked up at a spot, if any. Never asks the network.
    func cachedStreet(latitude: Double, longitude: Double) -> String? {
        addressCache[ReverseGeocoder.buildingKey(latitude: latitude, longitude: longitude)]
    }

    /// The venues near a stay, closest first, for the naming sheet's menu.
    /// Looked up on demand when the sidebar has not fetched them yet.
    func candidates(for visit: Visit) async -> [NearbyVenue] {
        if let known = lookups[visit.id]?.venues { return known }
        return await venueLookup.venues(latitude: visit.latitude, longitude: visit.longitude, limit: 5)
    }

    /// Accepts a guessed venue as the name of the stay's spot. Centred on the
    /// stay, not on the venue's pin, and sized for a storefront.
    /// There is no sheet to show a failure in, so it goes to the status strip.
    func accept(_ venue: NearbyVenue, for visit: Visit) async {
        do {
            try await createPlace(
                name: venue.name,
                latitude: visit.latitude,
                longitude: visit.longitude,
                radiusMeters: LocationPolicy.PlaceRadius.storefront,
                kind: NamedPlaceKind.label
            )
            await reload()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Saves a place at a coordinate the user chose, such as a Maps search
    /// result. Nearby recorded fixes may belong to another entrance or
    /// street address, so the coordinate is kept as given.
    func addPlace(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        kind: String = NamedPlaceKind.notable
    ) async {
        placeError = nil
        let isNew = LocationTimelineItems.addsPlace(name: name, kind: kind, renaming: nil, existing: places)
        let saved: NamedPlace
        do {
            saved = try await createPlace(
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters,
                kind: kind
            )
        } catch {
            placeError = LocationTimelineItems.saveFailureText(name: name, reason: Self.reason(for: error))
            return
        }
        if sheet == .adding {
            if isNew {
                savedPlace = saved.name
            } else {
                sheet = nil
            }
        }
        await reload()
    }

    /// Changes a place from the places list: its name, its centre (a new
    /// address the user searched for), and its radius. Its kind and source
    /// stay.
    func editPlace(
        _ place: NamedPlace,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double
    ) async {
        placeError = nil
        let saved: NamedPlace
        do {
            saved = try await store.updatePlace(
                id: place.id,
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters,
                kind: place.kind
            )
        } catch {
            placeError = LocationTimelineItems.saveFailureText(name: name, reason: Self.reason(for: error))
            return
        }
        placeAddresses.removeValue(forKey: place.id)
        savedPlace = saved.name
        await reload()
    }

    func deletePlace(_ place: NamedPlace) async {
        placeError = nil
        do {
            try await store.deletePlace(id: place.id)
            await reload()
        } catch {
            placeError = LocationTimelineItems.deleteFailureText(name: place.name, reason: Self.reason(for: error))
        }
    }

    /// Names a stop. An unnamed stop gets a place centred on it; a stop that
    /// already has one renames that place where it is, so a place found by
    /// address search never moves to where the phone happened to be.
    func name(
        _ visit: Visit,
        as name: String,
        radiusMeters: Double,
        kind: String = NamedPlaceKind.notable
    ) async {
        placeError = nil
        let isNew = LocationTimelineItems.addsPlace(name: name, kind: kind, renaming: visit.place, existing: places)
        let saved: NamedPlace
        do {
            if let place = visit.place {
                saved = try await store.updatePlace(
                    id: place.id,
                    name: name,
                    radiusMeters: radiusMeters,
                    kind: kind
                )
            } else {
                saved = try await createPlace(
                    name: name,
                    latitude: visit.latitude,
                    longitude: visit.longitude,
                    radiusMeters: radiusMeters,
                    kind: kind
                )
            }
        } catch {
            placeError = LocationTimelineItems.saveFailureText(name: name, reason: Self.reason(for: error))
            return
        }
        if case .naming = sheet {
            if isNew {
                savedPlace = saved.name
            } else {
                sheet = nil
            }
        }
        await reload()
    }

    /// Why a save or delete failed, in words fit for a sheet. The store's own
    /// errors already are; anything else is a file-system detail.
    private static func reason(for error: Error) -> String {
        sanitizedToolErrorMessage(for: error, fallback: "The recorded history could not be changed. Try again.")
    }

    /// Creates a place, or moves the one that already has the name.
    @discardableResult
    private func createPlace(
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        kind: String
    ) async throws -> NamedPlace {
        try await store.setPlace(
            name: name,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            source: NamedPlaceSource.manual,
            kind: kind
        )
    }
}
