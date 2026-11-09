import SQLite3
import XCTest

@testable import iMCP

final class ScreenTimeServiceTests: XCTestCase {
    func testResolveRangeOmittedDatesUseDefaultWindow() throws {
        let before = Date()
        let range = try ScreenTimeService.range([:])
        let after = Date()
        XCTAssertEqual(
            range.end.timeIntervalSince(range.start),
            7 * 24 * 60 * 60,
            accuracy: 1
        )
        XCTAssertGreaterThanOrEqual(range.end.timeIntervalSince1970, before.timeIntervalSince1970)
        XCTAssertLessThanOrEqual(range.end.timeIntervalSince1970, after.timeIntervalSince1970 + 1)
    }

    func testResolveRangeEndOnlyUsesSevenDaysBeforeEnd() throws {
        let end = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-10 * 24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        let range = try ScreenTimeService.range([
            "endDate": .string(formatter.string(from: end))
        ])
        XCTAssertEqual(range.end.timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(
            range.start.timeIntervalSince1970,
            range.end.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testResolveRangeAcceptsEndAlias() throws {
        let end = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-10 * 24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        let range = try ScreenTimeService.range([
            "end": .string(formatter.string(from: end))
        ])
        XCTAssertEqual(range.end.timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(
            range.start.timeIntervalSince1970,
            range.end.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func testResolveRangeClampsSpansLongerThan31Days() throws {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let start = end.addingTimeInterval(-200 * 24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        let range = try ScreenTimeService.range([
            "startDate": .string(formatter.string(from: start)),
            "endDate": .string(formatter.string(from: end)),
        ])
        XCTAssertEqual(range.end.timeIntervalSince(range.start), 31 * 24 * 60 * 60, accuracy: 1)
    }
}

/// Usage used to be attributed by where a session started: one that began
/// before the range was dropped, and one that ran past its end was counted
/// in full.
final class ScreenTimeQueryTests: XCTestCase {
    private var path: String!
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private let end = Date(timeIntervalSinceReferenceDate: 2000)

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "knowledge-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY, ZSTREAMNAME TEXT, ZVALUESTRING TEXT,
              ZVALUEINTEGER INTEGER, ZSTARTDATE REAL, ZENDDATE REAL, ZSTRUCTUREDMETADATA INTEGER);
            CREATE TABLE ZSTRUCTUREDMETADATA (Z_PK INTEGER PRIMARY KEY,
              Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN TEXT);
            INSERT INTO ZOBJECT (ZSTREAMNAME, ZVALUESTRING, ZSTARTDATE, ZENDDATE) VALUES
              ('/app/usage', 'com.example.app', 900, 1100),
              ('/app/usage', 'com.example.app', 1500, 1600),
              ('/app/usage', 'com.example.app', 1900, 2500),
              ('/app/usage', 'com.example.app', 100, 200),
              ('/app/usage', 'com.example.app', 2000, 2100);
            INSERT INTO ZSTRUCTUREDMETADATA (Z_PK, Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN)
              VALUES (1, 'example.com');
            INSERT INTO ZOBJECT (ZSTREAMNAME, ZSTARTDATE, ZENDDATE, ZSTRUCTUREDMETADATA)
              VALUES ('/app/webUsage', 900, 1100, 1);
            INSERT INTO ZOBJECT (ZSTREAMNAME, ZVALUEINTEGER, ZSTARTDATE, ZENDDATE) VALUES
              ('/display/isBacklit', 1, 900, 1100),
              ('/display/isBacklit', 1, 1900, 2500);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testUsageClipsSessionsToTheRange() throws {
        let rows = try KnowledgeDatabase(connection: ReadOnlySQLite(path: path)).fetchUsage(
            start: start,
            end: end,
            limit: 10
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.objectValue?["totalSeconds"]?.intValue, 300)
        XCTAssertEqual(rows.first?.objectValue?["sessions"]?.intValue, 3)
    }

    func testDailyUsageBucketsAnEarlySessionInsideTheRange() throws {
        let rows = try KnowledgeDatabase(connection: ReadOnlySQLite(path: path)).fetchDailyUsage(
            start: start,
            end: end,
            limit: 10
        )
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.compactMap { $0.objectValue?["totalSeconds"]?.intValue }.reduce(0, +), 300)
    }

    func testWebUsageClipsSessionsToTheRange() throws {
        let rows = try KnowledgeDatabase(connection: ReadOnlySQLite(path: path)).fetchWebUsage(
            start: start,
            end: end,
            limit: 10
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.objectValue?["totalSeconds"]?.intValue, 100)
        XCTAssertEqual(rows.first?.objectValue?["visits"]?.intValue, 1)
    }

    func testDeviceActivityClipsFirstOnAndLastOff() throws {
        let rows = try KnowledgeDatabase(connection: ReadOnlySQLite(path: path)).fetchDeviceActivity(
            start: start,
            end: end
        )
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.compactMap { $0.objectValue?["activeSeconds"]?.intValue }.reduce(0, +), 200)
    }
}
