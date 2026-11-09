import Foundation
import OSLog

private let log = Logger.service("callhistory")

extension BookmarkedDatabase {
    static let callHistory = BookmarkedDatabase(
        path: NSHomeDirectory() + "/Library/Application Support/CallHistoryDB/CallHistory.storedata",
        bookmarkKey: "me.mattt.iMCP.callHistoryDatabaseBookmark",
        selection: .file,
        displayName: "Call History",
        purpose: "call history"
    )
}

final class CallHistoryService: BookmarkedDatabaseService {
    static let shared = CallHistoryService()

    let store = BookmarkedSQLiteStore(.callHistory, log: log)

    private static let window = ToolArgument.dateWindow()
    private static let direction = ToolArgument.choice(
        "direction",
        description: "Filter by call direction",
        among: NamedCases<CallDirection?>([("incoming", .incoming), ("outgoing", .outgoing), ("any", nil)]),
        default: nil
    )
    private static let query = ToolArgument.searchTerm(
        "Keep only calls whose address or contact name contains this term"
    )
    private static let limit = ToolArgument.limit("Maximum calls to return")

    var tools: [Tool] {
        Tool(
            name: "calls_fetch",
            description:
                "Fetch phone and FaceTime calls from the call history database, most recent first, "
                + "with direction, duration in seconds, address, contact name, and whether it was answered",
            arguments: [Self.window, Self.direction, Self.query, Self.limit],
            annotations: .init(
                title: "Fetch Calls",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting call fetch with arguments: \(arguments)")

            let searchTerm = try Self.query(arguments)
            let window = try Self.window(arguments)
            let limit = try Self.limit(arguments)
            let direction = try Self.direction(arguments)

            let records = try self.store.withConnection { connection in
                try CallHistoryDatabase(connection: connection).fetchCalls(
                    startDate: window.start,
                    endDate: window.end,
                    direction: direction,
                    limit: limit,
                    matching: searchTerm
                )
            }

            var calls: [[String: Value]] = []
            for record in records {

                var call: [String: Value] = [
                    "@id": .string("call:\(record.id)"),
                    "direction": .string(record.isOutgoing ? "outgoing" : "incoming"),
                    "answered": .bool(record.isAnswered),
                    "duration": .double(record.duration),
                    "createdAt": .string(record.date.localISO8601),
                ]
                if let address = record.address {
                    call["address"] = .string(address)
                }
                if let contactName = record.contactName {
                    call["contactName"] = .string(contactName)
                }
                if let serviceProvider = record.serviceProvider {
                    call["service"] = .string(serviceProvider)
                }

                calls.append(call)
            }

            log.debug("Successfully fetched \(calls.count) calls")
            return Value.itemList(calls.map { .object($0) })
        }
    }

    enum CallDirection {
        case incoming
        case outgoing
    }

    struct CallRecord {
        let id: Int64
        let date: Date
        let duration: Double
        let address: String?
        let contactName: String?
        let isAnswered: Bool
        let isOutgoing: Bool
        let serviceProvider: String?

        func matches(_ searchTerm: String) -> Bool {
            (address?.localizedCaseInsensitiveContains(searchTerm) ?? false)
                || (contactName?.localizedCaseInsensitiveContains(searchTerm) ?? false)
        }
    }

    struct CallHistoryDatabase {
        let connection: ReadOnlySQLite

        func fetchCalls(
            startDate: Date?,
            endDate: Date?,
            direction: CallDirection?,
            limit: Int,
            matching searchTerm: String? = nil
        ) throws -> [CallRecord] {
            var conditions: [String] = []
            var bindings: [SQLiteValue] = []

            if let startDate {
                conditions.append("ZDATE >= ?")
                bindings.append(.coreDataDate(startDate))
            }
            if let endDate {
                conditions.append("ZDATE < ?")
                bindings.append(.coreDataDate(endDate))
            }
            if let direction {
                conditions.append("ZORIGINATED = \(direction == .outgoing ? 1 : 0)")
            }

            var sql = """
                SELECT Z_PK, ZDATE, ZDURATION, ZADDRESS, ZANSWERED, ZORIGINATED,
                       ZSERVICE_PROVIDER, ZNAME
                FROM ZCALLRECORD
                """
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY ZDATE DESC"

            return try connection.rows(sql, bindings, limit: limit) { row in
                let record = CallRecord(
                    id: row.int64(0),
                    date: row.coreDataDate(1),
                    duration: row.double(2),
                    // ZADDRESS may be TEXT or BLOB by OS version; both read as text.
                    address: row.text(3),
                    contactName: row.text(7),
                    isAnswered: row.bool(4),
                    isOutgoing: row.bool(5),
                    serviceProvider: row.text(6)
                )
                if let searchTerm, !record.matches(searchTerm) { return nil }
                return record
            }
        }
    }
}
