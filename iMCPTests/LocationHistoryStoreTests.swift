import CoreLocation
import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

final class LocationHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: LocationHistoryStore!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
        // Fixture timestamps sit at 1_700_000_000. Pin "now" near them so
        // retention prune does not delete the rows the other tests just wrote.
        store = LocationHistoryStore(
            url: directory.appendingPathComponent("history.sqlite"),
            now: { Date(timeIntervalSince1970: 1_700_000_000 + 40 * 86_400) }
        )
    }

    override func tearDownWithError() throws {
        store = nil
    }

    private func sample(
        device: String = "phone",
        latitude: Double = 40.7,
        longitude: Double = -73.9,
        secondsFromNow: TimeInterval
    ) -> LocationSample {
        LocationSample(
            deviceID: device,
            deviceName: "Rob's iPhone",
            personName: "Rob",
            isMe: true,
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: 10,
            positionType: "GPS",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + secondsFromNow)
        )
    }

    private func walSize() -> Int {
        let wal = directory.appendingPathComponent("history.sqlite-wal")
        return (try? Data(contentsOf: wal))?.count ?? 0
    }

    func testRoutesAndSpotsAreKeptAndGoWithTheHistory() async throws {
        let street = [
            CLLocationCoordinate2D(latitude: 40.7, longitude: -73.9),
            CLLocationCoordinate2D(latitude: 40.71, longitude: -73.9),
        ]
        try await store.saveRoute(.path(street), for: "walk")
        try await store.saveRoute(.none, for: "river")
        let spot = SpotLookup(venues: [NearbyVenue(name: "Cafe", category: "cafe", meters: 12)], address: "1 Main St")
        try await store.saveSpot(spot, for: "corner")
        let spots = try await store.spots(for: ["corner"])
        XCTAssertEqual(spots["corner"], spot)
        let saved = try await store.routes(for: ["walk", "river", "unknown"])
        guard case .path(let points) = saved["walk"] else { return XCTFail("the route is kept") }
        XCTAssertEqual(points.map(\.latitude), [40.7, 40.71])
        guard case .some(.none) = saved["river"] else { return XCTFail("no route is remembered too") }
        XCTAssertNil(saved["unknown"])

        try await store.deleteSamples()
        let afterDeleting = try await store.routes(for: ["walk", "river"])
        XCTAssertTrue(afterDeleting.isEmpty)
        let spotsAfterDeleting = try await store.spots(for: ["corner"])
        XCTAssertTrue(spotsAfterDeleting.isEmpty)
    }

    func testDeletingHistoryLeavesNoRecoverableRowsOnDisk() async throws {
        let marker = "SECURE-DELETE-MARKER-7F3A"
        // Enough rows to span several pages: emptying the table frees whole
        // pages, and only `secure_delete = ON` overwrites those.
        let rows = (0 ..< 400).map { sample(device: "\(marker)-\($0)", secondsFromNow: TimeInterval($0)) }
        _ = try await store.record(rows)
        try await store.deleteSamples()

        let main = try Data(contentsOf: directory.appendingPathComponent("history.sqlite"))
        XCTAssertNil(main.range(of: Data(marker.utf8)))
        XCTAssertEqual(walSize(), 0)
    }

    func testDeletingPeopleHistoryTruncatesTheWAL() async throws {
        _ = try await store.record([sample(secondsFromNow: 0)])
        try await store.deletePeopleSamples()
        XCTAssertEqual(walSize(), 0)
    }

    func testRecordingTheSameCachedFixTwiceStoresItOnce() async throws {
        let fix = sample(secondsFromNow: 0)
        let first = try await store.record([fix])
        let second = try await store.record([fix])
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0)

        let rows = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(rows, [fix])
    }

    func testRecordingTheSameFixRefreshesMutableDisplayNames() async throws {
        let original = sample(secondsFromNow: 0)
        let renamed = LocationSample(
            provider: original.provider,
            subjectID: original.subjectID,
            subjectKind: original.subjectKind,
            sourceDeviceID: original.sourceDeviceID,
            deviceID: original.deviceID,
            deviceName: "Rob's New iPhone",
            personName: "Robert",
            isMe: original.isMe,
            latitude: 0,
            longitude: 0,
            accuracyMeters: nil,
            positionType: nil,
            timestamp: original.timestamp
        )

        let inserted = try await store.record([original])
        let updated = try await store.record([renamed])
        let unchanged = try await store.record([renamed])
        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(unchanged, 0)

        let rows = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].deviceName, "Rob's New iPhone")
        XCTAssertEqual(rows[0].personName, "Robert")
        XCTAssertEqual(rows[0].latitude, original.latitude)
        XCTAssertEqual(rows[0].longitude, original.longitude)
    }

    func testDownsamplingKeepsOneSamplePerIntervalPerDevice() async throws {
        var samples: [LocationSample] = []
        for minute in 0 ..< 10 {
            samples.append(sample(secondsFromNow: TimeInterval(minute * 60)))
        }
        _ = try await store.record(samples)

        let thinned = try await store.samples(
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_001_000),
            everySeconds: 300
        )
        // Buckets are absolute, not relative to the first sample, so ten
        // minutes of one-minute samples land in three of them.
        XCTAssertEqual(thinned.count, 3)
    }

    func testAFullLimitKeepsTheNewestSamplesInTimeOrder() async throws {
        let samples = (0 ..< 5).map { sample(secondsFromNow: TimeInterval($0 * 60)) }
        _ = try await store.record(samples)

        let rows = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            limit: 2
        )

        XCTAssertEqual(rows, Array(samples.suffix(2)))
    }

    func testNamingAPlaceTwiceMovesItInsteadOfAddingASecond() async throws {
        _ = try await store.setPlace(
            name: "Home",
            latitude: 40.7,
            longitude: -73.9,
            radiusMeters: 150,
            source: "manual"
        )
        _ = try await store.setPlace(
            name: "Home",
            latitude: 41.0,
            longitude: -74.0,
            radiusMeters: 200,
            source: "manual"
        )
        let places = try await store.places()
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.latitude, 41.0)
        XCTAssertEqual(places.first?.radiusMeters, 200)
    }

    func testRenamingAPlaceThatDoesNotExistSaysSo() async throws {
        do {
            _ = try await store.setPlace(
                name: "Office",
                latitude: 40.7,
                longitude: -73.9,
                radiusMeters: 150,
                source: "manual",
                renaming: "Work"
            )
            XCTFail("Expected an unknown-place error")
        } catch let error as LocationHistoryError {
            XCTAssertEqual(error, .unknownPlace("Work"))
        }
    }

    func testAPlaceWithImpossibleNumbersIsRejected() async throws {
        let bad: [(latitude: Double, longitude: Double, radius: Double)] = [
            (999, -73.9, 150), (.nan, -73.9, 150), (40.7, 181, 150),
            (40.7, -73.9, -1), (40.7, -73.9, 1e9), (40.7, -73.9, .nan),
        ]
        for value in bad {
            do {
                _ = try await store.setPlace(
                    name: "Bad",
                    latitude: value.latitude,
                    longitude: value.longitude,
                    radiusMeters: value.radius,
                    source: "manual"
                )
                XCTFail("Expected \(value) to be rejected")
            } catch let error as LocationHistoryError {
                guard case .invalidRequest = error else { return XCTFail("\(error)") }
            }
        }
        let places = try await store.places()
        XCTAssertTrue(places.isEmpty)
    }

    func testRenamingOntoAnotherPlacesNameIsRejected() async throws {
        for name in ["Home", "Office"] {
            _ = try await store.setPlace(
                name: name,
                latitude: 40.7,
                longitude: -73.9,
                radiusMeters: 150,
                source: "manual"
            )
        }
        do {
            _ = try await store.setPlace(
                name: "home",
                latitude: 40.7,
                longitude: -73.9,
                radiusMeters: 150,
                source: "manual",
                renaming: "Office"
            )
            XCTFail("Expected the rename to be rejected")
        } catch let error as LocationHistoryError {
            guard case .invalidRequest = error else { return XCTFail("\(error)") }
        }
        let names = try await store.places().map(\.name)
        XCTAssertEqual(names, ["Home", "Office"])
    }

    func testAPlaceContainsAPointInsideItsRadius() {
        let place = NamedPlace(
            id: "1",
            name: "Home",
            latitude: 40.7,
            longitude: -73.9,
            radiusMeters: 150,
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(place.contains(latitude: 40.7001, longitude: -73.9001))
        XCTAssertFalse(place.contains(latitude: 40.75, longitude: -73.9))
    }

    func testSamplesOlderThanTheRetentionWindowAreDeleted() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store = LocationHistoryStore(
            url: directory.appendingPathComponent("pruned.sqlite"),
            now: { now }
        )
        let old = LocationSample(
            deviceID: "phone",
            deviceName: "Rob's iPhone",
            personName: "Rob",
            isMe: true,
            latitude: 40.7,
            longitude: -73.9,
            accuracyMeters: 10,
            positionType: "GPS",
            timestamp: now.addingTimeInterval(-(LocationHistoryStore.retention + 86_400))
        )
        let kept = LocationSample(
            deviceID: "phone",
            deviceName: "Rob's iPhone",
            personName: "Rob",
            isMe: true,
            latitude: 40.8,
            longitude: -74.0,
            accuracyMeters: 10,
            positionType: "GPS",
            timestamp: now.addingTimeInterval(-30 * 86_400)
        )
        _ = try await store.record([old, kept])

        let rows = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(rows, [kept])
    }

    func testUnavailableErrorDoesNotCarryStoreDetail() {
        let message = sanitizedToolErrorMessage(for: LocationHistoryError.unavailable)
        XCTAssertEqual(message, "The location history store is unavailable.")
    }

    func testSamplingSkipsDevicesWithNoFixAndCreditsTheirOwner() {
        let located = FindMyDevice(
            id: "phone",
            name: "Rob's iPhone",
            model: "iPhone 16e",
            deviceClass: "iPhone",
            batteryLevel: 0.5,
            batteryStatus: "NotCharging",
            isThisDevice: false,
            ownerID: nil,
            canPlaySound: true,
            location: FindMyFix(
                latitude: 40.7,
                longitude: -73.9,
                horizontalAccuracy: 12,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                positionType: "GPS",
                isOld: false
            )
        )
        let unlocated = FindMyDevice(
            id: "buds",
            name: "Rob's Beats",
            model: nil,
            deviceClass: nil,
            batteryLevel: nil,
            batteryStatus: nil,
            isThisDevice: false,
            ownerID: nil,
            canPlaySound: false,
            location: nil
        )
        let snapshot = FindMySnapshot(
            devices: [located, unlocated],
            people: [
                FindMyPerson(id: nil, name: "Rob", isMe: true, devices: [located, unlocated])
            ]
        )

        let samples = LocationSampler.samples(from: snapshot)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.deviceID, "phone")
        XCTAssertEqual(samples.first?.personName, "Rob")
        XCTAssertEqual(samples.first?.isMe, true)
    }

    func testSamplingRecordsOnlyCurrentUsersIPhone() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        func device(id: String, class deviceClass: String) -> FindMyDevice {
            FindMyDevice(
                id: id,
                name: id,
                model: deviceClass,
                deviceClass: deviceClass,
                batteryLevel: 0.5,
                batteryStatus: "NotCharging",
                isThisDevice: false,
                ownerID: nil,
                canPlaySound: true,
                location: FindMyFix(
                    latitude: 40.7,
                    longitude: -73.9,
                    horizontalAccuracy: 12,
                    timestamp: timestamp,
                    positionType: "GPS",
                    isOld: false
                )
            )
        }
        let phone = device(id: "phone", class: "iPhone")
        let mac = device(id: "mac", class: "MacBookPro")
        let accessory = device(id: "buds", class: "Accessory")
        let snapshot = FindMySnapshot(
            devices: [phone, mac, accessory],
            people: [FindMyPerson(id: nil, name: "Rob", isMe: true, devices: [phone, mac, accessory])]
        )

        let samples = LocationSampler.samples(from: snapshot)

        XCTAssertEqual(samples.map(\.deviceID), ["phone"])
    }

    func testPeopleHistoryUsesStableIdentityGateAndFriendOnlyPurge() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        let first = LocationSample(
            provider: LocationSampleProvider.people,
            subjectID: "friend_first",
            subjectKind: LocationSubjectKind.person,
            deviceID: "friend_first",
            deviceName: "Find My People",
            personName: "Alex",
            isMe: false,
            latitude: 40.1,
            longitude: -73.1,
            accuracyMeters: 8,
            positionType: nil,
            timestamp: timestamp
        )
        let renamed = LocationSample(
            provider: LocationSampleProvider.people,
            subjectID: "friend_first",
            subjectKind: LocationSubjectKind.person,
            deviceID: "friend_first",
            deviceName: "Find My People",
            personName: "Alexandra",
            isMe: false,
            latitude: 40.2,
            longitude: -73.2,
            accuracyMeters: 8,
            positionType: nil,
            timestamp: timestamp.addingTimeInterval(60)
        )
        let duplicateName = LocationSample(
            provider: LocationSampleProvider.people,
            subjectID: "friend_second",
            subjectKind: LocationSubjectKind.person,
            deviceID: "friend_second",
            deviceName: "Find My People",
            personName: "Alex",
            isMe: false,
            latitude: 41,
            longitude: -74,
            accuracyMeters: 10,
            positionType: nil,
            timestamp: timestamp
        )
        let web = sample(device: "phone", secondsFromNow: 123)

        let written = try await store.record([first, first, renamed, duplicateName, web])
        XCTAssertEqual(written, 4)
        let hidden = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(hidden, [web])

        let stable = try await store.samples(
            person: "friend_first",
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            includePeople: true
        )
        XCTAssertEqual(stable.map(\.personName), ["Alex", "Alexandra"])
        XCTAssertEqual(Set(stable.map(\.subjectID)), ["friend_first"])

        do {
            _ = try await store.samples(
                person: "Alex",
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 2_000_000_000),
                includePeople: true
            )
            XCTFail("Expected duplicate-name ambiguity")
        } catch let error as LocationHistoryError {
            XCTAssertEqual(
                error,
                .ambiguousPerson("Alex", identifiers: ["friend_first", "friend_second"])
            )
        }

        _ = try await store.setPlace(
            name: "Friend Place",
            latitude: 40,
            longitude: -73,
            radiusMeters: 100,
            source: LocationSampleProvider.people
        )
        _ = try await store.setPlace(
            name: "Manual Place",
            latitude: 41,
            longitude: -74,
            radiusMeters: 100,
            source: "manual"
        )
        let gatedPlaces = try await store.places(includePeople: false)
        XCTAssertEqual(gatedPlaces.map(\.name), ["Manual Place"])

        try await store.deletePeopleSamples()
        let remaining = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            includePeople: true
        )
        XCTAssertEqual(remaining, [web])
        let retainedPlaces = try await store.places()
        XCTAssertEqual(retainedPlaces.count, 2)
    }

    func testHistoryNameAmbiguityUsesProviderScopedLogicalPeople() async throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let webPhone = sample(device: "phone", secondsFromNow: 0)
        let webWatch = sample(device: "watch", secondsFromNow: 60)
        _ = try await store.record([webPhone, webWatch])

        // Several web devices are one logical person and must not be ambiguous.
        let webRows = try await store.samples(
            person: "Rob",
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            includePeople: true
        )
        XCTAssertEqual(webRows.count, 2)

        _ = try await store.record([
            LocationSample(
                provider: LocationSampleProvider.people,
                subjectID: "friend_rob",
                subjectKind: LocationSubjectKind.person,
                deviceID: "friend_rob",
                deviceName: "Find My People",
                personName: "Rob",
                isMe: false,
                latitude: 41,
                longitude: -74,
                accuracyMeters: 5,
                positionType: nil,
                timestamp: time
            )
        ])

        do {
            _ = try await store.samples(
                person: "Rob",
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 2_000_000_000),
                includePeople: true
            )
            XCTFail("Expected cross-provider ambiguity")
        } catch let error as LocationHistoryError {
            XCTAssertEqual(
                error,
                .ambiguousPerson(
                    "Rob",
                    identifiers: ["find-my-web:rob", "friend_rob"]
                )
            )
        }
    }

    func testLegacyHistoryMigratesAdditivelyAndKeepsRows() async throws {
        store = nil
        let url = directory.appendingPathComponent("legacy.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let legacySQL = """
            CREATE TABLE samples (
                device_id TEXT NOT NULL, device_name TEXT NOT NULL,
                person_name TEXT NOT NULL, is_me INTEGER NOT NULL,
                latitude REAL NOT NULL, longitude REAL NOT NULL,
                accuracy REAL, position_type TEXT, timestamp REAL NOT NULL,
                PRIMARY KEY (device_id, timestamp)
            );
            CREATE TABLE places (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, latitude REAL NOT NULL,
                longitude REAL NOT NULL, radius REAL NOT NULL, source TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            INSERT INTO samples VALUES
                ('legacy-phone', 'Old iPhone', 'Rob', 1, 40.7, -73.9, 10, 'GPS', 1700000000);
            """
        XCTAssertEqual(sqlite3_exec(db, legacySQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        store = LocationHistoryStore(
            url: url,
            now: { Date(timeIntervalSince1970: 1_700_000_000 + 40 * 86_400) }
        )
        let migrated = try await store.samples(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].provider, LocationSampleProvider.web)
        XCTAssertEqual(migrated[0].subjectID, "legacy-phone")
        XCTAssertEqual(migrated[0].sourceDeviceID, "legacy-phone")
    }

    func testHistoryFilesAreOwnerOnly() async throws {
        _ = try await store.record([sample(secondsFromNow: 0)])
        let url = await store.fileURL
        let manager = FileManager.default
        let directoryAttributes = try manager.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let fileAttributes = try manager.attributesOfItem(atPath: url.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for suffix in ["-wal", "-shm"] where manager.fileExists(atPath: url.path + suffix) {
            let attributes = try manager.attributesOfItem(atPath: url.path + suffix)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testPeopleSamplerRunsWithoutWebAndPreservesOriginalFixTime() async throws {
        let fix = FindMyFriendHistoryFix(
            identifier: "friend_stable",
            name: "Robin",
            latitude: 42,
            longitude: -72,
            horizontalAccuracyMeters: 5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_456)
        )
        let sampler = LocationSampler(store: store, peopleLoader: { [fix] })
        await sampler.sampleOnce(webClient: nil)

        let rows = try await store.samples(
            person: fix.identifier,
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            includePeople: true
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].subjectID, fix.identifier)
        XCTAssertEqual(rows[0].timestamp, fix.timestamp)
    }

    func testPeopleSamplerQuiesceCancelsBeforePersistence() async throws {
        let gate = AsyncGate()
        let fix = FindMyFriendHistoryFix(
            identifier: "friend_stable",
            name: "Robin",
            latitude: 42,
            longitude: -72,
            horizontalAccuracyMeters: 5,
            timestamp: Date(timeIntervalSince1970: 1_700_000_456)
        )
        let sampler = LocationSampler(
            store: store,
            peopleLoader: {
                await gate.wait()
                try Task.checkCancellation()
                return [fix]
            }
        )
        let sample = Task { await sampler.sampleOnce(webClient: nil) }
        await gate.waitUntilWaiting()
        await sampler.quiescePeople()
        await sample.value

        let rows = try await store.samples(
            person: fix.identifier,
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 2_000_000_000),
            includePeople: true
        )
        XCTAssertTrue(rows.isEmpty)
    }

    /// Switching Location off and on again must reach the sampler in that
    /// order: a start that overtook the stop before it would leave the
    /// sampler stopped while the toggle says on.
    @MainActor
    func testSamplingAppliesSwitchesInTheOrderTheyHappened() async {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [String] = []
            func append(_ entry: String) { lock.withLock { entries.append(entry) } }
            var all: [String] { lock.withLock { entries } }
        }
        let log = Log()
        let stopGate = AsyncGate()
        let streams = Counter()
        let firstStart = expectation(description: "first start")
        let secondStart = expectation(description: "second start")
        let sampling = LocationSampling(
            clientChanges: {
                streams.increment()
                let (changes, continuation) = AsyncStream<FindMyClient?>.makeStream()
                continuation.yield(nil)
                return changes
            },
            start: { _ in
                log.append("start")
                if log.all.count == 1 { firstStart.fulfill() } else { secondStart.fulfill() }
            },
            stop: {
                log.append("stop begins")
                await stopGate.wait()
                log.append("stop ends")
            }
        )

        sampling.setEnabled(true)
        await fulfillment(of: [firstStart], timeout: 5)
        sampling.setEnabled(false)
        sampling.setEnabled(true)
        await stopGate.waitUntilWaiting()
        XCTAssertEqual(log.all, ["start", "stop begins"], "the start waits for the stop before it")

        await stopGate.open()
        await fulfillment(of: [secondStart], timeout: 5)
        XCTAssertEqual(log.all, ["start", "stop begins", "stop ends", "start"])
    }

    private func failingClient() -> FindMyClient {
        let transport = ScriptedTransport()
        for _ in 0 ..< 4 {
            transport.fail("initClient", with: URLError(.notConnectedToInternet))
        }
        return FindMyClient(
            transport: transport,
            account: try! ICloudAccount(
                dsid: "1234",
                webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
            ),
            clientID: "client-id"
        )
    }

    /// `LocationHealth` compares the last success with the caller's clock,
    /// so the sampler stamps it with the clock it was given.
    func testTheSamplerStampsASuccessWithItsOwnClock() async {
        let moment = Date(timeIntervalSince1970: 1_234_567)
        let transport = ScriptedTransport()
        let devices: [String: Any] = [
            "serverContext": ["a": 1],
            "content": [
                [
                    "id": "phone", "name": "iPhone", "deviceClass": "iPhone",
                    "location": ["latitude": 40.7, "longitude": -73.9, "timeStamp": 1_700_000_000_000.0],
                ]
            ],
        ]
        transport.stub("initClient", json: devices)
        transport.stub("refreshClient", json: devices)
        let client = FindMyClient(
            transport: transport,
            account: try! ICloudAccount(
                dsid: "1234",
                webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
            ),
            clientID: "client-id"
        )
        let sampler = LocationSampler(store: store, peopleLoader: { [] }, now: { moment })

        await sampler.sampleOnce(webClient: client)

        let status = await sampler.currentStatus()
        XCTAssertNil(status.lastFailure)
        XCTAssertEqual(status.lastSuccessAt, moment)
    }

    func testStoppingTheSamplerClearsItsLastFailure() async {
        let sampler = LocationSampler(store: store, peopleLoader: { [] })
        await sampler.sampleOnce(webClient: failingClient())
        let failed = await sampler.currentStatus()
        XCTAssertEqual(failed.lastFailure, "URLError")

        await sampler.stop()
        let stopped = await sampler.currentStatus()
        XCTAssertNil(stopped.lastFailure)
        XCTAssertFalse(stopped.isRunning)
    }

    func testACancelledTickLeavesTheStatusAlone() async {
        let sampler = LocationSampler(store: store, peopleLoader: { [] })
        let client = failingClient()
        let tick = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await sampler.sampleOnce(webClient: client)
        }
        await tick.value
        let status = await sampler.currentStatus()
        XCTAssertNil(status.lastFailure, "A superseded tick must not report its own cancellation")
    }

    func testSamplerReusesThePhoneItChoseInsteadOfListingDevicesEveryTick() async throws {
        let transport = ScriptedTransport()
        let phoneList: [String: Any] = [
            "serverContext": ["prsId": 1234],
            "userInfo": ["firstName": "Robin", "lastName": "Doe"],
            "content": [
                [
                    "id": "phone",
                    "name": "Robin's iPhone",
                    "deviceClass": "iPhone",
                    "location": [
                        "latitude": 40.7,
                        "longitude": -74.0,
                        "horizontalAccuracy": 10.0,
                        "timeStamp": 1_700_000_000_000,
                    ],
                ]
            ],
        ]
        transport.stub("initClient", json: phoneList)
        for _ in 0 ..< 5 { transport.stub("refreshClient", json: phoneList) }
        let client = FindMyClient(
            transport: transport,
            account: try! ICloudAccount(
                dsid: "1234",
                webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
            ),
            clientID: "client-id"
        )
        let clock = SamplerClock()
        let sampler = LocationSampler(store: store, peopleLoader: { [] }, now: { clock.now })

        await sampler.sampleOnce(webClient: client)
        await sampler.sampleOnce(webClient: client)
        await sampler.sampleOnce(webClient: client)

        // One listing to choose the phone, then one locate per tick.
        XCTAssertEqual(transport.requests(matching: "fmipservice").count, 4)
        let locates = transport.requests(matching: "refreshClient").filter {
            ($0.json["clientContext"] as? [String: Any])?["shouldLocate"] as? Bool == true
        }
        XCTAssertEqual(locates.count, 3)
        XCTAssertTrue(
            locates.allSatisfy {
                ($0.json["clientContext"] as? [String: Any])?["selectedDevice"] as? String == "phone"
            }
        )

        clock.now = clock.now.addingTimeInterval(LocationSampler.phoneReuseSeconds)
        await sampler.sampleOnce(webClient: client)
        XCTAssertEqual(transport.requests(matching: "fmipservice").count, 6)
        let status = await sampler.currentStatus()
        XCTAssertNil(status.lastFailure)
    }

    func testASamplingFailureIsRecordedWithoutTheSystemsOwnWords() async throws {
        let account = try! ICloudAccount(
            dsid: "1234",
            webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
        )
        let offline = ScriptedTransport()
        offline.fail("initClient", with: URLError(.notConnectedToInternet))
        let sampler = LocationSampler(store: store, peopleLoader: { [] })
        await sampler.sampleOnce(
            webClient: FindMyClient(transport: offline, account: account, clientID: "client-id")
        )
        let unknown = await sampler.currentStatus().lastFailure
        XCTAssertEqual(unknown, "URLError")

        let rejected = ScriptedTransport()
        rejected.stub("initClient", status: 500)
        await sampler.sampleOnce(
            webClient: FindMyClient(transport: rejected, account: account, clientID: "client-id")
        )
        let facing = await sampler.currentStatus().lastFailure
        XCTAssertEqual(facing, "Find My rejected the request (HTTP 500).")
    }
}

private final class SamplerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

extension LocationHistoryStoreTests {
    /// Stored in rows on disk and sent to callers; renaming one orphans data.
    func testStoredVocabularyIsUnchanged() {
        XCTAssertEqual(LocationSampleProvider.web, "find-my-web")
        XCTAssertEqual(LocationSampleProvider.people, "find-my-people")
        XCTAssertEqual(NamedPlaceSource.manual, "manual")
        XCTAssertEqual(NamedPlaceSource.person, "person")
        XCTAssertEqual(NamedPlaceSource.findMyPeople, "find-my-people")
        XCTAssertEqual(LocationSubjectKey.friend(digest: Data([0xAB, 0x01])), "friend_ab01")
        XCTAssertTrue(LocationSubjectKey.isFriend("friend_ab01"))
        XCTAssertFalse(LocationSubjectKey.isFriend("find-my-web:rob"))
    }

    func testDeviceRecordingIgnoresFriendsAndPrefersTheUsersOwnFix() async throws {
        let none = try await store.deviceRecording()
        XCTAssertNil(none)
        let family = LocationSample(
            deviceID: "family",
            deviceName: "Sam's iPhone",
            personName: "Sam",
            isMe: false,
            latitude: 40,
            longitude: -73,
            accuracyMeters: 10,
            positionType: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + 500)
        )
        let friend = LocationSample(
            provider: LocationSampleProvider.people,
            subjectID: "friend_x",
            subjectKind: LocationSubjectKind.person,
            deviceID: "friend_x",
            deviceName: "Find My People",
            personName: "Alex",
            isMe: false,
            latitude: 41,
            longitude: -74,
            accuracyMeters: 10,
            positionType: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 - 500)
        )
        _ = try await store.record([sample(secondsFromNow: 0), sample(secondsFromNow: 100), family, friend])

        let read = try await store.deviceRecording()
        let recording = try XCTUnwrap(read)
        XCTAssertEqual(recording.began, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(recording.latest.timestamp, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(recording.latest.deviceID, "phone")
    }

    func testEveryWriteIsAnnouncedAndADuplicateFixIsNot() async throws {
        let changes = await store.changes()
        var iterator = changes.makeAsyncIterator()
        let start = await store.revision

        _ = try await store.record([sample(secondsFromNow: 0)])
        _ = await iterator.next()
        _ = try await store.record([sample(secondsFromNow: 0)])
        let afterDuplicate = await store.revision
        XCTAssertEqual(afterDuplicate, start + 1, "a fix already recorded changes nothing")

        try await store.setPlace(name: "Home", latitude: 40.7, longitude: -73.9, radiusMeters: 150, source: "manual")
        _ = await iterator.next()
        try await store.deletePlace(named: "Home")
        _ = await iterator.next()
        try await store.deletePeopleSamples()
        _ = await iterator.next()
        try await store.deleteSamples()
        _ = await iterator.next()
        let end = await store.revision
        XCTAssertEqual(end, start + 5)
    }

    /// The window deletes the place it shows, by id, as it edits one.
    func testDeletingAPlaceByIDRemovesOnlyThatPlace() async throws {
        let home = try await store.setPlace(
            name: "Home",
            latitude: 40.7,
            longitude: -73.9,
            radiusMeters: 150,
            source: "manual"
        )
        try await store.setPlace(name: "Work", latitude: 40.8, longitude: -73.95, radiusMeters: 150, source: "manual")
        let before = await store.revision

        let deleted = try await store.deletePlace(id: home.id)
        let again = try await store.deletePlace(id: home.id)

        XCTAssertTrue(deleted)
        XCTAssertFalse(again, "nothing left to delete")
        let names = try await store.places().map(\.name)
        XCTAssertEqual(names, ["Work"])
        let after = await store.revision
        XCTAssertEqual(after, before + 1, "a delete that found nothing is not a change")
    }

    func testUpdatingAPlaceByIDKeepsItsSourceAndRefusesATakenName() async throws {
        let home = try await store.setPlace(
            name: "Home",
            latitude: 40.7,
            longitude: -73.9,
            radiusMeters: 150,
            source: NamedPlaceSource.person
        )
        try await store.setPlace(name: "Work", latitude: 40.8, longitude: -73.9, radiusMeters: 150, source: "manual")

        let moved = try await store.updatePlace(
            id: home.id,
            name: "House",
            latitude: 40.71,
            longitude: -73.91,
            radiusMeters: 90,
            kind: NamedPlaceKind.label
        )
        XCTAssertEqual(moved.id, home.id)
        XCTAssertEqual(moved.source, NamedPlaceSource.person)
        XCTAssertEqual(moved.createdAt.timeIntervalSince1970, home.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(moved.latitude, 40.71)

        let renamed = try await store.updatePlace(id: home.id, name: "Cottage", radiusMeters: 90, kind: moved.kind)
        XCTAssertEqual(renamed.latitude, 40.71, "no centre given, so the place stays where it is")

        do {
            try await store.updatePlace(id: home.id, name: "work", radiusMeters: 90, kind: moved.kind)
            XCTFail("Expected a taken name to be refused")
        } catch {
            XCTAssertEqual(
                error as? LocationHistoryError,
                .invalidRequest("A place named \"work\" already exists. Choose another name.")
            )
        }
        let names = try await store.places().map(\.name)
        XCTAssertEqual(names, ["Cottage", "Work"])
    }
}

final class NamedPlaceKindTests: XCTestCase {
    func testALabelIsStoredSeparatelyFromANotablePlaceAndCanBePromoted() async throws {
        let directory = temporaryDirectoryURL()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try await store.setPlace(name: "Home", latitude: 40.7, longitude: -73.9, radiusMeters: 150, source: "manual")
        try await store.setPlace(
            name: "Corner Deli",
            latitude: 40.71,
            longitude: -73.91,
            radiusMeters: 60,
            source: "manual",
            kind: NamedPlaceKind.label
        )
        let places = try await store.places()
        XCTAssertEqual(places.map(\.name), ["Corner Deli", "Home"])
        XCTAssertEqual(places.map(\.kind), [NamedPlaceKind.label, NamedPlaceKind.notable])
        XCTAssertEqual(places.filter(\.isNotable).map(\.name), ["Home"])

        try await store.setPlace(
            name: "Corner Deli",
            latitude: 40.71,
            longitude: -73.91,
            radiusMeters: 60,
            source: "manual",
            kind: NamedPlaceKind.notable
        )
        let promoted = try await store.places()
        XCTAssertEqual(promoted.filter(\.isNotable).count, 2)
    }
}
