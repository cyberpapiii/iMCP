import SQLite3
import XCTest

@testable import iMCP

/// A search used to read only the newest rows, five times the limit, and
/// filter those, so anyone who last called a few months ago was never found.
final class CallHistorySearchTests: XCTestCase {
    private var path: String!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "calls-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZDATE REAL, ZDURATION REAL,
              ZADDRESS TEXT, ZANSWERED INTEGER, ZORIGINATED INTEGER, ZSERVICE_PROVIDER TEXT, ZNAME TEXT);
            INSERT INTO ZCALLRECORD (ZDATE, ZADDRESS, ZNAME) VALUES (1000, '+15550000001', 'Old Friend');
            """
        for i in 0 ..< 1_000 {
            sql +=
                "INSERT INTO ZCALLRECORD (ZDATE, ZADDRESS, ZNAME) VALUES (\(2000 + i), '+15550000002', 'Recent Caller');"
        }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testSearchReachesCallsOlderThanTheNewestRows() throws {
        let db = try CallHistoryService.CallHistoryDatabase(connection: ReadOnlySQLite(path: path))
        let found = try db.fetchCalls(startDate: nil, endDate: nil, direction: nil, limit: 30, matching: "old friend")
        XCTAssertEqual(found.map(\.contactName), ["Old Friend"])
    }

    func testReadOnlyConnectionOpensImmutable() {
        XCTAssertNoThrow(try ReadOnlySQLite(path: path, mode: .immutable))
    }

    func testReadOnlyConnectionReportsAMissingFile() {
        XCTAssertThrowsError(try ReadOnlySQLite(path: path + ".absent")) { error in
            XCTAssertTrue(error is ReadOnlySQLite.OpenError)
        }
    }

    /// The description is what the log records. It names the file and never
    /// its directory, and none of it reaches an MCP client.
    func testOpenFailureIsLoggedByFileNameAndHiddenFromClients() {
        let absent = path + ".absent"
        XCTAssertThrowsError(try ReadOnlySQLite(path: absent)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Failed to open \(URL(fileURLWithPath: absent).lastPathComponent): unable to open database file"
            )
            XCTAssertFalse(error.localizedDescription.contains("/"))
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "Tool execution failed. See iMCP logs for details."
            )
        }
    }

    func testSearchStopsAtTheLimit() throws {
        let db = try CallHistoryService.CallHistoryDatabase(connection: ReadOnlySQLite(path: path))
        let found = try db.fetchCalls(startDate: nil, endDate: nil, direction: nil, limit: 30, matching: "recent")
        XCTAssertEqual(found.count, 30)
    }

    func testNoSearchKeepsTheNewestRows() throws {
        let db = try CallHistoryService.CallHistoryDatabase(connection: ReadOnlySQLite(path: path))
        let found = try db.fetchCalls(startDate: nil, endDate: nil, direction: nil, limit: 5)
        XCTAssertEqual(found.count, 5)
        XCTAssertTrue(found.allSatisfy { $0.contactName == "Recent Caller" })
    }
}
