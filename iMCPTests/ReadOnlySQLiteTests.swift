import SQLite3
import XCTest

@testable import iMCP

final class ReadOnlySQLiteTests: XCTestCase {
    private func makeDatabase() throws -> String {
        let path = try makeTemporaryDirectory().appendingPathComponent("fixture.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
            CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, at REAL, payload BLOB);
            INSERT INTO item VALUES (1, 'one', 10, x'0102');
            INSERT INTO item VALUES (2, NULL, 20, NULL);
            INSERT INTO item VALUES (3, 'three', 30, x'03');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return path
    }

    func testRowsBindInOrderAndReadTypedColumns() throws {
        let connection = try ReadOnlySQLite(path: try makeDatabase())
        let rows = try connection.rows(
            "SELECT id, name, at, payload FROM item WHERE at >= ? AND id != ? ORDER BY id",
            [.coreDataDate(Date(timeIntervalSinceReferenceDate: 15)), .int(3)]
        ) { row in
            (row.int64(0), row.text(1), row.coreDataDate(2), row.blob(3))
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, 2)
        XCTAssertNil(rows[0].1, "NULL text reads as nil")
        XCTAssertEqual(rows[0].2, Date(timeIntervalSinceReferenceDate: 20))
        XCTAssertNil(rows[0].3, "NULL blob reads as nil")
    }

    func testANilRowIsSkippedAndTheLimitCountsKeptRows() throws {
        let connection = try ReadOnlySQLite(path: try makeDatabase())
        let named = try connection.rows("SELECT name FROM item ORDER BY id", limit: 1) { $0.text(0) }
        XCTAssertEqual(named, ["one"])
        let all = try connection.rows("SELECT name FROM item ORDER BY id") { $0.text(0) }
        XCTAssertEqual(all, ["one", "three"])
        XCTAssertEqual(
            try connection.rows("SELECT payload FROM item WHERE id = ?", [.text("1")]) { $0.blob(0) },
            [Data([1, 2])]
        )
    }

    /// A database image read from memory: the same rows, and no writes.
    func testADeserializedImageReadsAndRefusesWrites() throws {
        let image = try Data(contentsOf: URL(fileURLWithPath: try makeDatabase()))
        let connection = try ReadOnlySQLite(deserializing: image)

        XCTAssertEqual(try connection.rows("SELECT name FROM item ORDER BY id") { $0.text(0) }, ["one", "three"])
        XCTAssertThrowsError(try connection.rows("INSERT INTO item VALUES (4, 'four', 40, NULL)") { _ in () })
        XCTAssertThrowsError(
            try ReadOnlySQLite(deserializing: Data("not a database".utf8)).rows("SELECT 1 FROM item") { _ in () }
        )
    }

    /// A query error is for the log: it never reaches a client verbatim.
    func testABadQueryThrowsALogOnlyError() throws {
        let connection = try ReadOnlySQLite(path: try makeDatabase())
        XCTAssertThrowsError(try connection.rows("SELECT nope FROM item") { $0.text(0) }) { error in
            XCTAssertTrue(error is SQLiteQueryError)
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Tool execution failed. See iMCP logs for details.")
        }
    }

    func testEveryOpenModeReads() throws {
        let path = try makeDatabase()
        for mode: ReadOnlySQLite.Mode in [
            .readOnly, .immutable, .companion(immutable: true, busyTimeoutMilliseconds: 1000),
            .companion(immutable: false, busyTimeoutMilliseconds: 1000),
        ] {
            let ids = try ReadOnlySQLite(path: path, mode: mode).rows("SELECT id FROM item") { $0.int64(0) }
            XCTAssertEqual(ids.count, 3)
        }
    }

    func testFileAccessStatusReadsTheErrno() {
        XCTAssertEqual(FileAccessStatus(errno: EACCES), .denied)
        XCTAssertEqual(FileAccessStatus(errno: EPERM), .denied)
        XCTAssertEqual(FileAccessStatus(errno: ENOENT), .missing)
        XCTAssertEqual(FileAccessStatus(errno: ENOTDIR), .notADirectory)
        XCTAssertEqual(FileAccessStatus(errno: EIO), .other)
    }

}
