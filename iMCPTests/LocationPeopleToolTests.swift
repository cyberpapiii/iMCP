import Foundation
import XCTest

@testable import iMCP

/// The Location tools over Find My People: which provider each reads, and
/// what a failing or revoked provider hides.
final class LocationPeopleToolTests: XCTestCase {
    func testFriendsAreDeterministicAndLookupNeverGuessesDuplicateNames() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in
                [
                    localStoragePerson(id: "b", name: "Alex", latitude: 41),
                    localStoragePerson(id: "c", name: "Robin", latitude: 42),
                    localStoragePerson(id: "a", name: "alex", latitude: 40),
                ]
            }
        )

        let reports = try await readiness.friends()
        XCTAssertEqual(reports.map(\.name), ["Alex", "alex", "Robin"])
        XCTAssertEqual(reports.last?.source, "findmylocateagent-localstorage")
        XCTAssertEqual(reports.last?.verticalAccuracyMeters, 8)
        let history = try await readiness.historyFixes()
        XCTAssertEqual(history.map(\.timestamp), Array(repeating: Date(timeIntervalSince1970: 1_700_000_000), count: 3))
        XCTAssertEqual(Set(history.map(\.identifier)), Set(reports.map(\.identifier)))

        let robin = try await readiness.friend(matching: reports.last!.identifier)
        XCTAssertEqual(robin.name, "Robin")
        let service = LocationPersonResolver(readiness: readiness, snapshot: { self.webSnapshot(named: "Family") })
        let stablePlacePosition = try await service.position(for: robin.identifier)
        XCTAssertEqual(stablePlacePosition.latitude, robin.latitude)
        XCTAssertEqual(stablePlacePosition.provider, .people)
        let namedPlacePosition = try await service.position(for: "Robin")
        XCTAssertEqual(namedPlacePosition.latitude, robin.latitude)
        let webPlacePosition = try await service.position(for: "Family")
        XCTAssertEqual(webPlacePosition.latitude, 39)
        XCTAssertEqual(webPlacePosition.provider, .web)
        let overlappingService = LocationPersonResolver(
            readiness: readiness,
            snapshot: { self.webSnapshot(named: "Robin") }
        )
        do {
            _ = try await overlappingService.position(for: "Robin")
            XCTFail("Expected exact cross-provider ambiguity")
        } catch let error as FindMyPeopleToolError {
            guard case .ambiguousName(_, let identifiers) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                identifiers,
                [robin.identifier, "find-my-web:robin"].sorted()
            )
        }
        do {
            _ = try await readiness.friend(matching: "ALEX")
            XCTFail("Expected duplicate-name ambiguity")
        } catch let error as FindMyPeopleToolError {
            guard case .ambiguousName(_, let identifiers) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifiers, Array(reports.prefix(2).map(\.identifier)).sorted())
        }
        do {
            _ = try await service.position(for: "ALEX")
            XCTFail("Expected named-place duplicate-name ambiguity")
        } catch let error as FindMyPeopleToolError {
            guard case .ambiguousName = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        do {
            _ = try await service.position(for: "Nobody")
            XCTFail("Expected People's own not-found answer")
        } catch {
            XCTAssertEqual(error as? FindMyPeopleToolError, .friendNotFound("Nobody"))
        }
        let webOnly = LocationPersonResolver(
            readiness: FindMyPeopleReadiness(
                storage: peopleKeyStorage(database: InMemoryKeychainItem(), identity: InMemoryKeychainItem()),
                peopleEnabled: false,
                loadPeople: { _ in [] }
            ),
            snapshot: { self.webSnapshot(named: "Family") }
        )
        let partial = try await webOnly.position(for: "fam")
        XCTAssertEqual(partial.provider, .web)
        do {
            _ = try await webOnly.position(for: "Nobody")
            XCTFail("Expected an unknown person")
        } catch {
            XCTAssertEqual(error as? LocationPersonError, .unknownPerson("Nobody"))
        }
    }

    /// A friend and a Family member share a name. Every identifier the
    /// ambiguity error suggests, passed back as `person`, picks its own
    /// person: in the live lookup and in recorded history alike.
    func testEachSuggestedIdentifierSettlesAnAmbiguousName() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in [localStoragePerson(id: "robin-friend", name: "Robin", latitude: 42)] }
        )
        let friends = try await readiness.friends()
        let friendID = try XCTUnwrap(friends.first?.identifier)
        // Apple's own id for the Family member is not what callers are given.
        var web = webSnapshot(named: "Robin")
        web = FindMySnapshot(
            devices: web.devices,
            people: web.people.map { FindMyPerson(id: "apple-id", name: $0.name, isMe: false, devices: $0.devices) }
        )
        let snapshot = web
        let resolver = LocationPersonResolver(readiness: readiness, snapshot: { snapshot })

        var suggested: [String] = []
        do {
            _ = try await resolver.position(for: "Robin")
            XCTFail("Expected the shared name to be ambiguous")
        } catch FindMyPeopleToolError.ambiguousName(_, let identifiers) {
            suggested = identifiers
        }
        XCTAssertEqual(suggested, [friendID, "find-my-web:robin"].sorted())
        let friendPosition = try await resolver.position(for: friendID)
        XCTAssertEqual(friendPosition.provider, .people)
        XCTAssertEqual(friendPosition.latitude, 42)
        let webPosition = try await resolver.position(for: "find-my-web:robin")
        XCTAssertEqual(webPosition.provider, .web)
        XCTAssertEqual(webPosition.latitude, 39)
        let typedPosition = try await resolver.position(for: "find-my-web:Robin")
        XCTAssertEqual(typedPosition.provider, .web)
        do {
            _ = try await resolver.position(for: "find-my-web:nobody")
            XCTFail("Expected an unknown web person")
        } catch {
            XCTAssertEqual(error as? LocationPersonError, .unknownPerson("find-my-web:nobody"))
        }

        let now = Date()
        let store = LocationHistoryStore(url: temporaryDirectoryURL().appendingPathComponent("history.sqlite"))
        _ = try await store.record([
            LocationSample(
                deviceID: "robin-phone",
                deviceName: "Robin's iPhone",
                personName: "Robin",
                isMe: true,
                latitude: 39,
                longitude: -71,
                accuracyMeters: 5,
                positionType: "GPS",
                timestamp: now.addingTimeInterval(-30)
            ),
            LocationSample(
                provider: LocationSampleProvider.people,
                subjectID: friendID,
                subjectKind: LocationSubjectKind.person,
                deviceID: friendID,
                deviceName: "Find My People",
                personName: "Robin",
                isMe: false,
                latitude: 42,
                longitude: -74,
                accuracyMeters: 5,
                positionType: nil,
                timestamp: now
            ),
        ])
        let history = try XCTUnwrap(
            LocationService.testing(peopleReadiness: readiness, historyStore: store).tools
                .first { $0.name == "location_history" }
        )
        func rows(for person: String) async throws -> [[String: Any]] {
            try historySamples(
                try await history([
                    "startDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))),
                    "endDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(60))),
                    "person": .string(person),
                ])
            )
        }

        do {
            _ = try await rows(for: "Robin")
            XCTFail("Expected the shared name to be ambiguous in history")
        } catch LocationHistoryError.ambiguousPerson(_, let identifiers) {
            XCTAssertEqual(identifiers, suggested)
        }
        for identifier in suggested {
            let found = try await rows(for: identifier)
            XCTAssertEqual(found.count, 1, identifier)
            XCTAssertEqual(found.first?["latitude"] as? Double, identifier == friendID ? 42 : 39, identifier)
        }
    }

    /// Two Family members named Bob share one identifier, so they are one
    /// person, at the fresher fix, as history counts them. An ambiguity error
    /// therefore never suggests the identifier that produced it: each one it
    /// lists settles the query.
    func testWebPeopleWhoShareANameAreOnePerson() async throws {
        func person(_ name: String, id: String, latitude: Double, age: TimeInterval) -> FindMyPerson {
            let device = FindMyDevice(
                id: id,
                name: "\(name)'s iPhone",
                model: nil,
                deviceClass: "iPhone",
                batteryLevel: nil,
                batteryStatus: nil,
                isThisDevice: false,
                ownerID: "owner-\(id)",
                canPlaySound: false,
                location: FindMyFix(
                    latitude: latitude,
                    longitude: -71,
                    horizontalAccuracy: 10,
                    timestamp: Date().addingTimeInterval(-age),
                    positionType: nil,
                    isOld: false
                )
            )
            return FindMyPerson(id: nil, name: name, isMe: false, devices: [device])
        }
        let people = [
            person("Bob", id: "old-bob", latitude: 10, age: 600),
            person("bob", id: "new-bob", latitude: 20, age: 60),
            person("Bobby", id: "bobby", latitude: 30, age: 60),
        ]
        let snapshot = FindMySnapshot(devices: people.flatMap(\.devices), people: people)
        let resolver = LocationPersonResolver(
            readiness: FindMyPeopleReadiness(
                storage: peopleKeyStorage(),
                peopleEnabled: false,
                loadPeople: { _ in [] }
            ),
            snapshot: { snapshot }
        )

        let byName = try await resolver.position(for: "Bob")
        XCTAssertEqual(byName.latitude, 20)
        let byIdentifier = try await resolver.position(for: "find-my-web:bob")
        XCTAssertEqual(byIdentifier.latitude, 20)

        var suggested: [String] = []
        do {
            _ = try await resolver.position(for: "Bo")
            XCTFail("Expected Bob and Bobby to be ambiguous")
        } catch FindMyPeopleToolError.ambiguousName(_, let identifiers) {
            suggested = identifiers
        }
        XCTAssertEqual(suggested, ["find-my-web:bob", "find-my-web:bobby"])
        for identifier in suggested {
            let position = try await resolver.position(for: identifier)
            XCTAssertEqual(position.latitude, identifier == "find-my-web:bob" ? 20 : 30, identifier)
        }
    }

    /// The web provider sees one person, `name`, at 39, -71.
    private func webSnapshot(named name: String) -> FindMySnapshot {
        let device = FindMyDevice(
            id: "device-\(name)",
            name: "\(name)'s iPhone",
            model: nil,
            deviceClass: "iPhone",
            batteryLevel: nil,
            batteryStatus: nil,
            isThisDevice: false,
            ownerID: "owner-\(name)",
            canPlaySound: false,
            location: FindMyFix(
                latitude: 39,
                longitude: -71,
                horizontalAccuracy: 10,
                timestamp: Date(),
                positionType: nil,
                isOld: false
            )
        )
        return FindMySnapshot(
            devices: [device],
            people: [FindMyPerson(id: nil, name: name, isMe: false, devices: [device])]
        )
    }

    func testProviderFailureHidesPeopleHistoryVisitsAndPlacesButKeepsWebHistory() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in throw LocalStoragePeopleError.incorrectKey }
        )
        let directory = temporaryDirectoryURL()
        let now = Date()
        let store = LocationHistoryStore(
            url: directory.appendingPathComponent("history.sqlite"),
            now: { now }
        )
        // Two fixes each: a visit needs more than one sighting.
        _ = try await store.record([
            LocationSample(
                deviceID: "web-phone",
                deviceName: "Web Phone",
                personName: "Web Owner",
                isMe: true,
                latitude: 40,
                longitude: -73,
                accuracyMeters: 5,
                positionType: "GPS",
                timestamp: now.addingTimeInterval(-30)
            ),
            LocationSample(
                deviceID: "web-phone",
                deviceName: "Web Phone",
                personName: "Web Owner",
                isMe: true,
                latitude: 40,
                longitude: -73,
                accuracyMeters: 5,
                positionType: "GPS",
                timestamp: now
            ),
            LocationSample(
                provider: LocationSampleProvider.people,
                subjectID: "friend_hidden",
                subjectKind: LocationSubjectKind.person,
                deviceID: "friend_hidden",
                deviceName: "Find My People",
                personName: "Hidden Friend",
                isMe: false,
                latitude: 41,
                longitude: -74,
                accuracyMeters: 5,
                positionType: nil,
                timestamp: now
            ),
        ])
        _ = try await store.setPlace(
            name: "Manual",
            latitude: 40,
            longitude: -73,
            radiusMeters: 150,
            source: "manual"
        )
        _ = try await store.setPlace(
            name: "Hidden",
            latitude: 41,
            longitude: -74,
            radiusMeters: 150,
            source: LocationSampleProvider.people
        )
        let service = LocationService.testing(peopleReadiness: readiness, historyStore: store)
        let arguments: [String: Value] = [
            "startDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))),
            "endDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(60))),
        ]

        let history = try historySamples(
            try await XCTUnwrap(service.tools.first { $0.name == "location_history" })(arguments)
        )
        XCTAssertEqual(Set(history.compactMap { $0["person"] as? String }), ["Web Owner"])
        XCTAssertNil(history.first?["provider"])

        let visits = try jsonArray(
            try await XCTUnwrap(service.tools.first { $0.name == "location_visits" })(
                arguments.merging(["minimumMinutes": .int(0)]) { _, new in new }
            )
        )
        XCTAssertEqual(visits.compactMap { $0["person"] as? String }, ["Web Owner"])

        let places = try jsonArray(
            try await XCTUnwrap(service.tools.first { $0.name == "location_places" })([:])
        )
        XCTAssertEqual(places.compactMap { $0["name"] as? String }, ["Manual"])

        do {
            _ = try await XCTUnwrap(service.tools.first { $0.name == "location_history" })(
                arguments.merging(["person": .string("friend_hidden")]) { _, new in new }
            )
            XCTFail("Expected explicit People history to fail closed")
        } catch let error as LocalStoragePeopleError {
            XCTAssertEqual(error, .incorrectKey)
        }
    }

    func testVisitsGroupWebByPersonAndPeopleByStableSubjectAndExposePeopleIdentity() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in [localStoragePerson(id: "friend-server", name: "Friend", latitude: 41)] }
        )
        let friends = try await readiness.friends()
        let friendID = try XCTUnwrap(friends.first?.identifier)
        let directory = temporaryDirectoryURL()
        let now = Date()
        let store = LocationHistoryStore(
            url: directory.appendingPathComponent("history.sqlite"),
            now: { now }
        )
        var samples: [LocationSample] = []
        for device in ["phone", "watch"] {
            for offset in [0.0, 600.0] {
                samples.append(
                    LocationSample(
                        deviceID: device,
                        deviceName: device,
                        personName: "Web Owner",
                        isMe: true,
                        latitude: 40,
                        longitude: -73,
                        accuracyMeters: 5,
                        positionType: "GPS",
                        timestamp: now.addingTimeInterval(offset)
                    )
                )
            }
        }
        for offset in [0.0, 600.0] {
            samples.append(
                LocationSample(
                    provider: LocationSampleProvider.people,
                    subjectID: friendID,
                    subjectKind: LocationSubjectKind.person,
                    deviceID: friendID,
                    deviceName: "Find My People",
                    personName: "Friend",
                    isMe: false,
                    latitude: 41,
                    longitude: -74,
                    accuracyMeters: 5,
                    positionType: nil,
                    timestamp: now.addingTimeInterval(offset)
                )
            )
        }
        _ = try await store.record(samples)
        for (name, latitude, longitude, source) in [
            ("Web Place", 40.0, -73.0, "manual"),
            ("Friend Place", 41.0, -74.0, LocationSampleProvider.people),
        ] {
            _ = try await store.setPlace(
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: 150,
                source: source
            )
        }
        let service = LocationService.testing(peopleReadiness: readiness, historyStore: store)
        let visits = try jsonArray(
            try await XCTUnwrap(service.tools.first { $0.name == "location_visits" })([
                "startDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))),
                "endDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(700))),
                "minimumMinutes": .int(0),
            ])
        )

        XCTAssertEqual(visits.count, 2)
        let web = try XCTUnwrap(visits.first { $0["person"] as? String == "Web Owner" })
        XCTAssertEqual(web["sampleCount"] as? Int, 2)
        XCTAssertNil(web["provider"])
        let friend = try XCTUnwrap(visits.first { $0["person"] as? String == "Friend" })
        XCTAssertEqual(friend["provider"] as? String, LocationSampleProvider.people)
        XCTAssertEqual(friend["subjectIdentifier"] as? String, friendID)

        let history = try historySamples(
            try await XCTUnwrap(service.tools.first { $0.name == "location_history" })([
                "person": .string(friendID),
                "startDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))),
                "endDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(700))),
            ])
        )
        XCTAssertEqual(history.first?["provider"] as? String, LocationSampleProvider.people)
        XCTAssertEqual(history.first?["subjectIdentifier"] as? String, friendID)
    }

    func testVisitsKeepTheLegacyTwentyThousandSampleWorkingSet() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: false,
            loadPeople: { _ in [] }
        )
        let directory = temporaryDirectoryURL()
        let now = Date()
        let store = LocationHistoryStore(
            url: directory.appendingPathComponent("history.sqlite"),
            now: { now }
        )
        let samples = (0 ... 5_000).map { offset in
            LocationSample(
                deviceID: "phone",
                deviceName: "Phone",
                personName: "Web Owner",
                isMe: true,
                latitude: 40,
                longitude: -73,
                accuracyMeters: 5,
                positionType: "GPS",
                timestamp: now.addingTimeInterval(TimeInterval(offset))
            )
        }
        let inserted = try await store.record(samples)
        XCTAssertEqual(inserted, 5_001)
        _ = try await store.setPlace(
            name: "Web Place",
            latitude: 40,
            longitude: -73,
            radiusMeters: 150,
            source: "manual"
        )
        let service = LocationService.testing(peopleReadiness: readiness, historyStore: store)
        let visits = try jsonArray(
            try await XCTUnwrap(service.tools.first { $0.name == "location_visits" })([
                "startDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))),
                "endDate": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(6_000))),
                "minimumMinutes": .int(0),
            ])
        )

        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?["sampleCount"] as? Int, 5_001)
    }

    private func jsonArray(_ result: ToolResult) throws -> [[String: Any]] {
        guard case .json(let data) = result,
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw CocoaError(.coderReadCorrupt)
        }
        return rows
    }

    private func historySamples(_ result: ToolResult) throws -> [[String: Any]] {
        guard case .json(let data) = result,
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = report["samples"] as? [[String: Any]]
        else {
            throw CocoaError(.coderReadCorrupt)
        }
        return rows
    }

    func testLocationFriendToolsUseOnlyTheInjectedLocalProvider() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in [localStoragePerson(id: "robin", name: "Robin")] }
        )
        let service = LocationService.testing(
            peopleReadiness: readiness,
            historyStore: LocationHistoryStore(url: temporaryDirectoryURL().appendingPathComponent("history.sqlite"))
        )
        let friendsTool = try XCTUnwrap(service.tools.first { $0.name == "location_friends" })
        let friendTool = try XCTUnwrap(service.tools.first { $0.name == "location_friend" })
        let peopleTool = try XCTUnwrap(service.tools.first { $0.name == "location_people" })

        XCTAssertTrue(friendsTool.description.contains("never contacts Apple"))
        XCTAssertTrue(peopleTool.description.lowercased().contains("device-derived family"))
        XCTAssertTrue(peopleTool.description.contains("location_friends"))

        guard case .json(let listData) = try await friendsTool([:]) else {
            return XCTFail("Expected JSON")
        }
        XCTAssertEqual(try JSONDecoder().decode([FindMyFriendReport].self, from: listData).count, 1)

        guard case .json(let oneData) = try await friendTool(["person": .string("robin")]) else {
            return XCTFail("Expected JSON")
        }
        XCTAssertEqual(try JSONDecoder().decode(FindMyFriendReport.self, from: oneData).name, "Robin")
    }
}
