import Foundation
import SQLite3

/// SQLite copies a bound string or blob before the bind call returns.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value bound to a `?` placeholder, in order.
enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    /// A Core Data timestamp: seconds since 2001-01-01.
    case coreDataDate(Date)
}

/// The current row of a running query. Columns count from 0.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    /// nil for NULL. SQLite converts a BLOB or number to text.
    func text(_ column: Int32) -> String? {
        guard !isNull(column), let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int(statement, column) != 0
    }

    /// nil for NULL.
    func blob(_ column: Int32) -> Data? {
        guard !isNull(column), let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func coreDataDate(_ column: Int32) -> Date {
        Date(timeIntervalSinceReferenceDate: double(column))
    }
}

/// A statement that would not prepare or step. Not a `ClientFacingError`:
/// the message is SQLite's, for the log line, and never reaches a client.
struct SQLiteQueryError: LocalizedError {
    let message: String
    var errorDescription: String? { "SQLite query failed: \(message)" }
}

/// A read-only SQLite connection, closed when released.
final class ReadOnlySQLite {
    enum Mode {
        case readOnly
        /// Skips locking and the write-ahead log, so a database held open by
        /// another app can still be read, possibly slightly stale.
        case immutable
        /// A second connection beside one another library holds on the same
        /// file. It has to open the file the way that library did: when the
        /// first connection ignores the write-ahead log, one that tries to
        /// read it is refused.
        case companion(immutable: Bool, busyTimeoutMilliseconds: Int32)
    }

    /// Not a `ClientFacingError`: the description is for the log line written
    /// where the error is caught, and never reaches an MCP client.
    struct OpenError: LocalizedError {
        /// The last path component only. A full path would put the user's
        /// home directory in the log.
        let fileName: String
        let message: String
        var errorDescription: String? { "Failed to open \(fileName): \(message)" }
    }

    private let handle: OpaquePointer

    init(path: String, mode: Mode = .readOnly) throws {
        var handle: OpaquePointer?
        let status: Int32
        switch mode {
        case .readOnly:
            status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        case .immutable:
            status = sqlite3_open_v2("file:\(path)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        case .companion(let immutable, _):
            status = sqlite3_open_v2(
                "file:\(path)?\(immutable ? "immutable=1&mode=ro" : "mode=ro")",
                &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX,
                nil
            )
        }
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw OpenError(fileName: URL(fileURLWithPath: path).lastPathComponent, message: message)
        }
        if case .companion(_, let busyTimeout) = mode {
            sqlite3_busy_timeout(handle, busyTimeout)
        }
        self.handle = handle
    }

    /// A private in-memory database over a copy of `image`, for a database
    /// that must never touch disk (Find My People's decrypted pages). Temp
    /// storage stays in memory too, and the connection refuses writes.
    init(deserializing image: Data) throws {
        var opened: OpaquePointer?
        guard
            sqlite3_open_v2(":memory:", &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_MEMORY, nil) == SQLITE_OK,
            let handle = opened
        else {
            sqlite3_close(opened)
            throw OpenError(fileName: ":memory:", message: "could not open an in-memory database")
        }
        func fail(_ message: String) -> OpenError {
            sqlite3_close(handle)
            return OpenError(fileName: ":memory:", message: message)
        }
        guard sqlite3_exec(handle, "PRAGMA temp_store=MEMORY; PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK
        else { throw fail(String(cString: sqlite3_errmsg(handle))) }
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(image.count))?.assumingMemoryBound(to: UInt8.self) else {
            throw fail("out of memory")
        }
        image.copyBytes(to: buffer, count: image.count)
        // SQLite owns the buffer from here: with FREEONCLOSE it frees it on
        // close, and also when the deserialize itself fails.
        guard
            sqlite3_deserialize(
                handle,
                "main",
                buffer,
                sqlite3_int64(image.count),
                sqlite3_int64(image.count),
                UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
            ) == SQLITE_OK
        else { throw fail(String(cString: sqlite3_errmsg(handle))) }
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs `sql` with `bindings` and collects what `row` makes of each row;
    /// a nil from `row` skips that row. With `limit`, reading stops once that
    /// many rows are collected, so a query filtered here need not read the
    /// whole table.
    func rows<T>(
        _ sql: String,
        _ bindings: [SQLiteValue] = [],
        limit: Int? = nil,
        _ row: (SQLiteRow) throws -> T?
    ) throws -> [T] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw SQLiteQueryError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case .coreDataDate(let date):
                sqlite3_bind_double(statement, index, date.timeIntervalSinceReferenceDate)
            }
        }

        var results: [T] = []
        while limit.map({ results.count < $0 }) ?? true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw SQLiteQueryError(message: String(cString: sqlite3_errmsg(handle)))
            }
            if let value = try row(SQLiteRow(statement: statement)) {
                results.append(value)
            }
        }
        return results
    }
}
