import XCTest
import OSLog
import SQLite3

@testable import iMCP

final class NotificationsServiceTests: XCTestCase {
    func testCoordinatorMergesOrdersAndLimitsWithoutDeduplicating() throws {
        let date = Date(timeIntervalSinceReferenceDate: 200)
        let local = record(.mac, "1", date, app: "com.example.app", title: "Synthetic match")
        let remote = record(.iphone, "2", date, app: "com.example.app", title: "Synthetic match")
        let older = record(
            .iphone,
            "3",
            Date(timeIntervalSinceReferenceDate: 160),
            app: "com.example.app",
            title: "Match"
        )
        let window = NotificationWindow(
            start: Date(timeIntervalSinceReferenceDate: 150),
            end: Date(timeIntervalSinceReferenceDate: 250),
            app: "com.example.app",
            searchTerm: "match"
        )
        var asked: [NotificationWindow] = []
        let coordinator = NotificationFetchCoordinator(
            localFetch: { window, _ in
                asked.append(window)
                return self.result(.mac, records: [local])
            },
            remoteFetch: { window in
                asked.append(window)
                return self.result(.iphone, records: [older, remote])
            }
        )

        let fetched = try coordinator.fetch(selection: .all, window: window, limit: 2)

        XCTAssertEqual(fetched.records.map(\.id), [local.id, remote.id])
        XCTAssertEqual(fetched.outcomes.map(\.source), [.mac, .iphone])
        XCTAssertEqual(asked, [window, window], "each source applies the window itself")
    }

    /// A search reads Mac rows newest first until it has `limit` matches, so
    /// a match older than many newer non-matching rows is still found. Reading
    /// a fixed number of rows and filtering afterwards lost it.
    func testASearchFindsAMacMatchOlderThanManyNewerRows() throws {
        let fixture = try makeLocalDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        for id in Int64(4) ... 10 {
            try insertLocalRecord(
                database: db,
                id: id,
                deliveredAt: Double(id) * 100,
                appID: 2,
                content: notificationFixtureContent(title: "Filler", subtitle: nil, body: "Nothing")
            )
        }
        sqlite3_close(db)
        let source = LocalNotificationSource(databasePath: fixture.database.path)
        let coordinator = NotificationFetchCoordinator(
            localFetch: { window, limit in source.fetch(window, limit: limit) },
            remoteFetch: { _ in self.result(.iphone) }
        )

        let fetched = try coordinator.fetch(selection: .mac, window: NotificationWindow(searchTerm: "first"), limit: 1)

        XCTAssertEqual(fetched.records.map(\.id), ["notification:1"])
        XCTAssertEqual(fetched.outcomes.map(\.isTruncated), [true], "a full page may have more matches")
        let all = source.fetch(NotificationWindow(searchTerm: "first"), limit: 10)
        XCTAssertEqual(all.records.map(\.id), ["notification:1"])
        XCTAssertFalse(all.outcome.isTruncated)
    }

    func testCoordinatorSelectionPartialEmptyAndAllFailureSemantics() throws {
        let local = result(.mac, records: [])
        let denied = result(.iphone, status: .denied)
        let coordinator = coordinator(local: local, remote: denied)
        let window = NotificationWindow()

        let macOnly = try coordinator.fetch(selection: .mac, window: window, limit: 30)
        XCTAssertTrue(macOnly.records.isEmpty)
        XCTAssertEqual(macOnly.outcomes.map(\.source), [.mac])

        let partial = try coordinator.fetch(selection: .all, window: window, limit: 30)
        XCTAssertEqual(partial.outcomes.map(\.status), [.available, .denied])

        XCTAssertThrowsError(try coordinator.fetch(selection: .iphone, window: window, limit: 30))
    }

    func testCoordinatorResponseKeepsLocalFieldsAndAddsProvenanceAndCoverage() throws {
        let date = Date(timeIntervalSinceReferenceDate: 200)
        let local = record(.mac, "1", date, app: "com.example.mac", title: "Local")
        let remote = record(.iphone, "2", date, app: "com.example.phone", title: "Phone")
        let coordinator = coordinator(local: result(.mac), remote: result(.iphone))
        let response = coordinator.response(
            records: [local, remote],
            outcomes: [
                NotificationSourceOutcome(source: .mac, status: .available, isTruncated: false),
                NotificationSourceOutcome(source: .iphone, status: .degraded, isTruncated: true),
            ]
        )
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(object["itemListElement"] as? [[String: Any]])
        let coverage = try XCTUnwrap(object["coverage"] as? [String: Any])

        XCTAssertEqual(object["@type"] as? String, "ItemList")
        XCTAssertEqual(items[0]["@id"] as? String, "notification:1")
        XCTAssertEqual(items[0]["source"] as? String, "mac")
        XCTAssertEqual(items[0]["timestampKind"] as? String, "delivered")
        XCTAssertNotNil(items[0]["deliveredAt"])
        XCTAssertNil(items[0]["createdAt"])
        XCTAssertEqual(items[1]["source"] as? String, "iphone")
        XCTAssertEqual(items[1]["timestampKind"] as? String, "created")
        XCTAssertNotNil(items[1]["createdAt"])
        XCTAssertNil(items[1]["deliveredAt"])
        XCTAssertEqual(coverage["overall"] as? String, "partial")
        let sources = try XCTUnwrap(coverage["sources"] as? [[String: Any]])
        XCTAssertEqual(sources[1]["status"] as? String, "degraded")
        XCTAssertEqual(sources[1]["truncated"] as? Bool, true)
    }

    func testLocalSourcePreservesIdentityContentAndDeliveredTimestamp() throws {
        let fixture = try makeLocalDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = LocalNotificationSource(databasePath: fixture.database.path).fetch(
            NotificationWindow(
                start: Date(timeIntervalSinceReferenceDate: 150),
                end: Date(timeIntervalSinceReferenceDate: 250),
                app: "com.example.second"
            ),
            limit: 10
        )

        XCTAssertEqual(result.outcome, NotificationSourceOutcome(source: .mac, status: .available, isTruncated: false))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].id, "notification:2")
        XCTAssertEqual(result.records[0].occurredAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(result.records[0].timestampEvidence, .delivered)
        XCTAssertEqual(result.records[0].appIdentifier, "com.example.second")
        XCTAssertEqual(result.records[0].title, "Second title")
        XCTAssertEqual(result.records[0].subtitle, "Second subtitle")
        XCTAssertEqual(result.records[0].body, "Second body")
    }

    func testLocalSourceDistinguishesEmptySuccessFromFailureAndRetainsMalformedContentRow() throws {
        let fixture = try makeLocalDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = LocalNotificationSource(databasePath: fixture.database.path)

        let empty = source.fetch(
            NotificationWindow(app: "com.example.missing"),
            limit: 10
        )
        XCTAssertEqual(empty.outcome.status, .available)
        XCTAssertTrue(empty.records.isEmpty)

        let malformed = source.fetch(
            NotificationWindow(app: "com.example.malformed"),
            limit: 10
        )
        XCTAssertEqual(malformed.outcome.status, .available)
        XCTAssertEqual(malformed.records.count, 1)
        XCTAssertNil(malformed.records[0].title)
        XCTAssertNil(malformed.records[0].subtitle)
        XCTAssertNil(malformed.records[0].body)

        let missing = LocalNotificationSource(
            databasePath: fixture.directory.appendingPathComponent("absent").path
        ).fetch(NotificationWindow(), limit: 10)
        XCTAssertEqual(missing.outcome.status, .unavailable)
        XCTAssertTrue(missing.records.isEmpty)
    }

    func testRemoteArchiveDecoderDecodesSyntheticKeyedArchive() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123)
        let payload: [[String: Any]] = [
            [
                "AppNotificationIdentifier": "native-1",
                "AppNotificationCreationDate": date,
                "AppNotificationTitle": "Synthetic title",
                "AppNotificationSubtitle": "Synthetic subtitle",
                "AppNotificationMessage": "Synthetic body",
            ]
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)

        let records = try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
            data,
            bundleIdentifier: "com.example.phone"
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "notification:iphone:com.example.phone:native-1")
        XCTAssertEqual(records[0].occurredAt, date)
        XCTAssertEqual(records[0].timestampEvidence, .created)
        XCTAssertEqual(records[0].title, "Synthetic title")
        XCTAssertEqual(records[0].subtitle, "Synthetic subtitle")
        XCTAssertEqual(records[0].body, "Synthetic body")
        XCTAssertEqual(records[0].damagedText, [])
    }

    func testRemoteArchiveDecoderKeepsRecordsWhoseBodyIsInvalidUTF16() throws {
        let marker = "Synthetic damaged body \(damageSentinel)"
        let payload: [[String: Any]] = [
            syntheticRecord("first", at: 100, title: "First title", body: "First body"),
            syntheticRecord("second", at: 200, title: "Second title", body: marker),
            syntheticRecord("third", at: 300, title: "Third title", body: "Third body"),
        ]
        let intact = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)
        let damaged = try damagingUTF16(in: intact, marker: marker)

        let records = try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
            damaged,
            bundleIdentifier: "com.example.phone"
        )

        let intactRecords = try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
            intact,
            bundleIdentifier: "com.example.phone"
        )
        let expectedEvidence = try damagingUTF16(in: XCTUnwrap(marker.data(using: .utf16BigEndian)), marker: marker)
        XCTAssertEqual(expectedEvidence.count, 48)
        XCTAssertEqual(expectedEvidence.suffix(4), Data([0x00, 0x20, 0xD8, 0x00]))

        XCTAssertEqual(records.map(\.nativeIdentifier), ["first", "second", "third"])
        XCTAssertEqual(records[0], intactRecords[0])
        XCTAssertEqual(records[2], intactRecords[2])
        XCTAssertEqual(records[0].body, "First body")
        XCTAssertEqual(records[0].damagedText, [])
        XCTAssertEqual(records[1].id, "notification:iphone:com.example.phone:second")
        XCTAssertEqual(records[1].occurredAt, Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(records[1].title, "Second title")
        XCTAssertNil(records[1].subtitle)
        XCTAssertNil(records[1].body)
        XCTAssertEqual(
            records[1].damagedText,
            [DamagedNotificationText(field: .body, utf16BigEndian: expectedEvidence)]
        )
        XCTAssertEqual(intactRecords[1].body, marker)
        XCTAssertEqual(intactRecords[1].damagedText, [])
    }

    func testRemoteArchiveDecoderRejectsInvalidUTF16OutsideFreeText() throws {
        func assertMalformed(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(
                try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
                    data,
                    bundleIdentifier: "com.example.phone"
                ),
                file: file,
                line: line
            ) { error in
                XCTAssertEqual(error as? RemoteNotificationStoreError, .malformed, file: file, line: line)
            }
        }

        let identifier = "identifier \(damageSentinel)"
        assertMalformed(
            try damagingUTF16(
                in: NSKeyedArchiver.archivedData(
                    withRootObject: [syntheticRecord(identifier, at: 100, title: "Title", body: "Body")],
                    requiringSecureCoding: false
                ),
                marker: identifier
            )
        )

        let key = "Extra key \(damageSentinel)"
        var keyed = syntheticRecord("keyed", at: 100, title: "Title", body: "Body")
        keyed[key] = "Value"
        assertMalformed(
            try damagingUTF16(
                in: NSKeyedArchiver.archivedData(withRootObject: [keyed], requiringSecureCoding: false),
                marker: key
            )
        )

        let className = "NSArray \(damageSentinel)"
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName(className, for: NSArray.self)
        archiver.encode(
            [syntheticRecord("classed", at: 100, title: "Title", body: "Body")],
            forKey: NSKeyedArchiveRootObjectKey
        )
        archiver.finishEncoding()
        assertMalformed(try damagingUTF16(in: archiver.encodedData, marker: className))

        let mappingKey = "com.example.\(damageSentinel)"
        let library = try damagingUTF16(
            in: NSKeyedArchiver.archivedData(
                withRootObject: [mappingKey: "77000000-0000-4000-8000-000000000007"],
                requiringSecureCoding: false
            ),
            marker: mappingKey
        )
        XCTAssertThrowsError(try RemoteNotificationArchiveDecoder().decodeLibraryMappings(library)) { error in
            XCTAssertEqual(error as? RemoteNotificationStoreError, .malformed)
        }
        let fixture = try makeRemoteStoreFixture(apps: [])
        defer { try? FileManager.default.removeItem(at: fixture) }
        try library.write(to: fixture.appendingPathComponent("Library.plist"))
        XCTAssertEqual(
            RemoteNotificationSource(rootURL: fixture).fetch(NotificationWindow()),
            NotificationSourceResult(
                records: [],
                outcome: NotificationSourceOutcome(source: .iphone, status: .malformed, isTruncated: false)
            )
        )
    }

    func testRemoteArchiveDecoderKeepsFramingAndReferenceChecksAroundDamagedText() throws {
        let marker = "Framed body \(damageSentinel)"
        let damaged = try damagingUTF16(
            in: NSKeyedArchiver.archivedData(
                withRootObject: [syntheticRecord("framed", at: 100, title: "Plain title", body: marker)],
                requiringSecureCoding: false
            ),
            marker: marker
        )
        let decoder = RemoteNotificationArchiveDecoder()
        XCTAssertEqual(
            try decoder.decodeDeliveredNotifications(damaged, bundleIdentifier: "com.example.phone").count,
            1
        )

        XCTAssertThrowsError(
            try decoder.decodeDeliveredNotifications(damaged.dropLast(1), bundleIdentifier: "com.example.phone")
        )

        let ascii = try XCTUnwrap(damaged.range(of: Data("Plain title".utf8)))
        var invalidASCII = damaged
        invalidASCII[ascii.lowerBound] = 0x80
        XCTAssertThrowsError(
            try decoder.decodeDeliveredNotifications(invalidASCII, bundleIdentifier: "com.example.phone")
        )

        XCTAssertThrowsError(
            try decoder.decodeDeliveredNotifications(
                retargetingOneByteUIDs(in: damaged, to: 0xFE),
                bundleIdentifier: "com.example.phone"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteNotificationStoreError, .malformed)
        }
    }

    func testRemoteArchiveDecoderMapsNullStringsToNil() throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: [NilTitleNotificationFixture()],
            requiringSecureCoding: false
        )

        let records = try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
            data,
            bundleIdentifier: "com.example.phone"
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.title)
        XCTAssertNil(records.first?.subtitle)
        XCTAssertEqual(records.first?.body, "Body")
    }

    func testRemoteArchiveDecoderRejectsMalformedArchive() {
        XCTAssertThrowsError(
            try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
                Data([0x00, 0x01, 0x02]),
                bundleIdentifier: "com.example.phone"
            )
        )
    }

    func testRemoteArchiveDecoderRejectsMissingIdentity() throws {
        let payload: [[String: Any]] = [
            ["AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 123)]
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)

        XCTAssertThrowsError(
            try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
                data,
                bundleIdentifier: "com.example.phone"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteNotificationStoreError, .malformed)
        }
    }

    func testRemoteArchiveDecoderRejectsDuplicateNativeIdentifiers() throws {
        let payload: [[String: Any]] = [
            [
                "AppNotificationIdentifier": "duplicate",
                "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 100),
            ],
            [
                "AppNotificationIdentifier": "duplicate",
                "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 200),
            ],
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)

        XCTAssertThrowsError(
            try RemoteNotificationArchiveDecoder().decodeDeliveredNotifications(
                data,
                bundleIdentifier: "com.example.phone"
            )
        ) { error in
            XCTAssertEqual(error as? RemoteNotificationStoreError, .malformed)
        }
    }

    func testRemoteArchiveDecoderEnforcesPerFileAndRecordBounds() throws {
        let payload: [[String: Any]] = [
            [
                "AppNotificationIdentifier": "native-1",
                "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 123),
            ]
        ]
        let data = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)

        XCTAssertThrowsError(
            try RemoteNotificationArchiveDecoder(limits: .init(maximumFileBytes: data.count - 1))
                .decodeDeliveredNotifications(data, bundleIdentifier: "com.example.phone")
        )
        XCTAssertThrowsError(
            try RemoteNotificationArchiveDecoder(limits: .init(maximumRecords: 0))
                .decodeDeliveredNotifications(data, bundleIdentifier: "com.example.phone")
        )
        XCTAssertThrowsError(
            try RemoteNotificationArchiveDecoder(limits: .init(maximumGraphDepth: 0))
                .decodeDeliveredNotifications(data, bundleIdentifier: "com.example.phone")
        )
    }

    func testRemoteStorePathValidationRejectsTraversalAndNonUUIDNames() {
        XCTAssertFalse(RemoteNotificationFileReader.isValidMappedDirectory("../escape"))
        XCTAssertFalse(RemoteNotificationFileReader.isValidMappedDirectory("not-a-uuid"))
        XCTAssertTrue(
            RemoteNotificationFileReader.isValidMappedDirectory(
                "89178CC5-0000-4000-8000-000000000000"
            )
        )
    }

    func testRemoteLibrarySnapshotDetectsReplacement() throws {
        let fixture = try makeRemoteStoreFixture(
            apps: [("com.example.app", "71000000-0000-4000-8000-000000000007", nil)]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try RemoteNotificationFileReader.readLibrarySnapshot(below: fixture)
        let replacement = try NSKeyedArchiver.archivedData(
            withRootObject: ["com.example.other": "72000000-0000-4000-8000-000000000007"],
            requiringSecureCoding: false
        )
        try replacement.write(to: fixture.appendingPathComponent("Library.plist"), options: .atomic)

        XCTAssertFalse(try RemoteNotificationFileReader.librarySnapshotIsCurrent(snapshot, below: fixture))
    }

    func testRemoteSourceReadsMultipleAppsFiltersAndTreatsMissingArchiveAsEmpty() throws {
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.first",
                    "10000000-0000-4000-8000-000000000001",
                    [
                        [
                            "AppNotificationIdentifier": "first",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 100),
                            "AppNotificationTitle": "First",
                        ]
                    ]
                ),
                (
                    "com.example.second",
                    "20000000-0000-4000-8000-000000000002",
                    [
                        [
                            "AppNotificationIdentifier": "second",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 200),
                            "AppNotificationMessage": "Second",
                        ]
                    ]
                ),
                ("com.example.empty", "30000000-0000-4000-8000-000000000003", nil),
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = RemoteNotificationSource(rootURL: fixture)
        let all = source.fetch(NotificationWindow())
        XCTAssertEqual(all.outcome, NotificationSourceOutcome(source: .iphone, status: .available, isTruncated: false))
        XCTAssertEqual(
            all.records.map(\.id),
            [
                "notification:iphone:com.example.second:second",
                "notification:iphone:com.example.first:first",
            ]
        )

        let filtered = source.fetch(
            NotificationWindow(
                start: Date(timeIntervalSinceReferenceDate: 150),
                end: Date(timeIntervalSinceReferenceDate: 250),
                app: "com.example.second"
            )
        )
        XCTAssertEqual(filtered.records.map(\.nativeIdentifier), ["second"])
        XCTAssertEqual(filtered.outcome.status, .available)

        let searched = source.fetch(NotificationWindow(searchTerm: "SECOND"))
        XCTAssertEqual(searched.records.map(\.nativeIdentifier), ["second"], "matched in the body, ignoring case")
    }

    func testRemoteSourceDegradesForMalformedAppAndReturnsOtherApps() throws {
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.good",
                    "40000000-0000-4000-8000-000000000004",
                    [
                        [
                            "AppNotificationIdentifier": "good",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 100),
                        ]
                    ]
                ),
                ("com.example.bad", "50000000-0000-4000-8000-000000000005", []),
            ],
            malformedApps: ["com.example.bad"]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = RemoteNotificationSource(rootURL: fixture).fetch(
            NotificationWindow()
        )
        XCTAssertEqual(result.outcome.status, .degraded)
        XCTAssertFalse(result.outcome.isTruncated)
        XCTAssertEqual(result.records.map(\.nativeIdentifier), ["good"])
    }

    func testRemoteSourceReturnsArchiveWhoseOnlyProblemIsDamagedText() throws {
        let marker = "Phone body \(damageSentinel)"
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.damaged",
                    "78000000-0000-4000-8000-000000000007",
                    [
                        syntheticRecord("valid", at: 100, title: "Valid", body: "Valid body"),
                        syntheticRecord("damaged", at: 200, title: "Damaged", body: marker),
                    ]
                )
            ],
            damagedMarkers: ["com.example.damaged": marker]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = RemoteNotificationSource(rootURL: fixture).fetch(
            NotificationWindow(app: "com.example.damaged")
        )
        XCTAssertEqual(
            result.outcome,
            NotificationSourceOutcome(
                source: .iphone,
                status: .available,
                isTruncated: false,
                damagedTextRecordCount: 1
            )
        )
        XCTAssertEqual(result.records.map(\.nativeIdentifier), ["damaged", "valid"])
        XCTAssertEqual(result.records.map(\.body), [nil, "Valid body"])
        XCTAssertEqual(result.records[0].damagedText.map(\.field), [.body])

        let windowed = RemoteNotificationSource(rootURL: fixture).fetch(
            NotificationWindow(
                start: Date(timeIntervalSinceReferenceDate: 50),
                end: Date(timeIntervalSinceReferenceDate: 150)
            )
        )
        XCTAssertEqual(windowed.records.map(\.nativeIdentifier), ["valid"])
        XCTAssertEqual(windowed.outcome.damagedTextRecordCount, 0)
    }

    func testRemoteSourceReportsDamagedTextAndSkippedArchiveSeparately() throws {
        let marker = "Phone title \(damageSentinel)"
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.bad",
                    "79000000-0000-4000-8000-000000000007",
                    [syntheticRecord("skipped", at: 300, title: "Skipped", body: "Skipped body")]
                ),
                (
                    "com.example.damaged",
                    "7A000000-0000-4000-8000-000000000007",
                    [syntheticRecord("kept", at: 100, title: marker, body: "Kept body")]
                ),
            ],
            malformedApps: ["com.example.bad"],
            damagedMarkers: ["com.example.damaged": marker]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = RemoteNotificationSource(rootURL: fixture).fetch(NotificationWindow())
        XCTAssertEqual(
            result.outcome,
            NotificationSourceOutcome(
                source: .iphone,
                status: .degraded,
                isTruncated: false,
                damagedTextRecordCount: 1
            )
        )
        XCTAssertEqual(result.records.map(\.id), ["notification:iphone:com.example.damaged:kept"])
        XCTAssertNil(result.records[0].title)
        XCTAssertEqual(result.records[0].body, "Kept body")
        XCTAssertEqual(result.records[0].damagedText.map(\.field), [.title])
    }

    func testCoordinatorResponseReportsDamagedTextEvidenceAndCount() throws {
        let damaged = NormalizedNotificationRecord(
            source: .iphone,
            nativeIdentifier: "native-1",
            occurredAt: Date(timeIntervalSinceReferenceDate: 200),
            timestampEvidence: .created,
            appIdentifier: "com.example.phone",
            title: "Title",
            subtitle: nil,
            body: nil,
            damagedText: [DamagedNotificationText(field: .body, utf16BigEndian: Data([0x00, 0x41, 0xD8, 0x00]))]
        )
        let response = coordinator(local: result(.mac), remote: result(.iphone)).response(
            records: [damaged],
            outcomes: [
                NotificationSourceOutcome(source: .mac, status: .available, isTruncated: false),
                NotificationSourceOutcome(
                    source: .iphone,
                    status: .available,
                    isTruncated: false,
                    damagedTextRecordCount: 1
                ),
            ]
        )
        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap((object["itemListElement"] as? [[String: Any]])?.first)
        let coverage = try XCTUnwrap(object["coverage"] as? [String: Any])
        let sources = try XCTUnwrap(coverage["sources"] as? [[String: Any]])

        XCTAssertEqual(item["title"] as? String, "Title")
        XCTAssertNil(item["body"])
        XCTAssertEqual(
            item["damagedText"] as? [NSDictionary],
            [
                [
                    "field": "body",
                    "error": "invalidUTF16",
                    "encoding": "utf-16be",
                    "codeUnits": 2,
                    "bytesBase64": "AEHYAA==",
                ]
            ]
        )
        XCTAssertEqual(coverage["overall"] as? String, "complete")
        XCTAssertEqual(sources.map { $0["damagedTextRecords"] as? Int }, [0, 1])
        XCTAssertEqual(sources.map { $0["status"] as? String }, ["available", "available"])

        let plain = coordinator(local: result(.mac), remote: result(.iphone)).response(
            records: [record(.iphone, "2", Date(timeIntervalSinceReferenceDate: 100), app: "a", title: "T")],
            outcomes: []
        )
        let plainObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        )
        let plainItem = try XCTUnwrap((plainObject["itemListElement"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(plainItem.keys),
            ["@id", "source", "occurredAt", "timestampKind", "createdAt", "app", "title"]
        )
    }

    func testRemoteSourceReportsAggregateCeilingAsTruncated() throws {
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.app",
                    "60000000-0000-4000-8000-000000000006",
                    [
                        [
                            "AppNotificationIdentifier": "one",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 100),
                        ]
                    ]
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = RemoteNotificationSource(
            rootURL: fixture,
            limits: .init(maximumAggregateBytes: 512)
        ).fetch(NotificationWindow())
        XCTAssertTrue(result.outcome.isTruncated)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testRemoteSourceChargesFilteredRecordsToAggregateCeiling() throws {
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.first",
                    "73000000-0000-4000-8000-000000000007",
                    [
                        [
                            "AppNotificationIdentifier": "first",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 100),
                        ]
                    ]
                ),
                (
                    "com.example.second",
                    "74000000-0000-4000-8000-000000000007",
                    [
                        [
                            "AppNotificationIdentifier": "second",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 200),
                        ]
                    ]
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = RemoteNotificationSource(rootURL: fixture, limits: .init(maximumRecords: 1)).fetch(
            NotificationWindow(start: Date(timeIntervalSinceReferenceDate: 300))
        )
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertTrue(result.outcome.isTruncated)
    }

    func testRemoteSourceContinuesAfterOneArchiveExceedsItsRecordBudget() throws {
        let fixture = try makeRemoteStoreFixture(
            apps: [
                (
                    "com.example.a.bad",
                    "75000000-0000-4000-8000-000000000007",
                    [
                        [
                            "AppNotificationIdentifier": "bad-one",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 100),
                        ],
                        [
                            "AppNotificationIdentifier": "bad-two",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 200),
                        ],
                    ]
                ),
                (
                    "com.example.z.good",
                    "76000000-0000-4000-8000-000000000007",
                    [
                        [
                            "AppNotificationIdentifier": "good",
                            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: 300),
                        ]
                    ]
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = RemoteNotificationSource(rootURL: fixture, limits: .init(maximumRecords: 1)).fetch(
            NotificationWindow()
        )
        XCTAssertEqual(result.records.map(\.nativeIdentifier), ["good"])
        XCTAssertEqual(result.outcome.status, .degraded)
        XCTAssertTrue(result.outcome.isTruncated)
    }

    /// Like every other database service with a picker, the denial names
    /// both ways in: the grant, and choosing the database from the menu.
    func testAPermissionDenialTellsTheClientToGrantFullDiskAccessOrPickTheDatabase() async throws {
        let fixture = try makeLocalDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.database.path)
        let expected =
            "iMCP cannot read notifications. Allow iMCP in System Settings > "
            + "Privacy & Security > Full Disk Access. Or switch the service off and on in the iMCP menu "
            + "to choose the Notifications database folder."

        let unreadable = LocalNotificationSource(databasePath: fixture.database.path)
            .fetch(NotificationWindow(), limit: 10)
        XCTAssertEqual(unreadable.outcome.status, .denied)
        XCTAssertEqual(notificationSourceStatus(forUnreadableDatabaseAt: fixture.database.path), .denied)

        XCTAssertThrowsError(
            try coordinator(local: unreadable, remote: result(.iphone, status: .unavailable))
                .fetch(selection: .all, window: NotificationWindow(), limit: 30)
        ) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), expected)
        }

        // What a notifications_fetch caller sees with no grant and no bookmark.
        let database = BookmarkedDatabase(
            path: fixture.database.path,
            bookmarkKey: "notificationsBookmark",
            selection: .directory,
            displayName: "Notifications",
            purpose: "notification history"
        )
        let service = NotificationsService(
            store: BookmarkedSQLiteStore(database, log: Logger.service("tests"), defaults: makeTemporaryDefaults())
        )
        let fetch = try XCTUnwrap(service.tools.first { $0.name == "notifications_fetch" })
        do {
            _ = try await fetch(["source": "mac"])
            XCTFail("a denied database must fail the fetch")
        } catch {
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), expected)
        }
    }

    /// A row with no content is skipped, and does not count toward the limit.
    func testRowsWithoutContentDoNotUseUpTheLimit() throws {
        let fixture = try makeLocalDatabaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.database.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        XCTAssertEqual(
            sqlite3_exec(db, "INSERT INTO record VALUES (4, 400, 1, NULL), (5, 500, 1, NULL);", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(db)

        let fetched = LocalNotificationSource(databasePath: fixture.database.path)
            .fetch(NotificationWindow(), limit: 2)

        XCTAssertEqual(fetched.records.map(\.id), ["notification:3", "notification:2"])
        XCTAssertTrue(fetched.outcome.isTruncated)
    }

    func testOtherReadFailuresKeepTheGenericMessage() throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(notificationSourceStatus(forUnreadableDatabaseAt: absent), .unavailable)

        XCTAssertThrowsError(
            try coordinator(
                local: result(.mac, status: .unavailable),
                remote: result(.iphone, status: .malformed)
            )
            .fetch(selection: .all, window: NotificationWindow(), limit: 30)
        ) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "None of the requested notification sources could be read."
            )
        }
    }

    /// A bookmark that no longer resolves used to read as a denial, so the
    /// client was told to grant Full Disk Access for a database that is not
    /// there. Every unreadable database is now classified by its path.
    func testABrokenBookmarkIsClassifiedByTheDatabasePath() async throws {
        let defaults = makeTemporaryDefaults()
        let database = BookmarkedDatabase(
            path: temporaryDirectoryURL().appendingPathComponent("db").path,
            bookmarkKey: "notificationsBookmark",
            selection: .directory,
            displayName: "Notifications",
            purpose: "notification history"
        )
        defaults.set(Data("not a bookmark".utf8), forKey: database.bookmarkKey)
        let service = NotificationsService(
            store: BookmarkedSQLiteStore(database, log: Logger.service("tests"), defaults: defaults)
        )
        let fetch = try XCTUnwrap(service.tools.first { $0.name == "notifications_fetch" })

        do {
            _ = try await fetch(["source": "mac"])
            XCTFail("an unreadable database must fail the fetch")
        } catch {
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "None of the requested notification sources could be read."
            )
        }
    }

    private func makeLocalDatabaseFixture() throws -> (directory: URL, database: URL) {
        let directory = try makeTemporaryDirectory()
        let database = directory.appendingPathComponent("db")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT);"
                    + "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, delivered_date REAL, app_id INTEGER, data BLOB);"
                    + "INSERT INTO app VALUES (1, 'com.example.first'), (2, 'com.example.second'), (3, 'com.example.malformed');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        try insertLocalRecord(
            database: db,
            id: 1,
            deliveredAt: 100,
            appID: 1,
            content: notificationFixtureContent(title: "First title", subtitle: nil, body: "First body")
        )
        try insertLocalRecord(
            database: db,
            id: 2,
            deliveredAt: 200,
            appID: 2,
            content: notificationFixtureContent(
                title: "Second title",
                subtitle: "Second subtitle",
                body: "Second body"
            )
        )
        try insertLocalRecord(database: db, id: 3, deliveredAt: 300, appID: 3, content: Data([0x00, 0x01]))
        return (directory, database)
    }

    private func coordinator(
        local: NotificationSourceResult,
        remote: NotificationSourceResult
    ) -> NotificationFetchCoordinator {
        NotificationFetchCoordinator(
            localFetch: { _, _ in local },
            remoteFetch: { _ in remote }
        )
    }

    private func result(
        _ source: NotificationRecordSource,
        records: [NormalizedNotificationRecord] = [],
        status: NotificationSourceStatus = .available,
        truncated: Bool = false
    ) -> NotificationSourceResult {
        NotificationSourceResult(
            records: records,
            outcome: NotificationSourceOutcome(source: source, status: status, isTruncated: truncated)
        )
    }

    private func record(
        _ source: NotificationRecordSource,
        _ identifier: String,
        _ date: Date,
        app: String,
        title: String
    ) -> NormalizedNotificationRecord {
        NormalizedNotificationRecord(
            source: source,
            nativeIdentifier: identifier,
            occurredAt: date,
            timestampEvidence: source == .mac ? .delivered : .created,
            appIdentifier: app,
            title: title,
            subtitle: nil,
            body: nil
        )
    }

    private func makeRemoteStoreFixture(
        apps: [(bundleIdentifier: String, directory: String, records: [[String: Any]]?)],
        malformedApps: Set<String> = [],
        damagedMarkers: [String: String] = [:]
    ) throws -> URL {
        let root = try makeTemporaryDirectory()
        let mappings = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier, $0.directory) })
        try NSKeyedArchiver.archivedData(withRootObject: mappings, requiringSecureCoding: false)
            .write(to: root.appendingPathComponent("Library.plist"))

        for app in apps {
            let directory = root.appendingPathComponent(app.directory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let records = app.records else { continue }
            var data =
                malformedApps.contains(app.bundleIdentifier)
                ? Data([0x00, 0x01, 0x02])
                : try NSKeyedArchiver.archivedData(withRootObject: records, requiringSecureCoding: false)
            if let marker = damagedMarkers[app.bundleIdentifier] {
                data = try damagingUTF16(in: data, marker: marker)
            }
            try data.write(to: directory.appendingPathComponent("DeliveredNotifications.plist"))
        }
        return root
    }

    private func syntheticRecord(
        _ identifier: String,
        at seconds: TimeInterval,
        title: String,
        body: String
    ) -> [String: Any] {
        [
            "AppNotificationIdentifier": identifier,
            "AppNotificationCreationDate": Date(timeIntervalSinceReferenceDate: seconds),
            "AppNotificationTitle": title,
            "AppNotificationMessage": body,
        ]
    }

    /// Overwrites the sentinel's code unit inside `marker` with a lone high
    /// surrogate. The length is unchanged, so the binary plist framing stays valid.
    private func damagingUTF16(in data: Data, marker: String) throws -> Data {
        let encoded = try XCTUnwrap(marker.data(using: .utf16BigEndian))
        let range = try XCTUnwrap(data.range(of: encoded), "marker must be stored as UTF-16")
        XCTAssertNil(data.range(of: encoded, in: range.upperBound ..< data.endIndex), "marker must be unique")
        let sentinel = try XCTUnwrap(marker.utf16.firstIndex(of: damageSentinel.utf16.first!))
        let offset = range.lowerBound + marker.utf16.distance(from: marker.utf16.startIndex, to: sentinel) * 2
        var damaged = data
        damaged[offset] = 0xD8
        damaged[offset + 1] = 0x00
        return damaged
    }

    /// Points every one-byte UID object in a binary plist at `index`, which is
    /// past the end of a small archive's `$objects`.
    private func retargetingOneByteUIDs(in data: Data, to index: UInt8) throws -> Data {
        func integer(_ start: Int, _ count: Int) -> Int {
            data[(data.startIndex + start) ..< (data.startIndex + start + count)].reduce(0) { $0 << 8 | Int($1) }
        }
        let trailer = data.count - 32
        let offsetSize = integer(trailer + 6, 1)
        let objectCount = integer(trailer + 8, 8)
        let offsetTable = integer(trailer + 24, 8)
        XCTAssertLessThan(objectCount, Int(index))
        var patched = data
        var retargeted = 0
        for object in 0 ..< objectCount {
            let offset = data.startIndex + integer(offsetTable + object * offsetSize, offsetSize)
            guard data[offset] == 0x80 else { continue }
            patched[offset + 1] = index
            retargeted += 1
        }
        XCTAssertGreaterThan(retargeted, 0)
        return patched
    }

    private func notificationFixtureContent(title: String, subtitle: String?, body: String) throws -> Data {
        var request: [String: String] = ["titl": title, "body": body]
        request["subt"] = subtitle
        return try PropertyListSerialization.data(
            fromPropertyList: ["req": request],
            format: .binary,
            options: 0
        )
    }

    private func insertLocalRecord(
        database: OpaquePointer,
        id: Int64,
        deliveredAt: Double,
        appID: Int64,
        content: Data
    ) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO record VALUES (?, ?, ?, ?)", -1, &statement, nil),
            SQLITE_OK
        )
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int64(query, 1, id)
        sqlite3_bind_double(query, 2, deliveredAt)
        sqlite3_bind_int64(query, 3, appID)
        _ = content.withUnsafeBytes { bytes in
            sqlite3_bind_blob(query, 4, bytes.baseAddress, Int32(bytes.count), nil)
        }
        XCTAssertEqual(sqlite3_step(query), SQLITE_DONE)
    }
}

private let damageSentinel = "\u{2603}"

/// Archives the way the real store does when a notification has no title:
/// `encode(nil, forKey:)` writes a reference to the archive's `$null` object.
@objc(NilTitleNotificationFixture)
private final class NilTitleNotificationFixture: NSObject, NSCoding {
    override init() {}
    init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode("native-1" as NSString, forKey: "AppNotificationIdentifier")
        coder.encode(Date(timeIntervalSinceReferenceDate: 123) as NSDate, forKey: "AppNotificationCreationDate")
        coder.encode(nil, forKey: "AppNotificationTitle")
        coder.encode("Body" as NSString, forKey: "AppNotificationMessage")
    }
}
