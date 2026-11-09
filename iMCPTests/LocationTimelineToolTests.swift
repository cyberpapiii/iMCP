import XCTest

@testable import iMCP

/// The two primary tools over a recorded history, with Find My unavailable
/// (as it is in a test process): the timeline must describe its holes, and
/// "now" must fall back to the last recorded position and say so.
final class LocationTimelineToolTests: XCTestCase {
    private var directory: URL!
    private var store: LocationHistoryStore!
    private var session: ICloudSession!
    private let now = Date()

    override func setUp() async throws {
        directory = temporaryDirectoryURL()
        store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { self.now })
        // A signed-out session of its own: the test host is the real app,
        // whose shared session may be signed in to a real account.
        let (storage, _) = storageInMemory()
        session = await MainActor.run { ICloudSession(transport: ScriptedTransport(), storage: storage) }
    }

    private func sample(
        minutesAgo: Double,
        latitude: Double = 40.7464,
        longitude: Double = -74.9445,
        accuracy: Double = 15
    ) -> LocationSample {
        LocationSample(
            deviceID: "phone",
            deviceName: "Rob's iPhone",
            personName: "Rob",
            isMe: true,
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracy,
            positionType: "Wifi",
            timestamp: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    /// No address unless a test supplies one: Apple Maps answers or not by
    /// the network's mood, and a test must not depend on it.
    private func service(addresses: @escaping ReverseGeocoder.Loader = { _, _ in nil }) -> LocationService {
        LocationService(
            peopleReadiness: peopleSwitchedOff(),
            historyStore: store,
            session: { [session] in session! },
            sampler: LocationSampler(store: store, peopleLoader: { [] }),
            venueLookup: VenueLookup { _, _, _ in
                [NearbyVenue(name: "Corner Deli", category: "store", meters: 22)]
            },
            addresses: addresses
        )
    }

    private func object(_ result: ToolResult) throws -> [String: Any] {
        guard case .json(let data) = result,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.coderReadCorrupt) }
        return object
    }

    private func iso(_ minutesAgo: Double) -> String {
        now.addingTimeInterval(-minutesAgo * 60).formatted(.iso8601)
    }

    func testHistoryKeepsTheNewestSamplesAndSaysWhenItDroppedSome() async throws {
        _ = try await store.record([30.0, 20, 10].map { sample(minutesAgo: $0) })
        let tool = try XCTUnwrap(service().tools.first { $0.name == "location_history" })

        let cut = try object(try await tool(["limit": .int(2)]))
        XCTAssertEqual(cut["truncated"] as? Bool, true)
        let rows = try XCTUnwrap(cut["samples"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        let times = rows.compactMap { $0["time"] as? String }
        XCTAssertEqual(times, times.sorted(), "oldest first within what is returned")
        XCTAssertEqual(times.last, now.addingTimeInterval(-10 * 60).localISO8601)

        let whole = try object(try await tool(["limit": .int(3)]))
        XCTAssertEqual(whole["truncated"] as? Bool, false)
        XCTAssertEqual((whole["samples"] as? [[String: Any]])?.count, 3)
    }

    func testTheTimelineDescribesGapsAndEndingsInsteadOfBridgingThem() async throws {
        // Home for an hour, five hours of nothing, home again for 30 minutes,
        // then a kilometre away until five minutes ago.
        var samples = stride(from: 480.0, through: 420, by: -10).map { sample(minutesAgo: $0) }
        samples += stride(from: 110.0, through: 80, by: -10).map { sample(minutesAgo: $0) }
        samples += stride(from: 65.0, through: 5, by: -10).map {
            sample(minutesAgo: $0, latitude: 40.7360, longitude: -74.9870)
        }
        _ = try await store.record(samples)
        _ = try await store.setPlace(
            name: "Home",
            latitude: 40.7464,
            longitude: -74.9445,
            radiusMeters: 150,
            source: "manual"
        )
        let service = service()

        let report = try object(
            try await XCTUnwrap(service.tools.first { $0.name == "location_timeline" })([
                "startDate": .string(iso(600)),
                "endDate": .string(iso(0)),
            ])
        )

        XCTAssertEqual(report["device"] as? String, "Rob's iPhone")
        let visits = try XCTUnwrap(report["visits"] as? [[String: Any]])
        XCTAssertEqual(visits.map { $0["endedBy"] as? String }, ["coverageGap", "movement", "ongoing"])
        XCTAssertEqual(visits.map { $0["label"] as? String }.prefix(2), ["Home", "Home"])
        XCTAssertNil(visits[0]["departure"], "a stay that ends in a gap has no departure")
        XCTAssertNotNil(visits[1]["departure"])
        XCTAssertNotNil(visits[1]["departedBefore"])
        XCTAssertNil(visits[2]["place"], "an unnamed place is only 'near' an address")
        XCTAssertEqual(visits[2]["label"] as? String, "unnamed location")

        let gaps = try XCTUnwrap(report["gaps"] as? [[String: Any]])
        XCTAssertEqual(gaps.count, 2, "the leading 120 minutes and the five-hour hole")
        XCTAssertEqual(gaps[1]["minutes"] as? Int, 310)

        let coverage = try XCTUnwrap(report["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["periodPredatesRecording"] as? Bool, true)
        XCTAssertEqual(coverage["gapThresholdMinutes"] as? Int, 30)
        XCTAssertEqual(coverage["sampleCount"] as? Int, samples.count)

        let health = try XCTUnwrap(report["health"] as? [String: Any])
        XCTAssertNotNil(health["iCloud"] as? String)
        XCTAssertNotNil(health["message"], "not signed in must be said, not implied by an empty list")
        XCTAssertTrue((report["note"] as? String)?.contains("gap") ?? false)
    }

    func testARangeWithNoRecordingSaysSoRatherThanReturningNothing() async throws {
        _ = try await store.record([sample(minutesAgo: 5)])
        let service = service()

        let report = try object(
            try await XCTUnwrap(service.tools.first { $0.name == "location_timeline" })([
                "startDate": .string(iso(3_000)),
                "endDate": .string(iso(2_000)),
            ])
        )

        XCTAssertEqual((report["visits"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((report["gaps"] as? [[String: Any]])?.count, 1)
        let note = try XCTUnwrap(report["note"] as? String)
        XCTAssertTrue(note.contains("Recording began"), note)
        XCTAssertTrue(note.contains("No positions were recorded"), note)
    }

    func testNowFallsBackToTheLastRecordedPositionAndCallsItStale() async throws {
        _ = try await store.record([sample(minutesAgo: 95), sample(minutesAgo: 90)])
        let service = service()

        let report = try object(
            try await XCTUnwrap(service.tools.first { $0.name == "location_now" })([:])
        )

        XCTAssertEqual(report["source"] as? String, "lastRecorded")
        XCTAssertEqual(report["device"] as? String, "Rob's iPhone")
        XCTAssertEqual(report["isStale"] as? Bool, true)
        XCTAssertEqual(report["fixAgeMinutes"] as? Int, 90)
        XCTAssertNotNil(report["horizontalAccuracyMeters"])
        let health = try XCTUnwrap(report["health"] as? [String: Any])
        XCTAssertTrue((health["message"] as? String)?.contains("last recorded position") ?? false)
    }

    /// `location_place_set` with `radiusMeters: 40` saved 150 on 2026-09-03:
    /// the SDK decodes a whole number as `.int`, which `doubleValue` rejects.
    func testAWholeNumberRadiusIsHonoured() async throws {
        let service = service()

        let report = try object(
            try await XCTUnwrap(service.tools.first { $0.name == "location_place_set" })([
                "name": .string("Juniper's"),
                "latitude": .double(40.7535143),
                "longitude": .int(-74),
                "radiusMeters": .int(40),
            ])
        )

        XCTAssertEqual(report["radiusMeters"] as? Double, 40)
        XCTAssertEqual(report["longitude"] as? Double, -74)
    }

    /// The tool keeps names as the window does: trimmed, and one place per
    /// name. " Home " from a tool is the window's "Home", not a second place.
    func testAToolNamesAPlaceAsTheWindowDoes() async throws {
        let service = service()
        let set = try XCTUnwrap(service.tools.first { $0.name == "location_place_set" })
        _ = try await set(["name": .string("Home"), "latitude": .double(40.7), "longitude": .double(-73.9)])
        _ = try await set(["name": .string("Office"), "latitude": .double(40.8), "longitude": .double(-73.8)])

        let moved = try object(
            try await set(["name": .string(" Home "), "latitude": .double(41.0), "longitude": .double(-74.0)])
        )
        XCTAssertEqual(moved["name"] as? String, "Home")
        let places = try await store.places()
        XCTAssertEqual(places.map(\.name).sorted(), ["Home", "Office"])
        XCTAssertEqual(places.first { $0.name == "Home" }?.latitude, 41.0)

        do {
            _ = try await set([
                "name": .string(" home\n"), "latitude": .double(40.7), "longitude": .double(-73.9),
                "renameFrom": .string("Office"),
            ])
            XCTFail("expected the taken name to be refused")
        } catch {
            guard case .invalidRequest = error as? LocationHistoryError else { return XCTFail("\(error)") }
        }
        do {
            _ = try await set(["name": .string("  "), "latitude": .double(40.7), "longitude": .double(-73.9)])
            XCTFail("expected an empty name to be refused")
        } catch {
            XCTAssertEqual(error as? LocationHistoryError, .invalidRequest("A place needs a name."))
        }
        let after = try await store.places()
        XCTAssertEqual(after.map(\.name).sorted(), ["Home", "Office"])
    }

    func testDeletingAPlaceRemovesItAndASecondCallReportsNothingToDelete() async throws {
        let service = service()
        _ = try await XCTUnwrap(service.tools.first { $0.name == "location_place_set" })([
            "name": .string("Juniper's"),
            "latitude": .double(40.7535143),
            "longitude": .double(-74.9885),
        ])
        let delete = try XCTUnwrap(service.tools.first { $0.name == "location_place_delete" })

        let first = try object(try await delete(["name": .string("juniper's")]))
        XCTAssertEqual(first["deleted"] as? Bool, true)
        let places = try await store.places()
        XCTAssertTrue(places.isEmpty)

        let second = try object(try await delete(["name": .string("juniper's")]))
        XCTAssertEqual(second["deleted"] as? Bool, false)
    }

    func testDeletingAPlaceRequiresAName() async throws {
        let delete = try XCTUnwrap(service().tools.first { $0.name == "location_place_delete" })
        do {
            _ = try await delete([:])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? LocationHistoryError, .invalidRequest("Place name is required"))
        }
    }

    func testVisitsKeepsItsArrayShapeWithTheNewFields() async throws {
        // The newest sample sits a minute inside the range: `endDate` is exclusive.
        let samples = stride(from: 65.0, through: 5, by: -10).map { sample(minutesAgo: $0) }
        _ = try await store.record(samples)
        let service = service()

        let result = try await XCTUnwrap(service.tools.first { $0.name == "location_visits" })([
            "startDate": .string(iso(120)),
            "endDate": .string(iso(0)),
        ])
        guard case .json(let data) = result,
            let visits = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return XCTFail("expected an array") }

        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits[0]["endedBy"] as? String, "ongoing")
        XCTAssertNotNil(visits[0]["lastObserved"])
        XCTAssertNil(visits[0]["departure"])
        XCTAssertEqual(visits[0]["durationMinutes"] as? Int, 60)
        XCTAssertEqual(visits[0]["sampleCount"] as? Int, 7)
        // Unnamed, so Maps candidates ride along: a hint for the agent, not a name.
        let venues = try XCTUnwrap(visits[0]["nearbyVenues"] as? [[String: Any]])
        XCTAssertEqual(venues.map { $0["name"] as? String }, ["Corner Deli"])
        XCTAssertEqual(venues[0]["meters"] as? Int, 22)
    }
}

extension LocationTimelineToolTests {
    func testVisitsRetriesFailedAddressesAndKeepsNearbyCoordinatesDistinct() async throws {
        var samples = [180.0, 170, 120, 110].map { sample(minutesAgo: $0) }
        samples += [60.0, 50].map { sample(minutesAgo: $0, latitude: 40.74641) }
        _ = try await store.record(samples)
        let counter = Counter()
        let responses: [String?] = [nil, "112 Harbor St", "114 Harbor St"]
        let service = service(addresses: { _, _ in responses[min(counter.increment(), responses.count) - 1] })
        let tool = try XCTUnwrap(service.tools.first { $0.name == "location_visits" })
        guard
            case .json(let data) = try await tool([
                "startDate": .string(iso(200)), "endDate": .string(iso(0)),
            ])
        else { return XCTFail("Expected JSON") }
        let visits = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(visits.count, 3)
        XCTAssertNil(visits[0]["nearAddress"])
        XCTAssertEqual(visits[1]["nearAddress"] as? String, "112 Harbor St")
        XCTAssertEqual(visits[2]["nearAddress"] as? String, "114 Harbor St")
        let calls = counter.value
        XCTAssertEqual(calls, 3)
    }

    func testRepeatedStopsShareAnAddressLookupOnlyWithinOneRequest() async throws {
        _ = try await store.record([180.0, 170, 120, 110].map { sample(minutesAgo: $0) })
        let counter = Counter()
        let service = service(addresses: { _, _ in
            counter.increment()
            return "112 Harbor St"
        })
        let tool = try XCTUnwrap(service.tools.first { $0.name == "location_timeline" })
        for requestNumber in 1 ... 2 {
            let result = try object(
                try await tool([
                    "startDate": .string(iso(200)), "endDate": .string(iso(0)),
                ])
            )
            let visits = try XCTUnwrap(result["visits"] as? [[String: Any]])
            XCTAssertEqual(visits.count, 2)
            XCTAssertEqual(
                visits.compactMap { $0["nearAddress"] as? String },
                ["112 Harbor St", "112 Harbor St"]
            )
            let calls = counter.value
            XCTAssertEqual(calls, requestNumber)
        }
    }
}

extension LocationTimelineToolTests {
    private func friendSample(minutesAgo: Double) -> LocationSample {
        LocationSample(
            provider: LocationSampleProvider.people,
            subjectID: "friend_abc",
            subjectKind: LocationSubjectKind.person,
            deviceID: "friend_abc",
            deviceName: "Find My People",
            personName: "Alex",
            isMe: false,
            latitude: 41,
            longitude: -74,
            accuracyMeters: 10,
            positionType: nil,
            timestamp: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    /// Decision 3: a fresh friend fix is not phone recording. Health and
    /// coverage read the device recording only, as the window does.
    func testTimelineHealthAndCoverageIgnoreFindMyPeopleRows() async throws {
        _ = try await store.record([sample(minutesAgo: 90), sample(minutesAgo: 80)])
        _ = try await store.record([friendSample(minutesAgo: 600), friendSample(minutesAgo: 1)])

        let report = try object(
            try await XCTUnwrap(service().tools.first { $0.name == "location_timeline" })([
                "startDate": .string(iso(300)),
                "endDate": .string(iso(0)),
            ])
        )

        let health = try XCTUnwrap(report["health"] as? [String: Any])
        XCTAssertEqual(health["lastSampleAgeMinutes"] as? Int, 80)
        let coverage = try XCTUnwrap(report["coverage"] as? [String: Any])
        XCTAssertEqual(coverage["recordingBeganAt"] as? String, now.addingTimeInterval(-90 * 60).localISO8601)
        XCTAssertEqual(coverage["periodPredatesRecording"] as? Bool, true)
    }

    /// Decision 5: the fallback reads the timeline's subject (the user's own
    /// samples, else everyone's) and says stale only when the fix is old.
    func testNowFallbackUsesTheTimelinesSubjectAndAgeForStaleness() async throws {
        let familyPhone = { (minutesAgo: Double) in
            LocationSample(
                deviceID: "family-phone",
                deviceName: "Sam's iPhone",
                personName: "Sam",
                isMe: false,
                latitude: 40.7,
                longitude: -73.9,
                accuracyMeters: 15,
                positionType: "Wifi",
                timestamp: self.now.addingTimeInterval(-minutesAgo * 60)
            )
        }
        _ = try await store.record([familyPhone(12), familyPhone(5)])

        let report = try object(try await XCTUnwrap(service().tools.first { $0.name == "location_now" })([:]))

        XCTAssertEqual(report["source"] as? String, "lastRecorded")
        XCTAssertEqual(report["device"] as? String, "Sam's iPhone", "no sample of the user's own, so everyone's")
        XCTAssertEqual(report["isStale"] as? Bool, false, "five minutes old is not stale")
    }

    /// Bug 4: the schema allows `limit: 0`; it returns no samples and says
    /// whether any were there.
    func testHistoryLimitZeroReturnsNothingAndReportsTruncation() async throws {
        let tool = try XCTUnwrap(service().tools.first { $0.name == "location_history" })
        let empty = try object(try await tool(["limit": .int(0)]))
        XCTAssertEqual((empty["samples"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(empty["truncated"] as? Bool, false)

        _ = try await store.record([sample(minutesAgo: 5)])
        let held = try object(try await tool(["limit": .int(0)]))
        XCTAssertEqual((held["samples"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(held["truncated"] as? Bool, true)
    }
}
