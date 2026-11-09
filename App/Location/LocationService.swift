import Foundation
import JSONSchema
import MCP
import OSLog

private let log = Logger.service("location")

/// Where the people and things in the user's life are, by way of Apple's Find
/// My service.
///
/// The Mac's own CoreLocation position is deliberately not a source here. It
/// answers "where is this computer", which is a different question from "where
/// is the user", and a confidently wrong answer is worse than none. The Mac
/// shows up as one device among the rest, through Find My, or not at all.
final class LocationService: Service {
    /// The session is made on the main actor, after the service.
    typealias SessionProvider = @Sendable @MainActor () -> ICloudSession

    private let peopleReadiness: FindMyPeopleReadiness
    private let historyStore: LocationHistoryStore
    private let sessionProvider: SessionProvider
    /// Location's toggle drives sampling; the session only supplies the client.
    private let sampling: LocationSampling
    private let sampler: LocationSampler
    private let venueLookup: VenueLookup
    private let addresses: ReverseGeocoder.Loader

    /// The app's parts are made once, in `LocationEnvironment`.
    init(
        peopleReadiness: FindMyPeopleReadiness,
        historyStore: LocationHistoryStore,
        session: @escaping SessionProvider,
        sampler: LocationSampler,
        venueLookup: VenueLookup,
        addresses: ReverseGeocoder.Loader? = nil
    ) {
        self.peopleReadiness = peopleReadiness
        self.historyStore = historyStore
        self.sessionProvider = session
        self.sampling = LocationSampling(sampler: sampler, session: session)
        self.sampler = sampler
        self.venueLookup = venueLookup
        self.addresses = addresses ?? ReverseGeocoder.appleMaps(.full)
    }

    /// Signed out, Find My has nothing to say, so the tools are not exposed at
    /// all rather than exposed and failing. A renewal keeps the live client,
    /// so the tools stay listed while it runs.
    var isActivated: Bool {
        get async {
            let webIsReady = await MainActor.run { sessionProvider().hasLiveClient }
            let peopleIsReady = await peopleReadiness.isReady()
            return webIsReady || peopleIsReady
        }
    }

    var permission: ServicePermission { .iCloudSignIn }

    func activate() async throws {
        // Sampling follows the toggle, not this call: `activate()` also runs
        // from the grant-access affordance, and recording history for a
        // service the user has switched off is the bug this exists to avoid.
        guard await isActivated else {
            throw await MainActor.run { ICloudStatus.toolError(of: sessionProvider()) }
        }
    }

    func enablementDidChange(enabled: Bool) async {
        await MainActor.run { sampling.setEnabled(enabled) }
    }

    // MARK: - Arguments

    private static func refresh(_ description: String, default value: Bool) -> ToolArgument<Bool> {
        .bool("refresh", description: description, default: value)
    }
    private static let refreshFix = refresh(
        "Ask Apple to wake the devices for a fresh fix instead of answering from its cache. Slower.",
        default: false
    )
    private static let refreshPhone = refresh(
        "Ask Apple to wake the phone for a fresh fix instead of answering from its cache. Slower.",
        default: false
    )
    /// Documented so a client that sends it is not refused; every call re-reads.
    private static let refreshCache = refresh(
        "Re-read the local Find My cache. Every call already does this; it never wakes a friend's device.",
        default: true
    )

    /// A required string whose absence is the error `missing` makes, so the
    /// client sees the same message as for an unknown name.
    private static func required(
        _ key: String,
        _ description: String,
        allowsEmpty: Bool = false,
        missing: @escaping @Sendable () -> any Error
    ) -> ToolArgument<String> {
        ToolArgument(key, .string(description: description), isRequired: true) { present in
            guard let string = present?.stringValue, allowsEmpty || !string.isEmpty else { throw missing() }
            return string
        }
    }
    private static let friend = required(
        "person",
        "An opaque location_friends identifier or an exact display name."
    ) { FindMyPeopleToolError.friendNotFound("") }
    private static let deviceToRing = required(
        "device",
        "The device's name, as location_devices reports it, or its id when two devices share a name.",
        allowsEmpty: true
    ) { FindMyError.unknownDevice("") }

    private static let window = ToolArgument.dateWindow(
        "Start of the range (inclusive), ISO 8601.",
        "End of the range (exclusive), ISO 8601."
    )
    private static let historyPerson = ToolArgument.string(
        "person",
        description:
            "Only this person's samples. Use a location_friends opaque identifier for a friend, or an unambiguous exact name."
    )
    private static let historyDevice = ToolArgument.string(
        "device",
        description: "Only this device's samples, as location_devices names it."
    )
    private static let visitsPerson = ToolArgument.string(
        "person",
        description:
            "Whose timeline. Use a location_friends opaque identifier for a friend, or an unambiguous exact name. Defaults to everyone visible through the enabled providers."
    )
    private static let visitsDevice = ToolArgument.string(
        "device",
        description:
            "Derive from this device. Defaults to the person's most-moved device, which is normally their phone."
    )
    /// Minutes; 0, the default, keeps every sample.
    private static let interval = ToolArgument<Int>(
        "intervalMinutes",
        .integer(
            description:
                "Keep at most one sample per device per interval. Use it to thin a long range down to something readable."
        )
    ) { present in
        try present.map { try ArgumentValue.wholeNumber($0, "intervalMinutes").bounded(to: 0 ... 10_080) } ?? 0
    }
    private static let historyLimit = ToolArgument.limit(
        "Maximum samples to return. When the range holds more, the newest are returned and truncated is true.",
        default: ListLimit.max
    )
    private static let minimumDwell = ToolArgument.integer(
        "minimumMinutes",
        description: "Ignore stays shorter than this.",
        default: LocationPolicy.defaultDwellMinutes,
        in: 0 ... 10_080,
        documentsRange: false
    )
    private static let placeName = required("name", "What to call the place, e.g. \"Home\".") {
        LocationHistoryError.unknownPlace("")
    }
    private static let placeLatitude = ToolArgument<Double?>.number(
        "latitude",
        description: "Latitude, when naming a fixed point."
    )
    private static let placeLongitude = ToolArgument<Double?>.number(
        "longitude",
        description: "Longitude, when naming a fixed point."
    )
    private static let placePerson = ToolArgument.string(
        "person",
        description:
            "Use this person's current position instead of latitude and longitude. Find My People accepts its opaque identifier or an unambiguous exact name."
    )
    private static let radius = ToolArgument.number(
        "radiusMeters",
        description: "How far from the point still counts as being there, "
            + "\(Int(LocationPolicy.PlaceRadius.bounds.lowerBound)) to \(Int(LocationPolicy.PlaceRadius.bounds.upperBound)).",
        default: LocationPolicy.PlaceRadius.default
    )
    private static let renameFrom = ToolArgument.string(
        "renameFrom",
        description: "The existing place's current name, when renaming."
    )
    private static let notable = ToolArgument.bool(
        "notable",
        description:
            "True for one of the user's own places (home, work, a regular spot); false to only label a spot so stays there carry a name without it counting as significant.",
        default: true
    )
    private static let placeToDelete = required(
        "name",
        "The place's name as location_places reports it, matched case-insensitively."
    ) { LocationHistoryError.invalidRequest("Place name is required") }

    var tools: [Tool] {
        Tool(
            name: "location_people",
            description: """
                Device-derived family locations: the signed-in user and Family Sharing members whose \
                devices share a location. This is not the Find My People sharing list; use \
                location_friends for friends and other non-family People shares.
                """,
            arguments: [Self.refreshFix],
            annotations: .init(
                title: "Locate People",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let snapshot = try await self.snapshot(
                locate: try Self.refreshFix(arguments)
            )
            return try await self.people(from: snapshot)
        }

        Tool(
            name: "location_friends",
            description: """
                The Find My People sharing list from this Mac's local cache, including exact coordinates, \
                accuracy, source fix time, staleness, and motion fields when Apple recorded them. This is \
                separate from location_people, which reports device-derived family locations. Every call \
                re-reads the local cache and never contacts Apple or a geocoding service.
                """,
            arguments: [Self.refreshCache],
            annotations: .init(
                title: "List Find My Friends",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.peopleReadiness.friends()
        }

        Tool(
            name: "location_friend",
            description: """
                One Find My People share from this Mac's local cache. Pass the opaque identifier from \
                location_friends or an exact case-insensitive display name; duplicate names return an \
                ambiguity error instead of guessing. No network or geocoding request is made.
                """,
            arguments: [Self.friend],
            annotations: .init(
                title: "Locate One Find My Friend",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.peopleReadiness.friend(matching: try Self.friend(arguments))
        }

        Tool(
            name: "location_devices",
            description: """
                Every device this iCloud account can see through Find My: name, model, owner, \
                battery, and last known position.
                """,
            arguments: [Self.refreshFix],
            annotations: .init(
                title: "List Devices",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let snapshot = try await self.snapshot(
                locate: try Self.refreshFix(arguments)
            )
            let owners = snapshot.owners
            let now = Date()
            return snapshot.devices.map { DeviceReport($0, owner: owners[$0.id]?.name, now: now) }
        }

        Tool(
            name: "location_ring",
            description: """
                Play a sound on one of the user's own devices, to find it nearby. \
                Family members' devices cannot be rung.
                """,
            arguments: [Self.deviceToRing],
            annotations: .init(
                title: "Play Sound on Device",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let name = try Self.deviceToRing(arguments)
            let played = try await self.withFindMy { client -> String in
                let snapshot = try await client.snapshot()
                let device = try LocationPersonResolver.ownDevice(matching: name, in: snapshot.devices)
                guard device.canPlaySound else {
                    throw FindMyError.soundUnavailable(device.name)
                }
                try await client.playSound(deviceID: device.id)
                return device.name
            }
            return RingResult(device: played, played: true)
        }

        Tool(
            name: "location_history",
            description: """
                Raw recorded positions for a person or device over a date range. iMCP records these \
                itself while it runs, because Apple exposes no location history; nothing before the \
                first run exists. Defaults to the last \(LocationPolicy.Lookback.historyDays) days.
                """,
            arguments: [Self.historyPerson, Self.historyDevice, Self.window, Self.interval, Self.historyLimit],
            annotations: .init(
                title: "Location History",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let range = Self.range(from: try Self.window(arguments))
            let interval = try Self.interval(arguments) * 60
            let person = try Self.historyPerson(arguments)
            let device = try Self.historyDevice(arguments)
            let includePeople = try await self.peopleHistoryAccess(requestedPerson: person)
            // One more than asked for, so `truncated` knows whether the range
            // held more. A limit of 0 asks only that question.
            let limit = try Self.historyLimit(arguments)
            let newest = try await self.historyStore.samples(
                person: person,
                device: device,
                from: range.lowerBound,
                to: range.upperBound,
                everySeconds: interval,
                limit: limit + 1,
                includePeople: includePeople
            )
            return HistoryReport(
                samples: newest.suffix(limit).map(HistorySample.init),
                truncated: newest.count > limit
            )
        }

        Tool(
            name: "location_visits",
            description: """
                A place-by-place timeline for a person over a date range, derived from recorded \
                history: where they stayed put, when they arrived, and how long. Visits inside a \
                named place carry its name. Defaults to the last \(LocationPolicy.Lookback.historyDays) days.
                """,
            arguments: [Self.visitsPerson, Self.visitsDevice, Self.window, Self.minimumDwell],
            annotations: .init(
                title: "Visited Places",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let range = Self.range(from: try Self.window(arguments))
            let person = try Self.visitsPerson(arguments)
            let device = try Self.visitsDevice(arguments)
            let includePeople = try await self.peopleHistoryAccess(requestedPerson: person)
            let samples = try await self.historyStore.samples(
                person: person,
                device: device,
                from: range.lowerBound,
                to: range.upperBound,
                limit: LocationPolicy.historyReadCap,
                includePeople: includePeople
            )
            let dwell = TimeInterval(try Self.minimumDwell(arguments) * 60)
            let places = try await self.historyStore.places(includePeople: includePeople)
            return await self.visits(
                from: samples,
                range: range,
                now: Date(),
                minimumDwell: dwell,
                places: places
            )
        }

        Tool(
            name: "location_now",
            description: """
                Where the user's tracked iPhone is right now, with the fix time, its age, Apple's \
                accuracy radius, whether it is stale, and whether sign-in and recording are healthy. \
                This is the phone's position, which is evidence of the person's, not proof. \
                Inside a place the user named, `place` is that name; otherwise `nearPlace` and \
                `nearPlaceMeters` give the closest named place within a kilometre, so "280 m from \
                Office" can be read as next door to work. `nearbyVenues` lists what Apple Maps has \
                within reach of the fix: candidates for where the user might be, never a finding. \
                Say "probably" with a venue and "at" only with a named place.
                """,
            arguments: [Self.refreshPhone],
            annotations: .init(
                title: "Current Location",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await self.now(refresh: try Self.refreshPhone(arguments))
        }

        Tool(
            name: "location_timeline",
            description: """
                The user's recent timeline from this Mac's own recording of their iPhone: the \
                stays it can support, the holes in the record, when recording covers, and whether \
                recording is healthy. Stays end with "movement" only when the phone was next seen \
                somewhere else; otherwise the ending says why the record stops. Defaults to the \
                last \(LocationPolicy.Lookback.timelineDays) days. A stay inside a place the user named carries that name in `place`; \
                an unnamed stay carries the nearest named place within a kilometre in `nearPlace` \
                and `nearPlaceMeters`, which is the context that turns an address into "next \
                door to work". `nearbyVenues` on an unnamed stay lists what Apple Maps has within \
                reach of the fix, closest first: candidates, never a finding, because one fix sits \
                within its own accuracy of several businesses. Use `location_places` for the \
                user's full list of named places.
                """,
            arguments: [Self.window, Self.minimumDwell],
            annotations: .init(
                title: "Location Timeline",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let window = try Self.window(arguments)
            let now = Date()
            let end = window.end ?? now
            let start =
                window.start
                ?? end.addingTimeInterval(-LocationPolicy.Lookback.seconds(days: LocationPolicy.Lookback.timelineDays))
            let dwell = TimeInterval(try Self.minimumDwell(arguments) * 60)
            return try await self.timeline(range: start ..< end, now: now, minimumDwell: dwell)
        }

        Tool(
            name: "location_places",
            description: """
                The places the user has named, with their coordinates and how wide each one counts \
                as. `kind` is "notable" for the user's own places (home, work, their bar), the \
                ones worth reasoning about, and "label" for a spot they identified once so stays \
                there carry a name; a label is not a place that matters to them. \
                location_visits reports stays inside either by name.
                """,
            arguments: [],
            annotations: .init(
                title: "Named Places",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let includePeople = try await self.peopleHistoryAccess(requestedPerson: nil)
            return try await self.historyStore.places(includePeople: includePeople).map(PlaceReport.init)
        }

        Tool(
            name: "location_place_set",
            description: """
                Name a place, from coordinates or from where a person is right now. Naming a place \
                that already exists moves it; pass renameFrom to rename one instead.
                """,
            arguments: [
                Self.placeName, Self.placeLatitude, Self.placeLongitude, Self.placePerson, Self.radius, Self.renameFrom,
                Self.notable,
            ],
            annotations: .init(
                title: "Name a Place",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.placeName(arguments)
            let radius = try Self.radius(arguments)
            var source = NamedPlaceSource.manual
            let latitude: Double
            let longitude: Double
            if let person = try Self.placePerson(arguments) {
                let resolved = try await self.personResolver.position(for: person)
                latitude = resolved.latitude
                longitude = resolved.longitude
                switch resolved.provider {
                case .web: source = NamedPlaceSource.person
                case .people: source = NamedPlaceSource.findMyPeople
                }
            } else if let value = try Self.placeLatitude(arguments), let other = try Self.placeLongitude(arguments) {
                latitude = value
                longitude = other
            } else {
                throw LocationHistoryError.invalidRequest(
                    "Pass either latitude and longitude, or a person"
                )
            }
            let place = try await self.historyStore.setPlace(
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radius,
                source: source,
                kind: try Self.notable(arguments) ? NamedPlaceKind.notable : NamedPlaceKind.label,
                renaming: try Self.renameFrom(arguments)
            )
            return PlaceReport(place)
        }

        Tool(
            name: "location_place_delete",
            description:
                "Delete a named place by name. Recorded positions are kept; stays there simply stop carrying the name. Reports whether a place was removed.",
            arguments: [Self.placeToDelete],
            annotations: .init(
                title: "Delete a Place",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.placeToDelete(arguments)
            return Value.object([
                "deleted": .bool(try await self.historyStore.deletePlace(named: name)),
                "name": .string(name),
            ])
        }
    }

    // MARK: - Find My

    /// Calls Find My, and when Apple rejected the session, waits for the
    /// session's renewal and calls again on the renewed client. The client
    /// has already told the session; the menu changes with it.
    private func withFindMy<T>(_ body: (FindMyClient) async throws -> T) async throws -> T {
        let session = await MainActor.run { sessionProvider() }
        guard let client = await session.findMy else {
            throw await ICloudStatus.toolError(of: session)
        }
        do {
            return try await body(client)
        } catch ICloudAuthError.trustExpired {
            guard let renewed = await session.renewAfterRejection(of: client) else {
                throw await ICloudStatus.toolError(of: session)
            }
            return try await body(renewed)
        }
    }

    private func snapshot(locate: Bool) async throws -> FindMySnapshot {
        try await withFindMy { try await $0.snapshot(locate: locate) }
    }

    private var personResolver: LocationPersonResolver {
        LocationPersonResolver(readiness: peopleReadiness, snapshot: { try await self.snapshot(locate: false) })
    }

    private func people(from snapshot: FindMySnapshot) async throws -> [PersonLocation] {
        let now = Date()
        var rows: [PersonLocation] = []
        var describer = PointDescriber(addresses: addresses, venueLookup: venueLookup)
        for person in snapshot.people {
            let address = await person.bestFix.asyncMap { best in
                await describer.address(latitude: best.fix.latitude, longitude: best.fix.longitude)
            }
            rows.append(PersonLocation(person, address: address ?? nil, now: now))
        }
        return rows
    }

    // MARK: - History

    /// The range a history question covers. Both ends default rather than
    /// failing, because "where was I lately" is the common question and it
    /// carries no dates.
    private static func range(from window: DateWindow) -> Range<Date> {
        let end = window.end ?? Date()
        let start =
            window.start
            ?? end.addingTimeInterval(-LocationPolicy.Lookback.seconds(days: LocationPolicy.Lookback.historyDays))
        return start ..< end
    }

    /// Whether People rows and People-derived places may be shown. A request
    /// naming a friend fails with the reason; any other request just leaves
    /// them out.
    private func peopleHistoryAccess(requestedPerson: String?) async throws -> Bool {
        let namesFriend = requestedPerson.map(LocationSubjectKey.isFriend) ?? false
        guard await peopleReadiness.isPeopleEnabled() else {
            if namesFriend { throw FindMyPeopleToolError.disabled }
            return false
        }
        do {
            try await peopleReadiness.assertHistoryAccess()
            return true
        } catch {
            if namesFriend { throw error }
            return false
        }
    }

    /// One report per stay, for every subject in `samples`. The rules live in
    /// `VisitInference`; this only chooses the device and words the result.
    ///
    /// Derived on read rather than stored: the dwell threshold is the caller's
    /// to choose, and a stored table would have to be thrown away and rebuilt
    /// every time they chose differently.
    private func visits(
        from samples: [LocationSample],
        range: Range<Date>,
        now: Date,
        minimumDwell: TimeInterval,
        places: [NamedPlace]
    ) async -> [VisitReport] {
        let bySubject = Dictionary(grouping: samples, by: LocationSubjectKey.person(of:))
        var describer = PointDescriber(addresses: addresses, venueLookup: venueLookup)
        var reports: [VisitReport] = []
        for (_, personSamples) in bySubject.sorted(by: { $0.key < $1.key }) {
            let person = personSamples.max(by: { $0.timestamp < $1.timestamp })?.personName ?? "Unknown"
            // One device, not all of them: a Mac sitting at home and a phone out
            // in the world would otherwise interleave into a timeline that
            // teleports. The most-moved device is the one that was carried.
            guard let chosen = VisitInference.mostMovedDevice(in: personSamples) else { continue }
            let timeline = VisitInference.timeline(
                deviceID: chosen,
                samples: personSamples,
                range: range,
                now: now,
                places: places,
                rules: VisitInference.Rules(minimumDwell: minimumDwell)
            )
            for visit in timeline.visits {
                reports.append(VisitReport(visit, person: person, description: await describer.describe(visit)))
            }
        }
        return reports.sorted { $0.arrival < $1.arrival }
    }

    // MARK: - Timeline and now

    private func timeline(range: Range<Date>, now: Date, minimumDwell: TimeInterval) async throws -> TimelineReport {
        let places = try await historyStore.places(includePeople: false)
        let recording = try await historyStore.deviceRecording()
        let health = await health(now: now, latestFixAt: recording?.latest.timestamp)
        let rules = VisitInference.Rules(minimumDwell: minimumDwell)
        let track = try await LocationTrack.read(
            from: historyStore,
            range: range,
            now: now,
            places: places,
            rules: rules
        )
        let person = track.person ?? "Me"
        var describer = PointDescriber(addresses: addresses, venueLookup: venueLookup)
        var visits: [VisitReport] = []
        for visit in track.timeline.visits {
            visits.append(VisitReport(visit, person: person, description: await describer.describe(visit)))
        }
        let timeline = track.timeline
        return TimelineReport(
            person: person,
            device: track.deviceName ?? "none recorded",
            coverage: CoverageReport(
                from: range.lowerBound.localISO8601,
                to: range.upperBound.localISO8601,
                sampleCount: timeline.sampleCount,
                ignoredLowAccuracySamples: timeline.ignoredLowAccuracyCount,
                firstSampleAt: timeline.firstSampleAt?.localISO8601,
                lastSampleAt: timeline.lastSampleAt?.localISO8601,
                expectedIntervalMinutes: LocationPolicy.expectedIntervalMinutes,
                gapThresholdMinutes: Int(rules.maximumGap / 60),
                recordingBeganAt: recording?.began.localISO8601,
                periodPredatesRecording: recording.map { range.lowerBound < $0.began } ?? true
            ),
            gaps: timeline.gaps.map {
                GapReport(from: $0.from.localISO8601, to: $0.to.localISO8601, minutes: Int($0.duration / 60))
            },
            visits: visits,
            health: HealthReport(health, iCloudDetail: await iCloudDetail()),
            note: Self.coverageNote(timeline: timeline, recordingBegan: recording?.began, range: range, now: now)
        )
    }

    private static func coverageNote(
        timeline: DeviceTimeline,
        recordingBegan: Date?,
        range: Range<Date>,
        now: Date
    ) -> String {
        guard let recordingBegan else {
            return
                "Nothing has been recorded yet. Recording starts when Location is on, the app is running, and iCloud is signed in."
        }
        var parts: [String] = []
        if range.lowerBound < recordingBegan {
            parts.append("Recording began \(recordingBegan.localISO8601); nothing exists before that.")
        }
        if timeline.sampleCount == 0 {
            parts.append("No positions were recorded in this range, so no visit can be confirmed or ruled out.")
        } else {
            let covered = Int(timeline.gaps.reduce(0) { $0 + $1.duration } / 60)
            let total = Int(min(range.upperBound, now).timeIntervalSince(range.lowerBound) / 60)
            parts.append(
                "\(timeline.gaps.count) gap(s) totalling \(covered) of \(max(total, 0)) minutes; "
                    + "the phone's whereabouts inside a gap are unknown, not \"still there\"."
            )
        }
        return parts.joined(separator: " ")
    }

    private func now(refresh: Bool) async throws -> NowReport {
        let now = Date()
        // A live answer does not need the history, so a failing store only
        // costs the health line and the place names, and is logged.
        func read<T>(_ what: String, _ body: () async throws -> T?) async -> T? {
            do {
                return try await body()
            } catch {
                log.error("location_now could not read \(what): \(error.localizedDescription)")
                return nil
            }
        }
        let recording = await read("the recording") { try await historyStore.deviceRecording() }
        let places = await read("the places") { try await historyStore.places(includePeople: false) } ?? []
        let health = await health(now: now, latestFixAt: recording?.latest.timestamp)
        let iCloudDetail = await iCloudDetail()
        var describer = PointDescriber(addresses: addresses, venueLookup: venueLookup)
        do {
            let snapshot = try await snapshot(locate: refresh)
            guard let phone = LocationSampler.phoneToTrack(in: snapshot) else {
                throw FindMyError.noDevices
            }
            let fix = phone.location.map {
                NowReport.Fix(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    accuracyMeters: $0.horizontalAccuracy,
                    positionType: $0.positionType,
                    timestamp: $0.timestamp,
                    isOld: $0.isOld
                )
            }
            let description = await fix.asyncMap {
                await describer.describe(latitude: $0.latitude, longitude: $0.longitude, places: places)
            }
            return NowReport(
                person: snapshot.people.first(where: \.isMe)?.name ?? "Me",
                device: phone.name,
                deviceClass: phone.deviceClass,
                source: .findMy,
                fix: fix,
                description: description,
                now: now,
                health: HealthReport(health, iCloudDetail: iCloudDetail)
            )
        } catch {
            // Find My is not answering, or has no phone to answer about. The
            // last recorded position is still an answer, as long as it says
            // how old it is and why it is all there is.
            let recent = try await historyStore.samples(
                person: nil,
                device: nil,
                from: now.addingTimeInterval(
                    -LocationPolicy.Lookback.seconds(days: LocationPolicy.Lookback.historyDays)
                ),
                to: now,
                limit: LocationPolicy.historyReadCap,
                includePeople: false
            )
            guard let last = LocationTrack.subject(of: recent).max(by: { $0.timestamp < $1.timestamp }) else {
                throw error
            }
            let reason = sanitizedToolErrorMessage(for: error, fallback: errorTypeName(for: error))
            return NowReport(
                person: last.personName,
                device: last.deviceName,
                deviceClass: nil,
                source: .lastRecorded,
                fix: NowReport.Fix(
                    latitude: last.latitude,
                    longitude: last.longitude,
                    accuracyMeters: last.accuracyMeters,
                    positionType: last.positionType,
                    timestamp: last.timestamp,
                    isOld: false
                ),
                description: await describer.describe(
                    latitude: last.latitude,
                    longitude: last.longitude,
                    places: places
                ),
                now: now,
                health: HealthReport(
                    health,
                    iCloudDetail: iCloudDetail,
                    message: "Find My did not answer (\(reason)) so this is the last recorded position, not a live one."
                )
            )
        }
    }

    private func health(now: Date, latestFixAt: Date?) async -> LocationHealth {
        let samplerStatus = await sampler.currentStatus()
        return await MainActor.run {
            LocationHealth(session: sessionProvider(), sampler: samplerStatus, latestFixAt: latestFixAt, now: now)
        }
    }

    private func iCloudDetail() async -> String? {
        await MainActor.run { sessionProvider().problem }
    }
}

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
