import OSLog

private let log = Logger.service("screentime")
private let defaultLimit = 20
private let defaultRangeDuration: TimeInterval = 7 * 24 * 60 * 60
/// The most usage history one call reads. It bounds what a single call can
/// export, like the row caps on the other history tools (added with them in
/// the August 2026 security fixes). A longer range keeps its end and moves its
/// start forward. The schema does not mention the cap; a caller learns of it
/// from the reply's `startDate`, which is the start actually read.
private let maximumRangeSpan: TimeInterval = 31 * 24 * 60 * 60

private enum UsageGrouping: String, CaseIterable { case app, day }

extension BookmarkedDatabase {
    static let knowledge = BookmarkedDatabase(
        path: NSHomeDirectory() + "/Library/Application Support/Knowledge/knowledgeC.db",
        bookmarkKey: "me.mattt.iMCP.knowledgeDatabaseBookmark",
        selection: .file,
        displayName: "Screen Time",
        purpose: "app usage history"
    )
}

final class ScreenTimeService: BookmarkedDatabaseService {
    static let shared = ScreenTimeService()

    let store = BookmarkedSQLiteStore(.knowledge, log: log)

    /// Defaults to the 7 days before now, and never spans more than
    /// `maximumRangeSpan`.
    static let range = ToolArgument.dateWindow(
        "Start of the date range (inclusive, ISO 8601). Defaults to 7 days ago.",
        "End of the date range (exclusive, ISO 8601). Defaults to now."
    ).map { window -> (start: Date, end: Date) in
        let end = window.end ?? Date()
        let start = window.start ?? end.addingTimeInterval(-defaultRangeDuration)
        guard start < end else { throw ToolInputError.startNotBeforeEnd("startDate", "endDate") }
        return (max(start, end.addingTimeInterval(-maximumRangeSpan)), end)
    }
    private static let appLimit = ToolArgument.limit(
        "Maximum number of apps to return (per day when groupBy is \"day\")",
        default: defaultLimit
    )
    private static let domainLimit = ToolArgument.limit("Maximum number of domains to return", default: defaultLimit)
    private static let groupBy = ToolArgument.choice(
        "groupBy",
        description:
            "Group usage over the whole range (\"app\") or per local calendar day (\"day\") for trend analysis",
        among: NamedCases<UsageGrouping>(),
        default: .app
    )

    var tools: [Tool] {
        Tool(
            name: "screentime_usage",
            description:
                "Summarize app usage from the macOS Screen Time (Knowledge) database, "
                + "grouped by app bundle identifier (optionally per day) and sorted by total usage time",
            arguments: [Self.range, Self.appLimit, Self.groupBy],
            annotations: .init(
                title: "Screen Time Usage",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting Screen Time usage fetch with arguments: \(arguments)")

            let (startDate, endDate) = try Self.range(arguments)
            let limit = try Self.appLimit(arguments)
            let groupBy = try Self.groupBy(arguments)

            let items: [Value]
            if groupBy == .day {
                items = try self.knowledge { try $0.fetchDailyUsage(start: startDate, end: endDate, limit: limit) }
                log.debug("Successfully fetched daily usage rows: \(items.count)")
            } else {
                items = try self.knowledge { try $0.fetchUsage(start: startDate, end: endDate, limit: limit) }
                log.debug("Successfully fetched usage for \(items.count) apps")
            }

            return Self.itemList(items, start: startDate, end: endDate)
        }

        Tool(
            name: "screentime_web_usage",
            description:
                "Summarize web browsing time per domain from the macOS Screen Time (Knowledge) "
                + "database, across all browsers, sorted by total time spent",
            arguments: [Self.range, Self.domainLimit],
            annotations: .init(
                title: "Screen Time Web Usage",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting Screen Time web usage fetch")

            let (startDate, endDate) = try Self.range(arguments)
            let limit = try Self.domainLimit(arguments)

            let items = try self.knowledge { try $0.fetchWebUsage(start: startDate, end: endDate, limit: limit) }
            log.debug("Successfully fetched web usage for \(items.count) domains")

            return Self.itemList(items, start: startDate, end: endDate)
        }

        Tool(
            name: "screentime_device_activity",
            description:
                "Report daily device active time from the macOS Screen Time (Knowledge) database, "
                + "based on when the display was on: total active seconds, first-on and last-off "
                + "times per local calendar day (a proxy for wake/sleep rhythm)",
            arguments: [Self.range],
            annotations: .init(
                title: "Screen Time Device Activity",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting Screen Time device activity fetch")

            let (startDate, endDate) = try Self.range(arguments)

            let items = try self.knowledge { try $0.fetchDeviceActivity(start: startDate, end: endDate) }
            log.debug("Successfully fetched device activity for \(items.count) days")

            return Self.itemList(items, start: startDate, end: endDate)
        }
    }

    private func knowledge<T>(_ read: (KnowledgeDatabase) throws -> T) throws -> T {
        try store.withConnection { try read(KnowledgeDatabase(connection: $0)) }
    }

    private static func itemList(_ items: [Value], start: Date, end: Date) -> Value {
        .itemList(items, extra: ["startDate": .string(start.localISO8601), "endDate": .string(end.localISO8601)])
    }
}

struct KnowledgeDatabase {
    /// The local calendar day a session counts towards. A session that began
    /// before the range is bucketed on the range's first day, not outside it.
    private static let day =
        "date(MAX(ZSTARTDATE, ?1) + \(Int(Date.timeIntervalBetween1970AndReferenceDate)), 'unixepoch', 'localtime')"

    let connection: ReadOnlySQLite

    /// Runs a query whose `?1` and `?2` are the range start and end as Core
    /// Data timestamps and whose `?3`, if present, is the row limit.
    private func rows(
        _ sql: String,
        start: Date,
        end: Date,
        limit: Int? = nil,
        _ row: (SQLiteRow) -> Value?
    ) throws -> [Value] {
        try connection.rows(
            sql,
            [.coreDataDate(start), .coreDataDate(end)] + (limit.map { [.int(Int64($0))] } ?? []),
            row
        )
    }

    func fetchUsage(start: Date, end: Date, limit: Int) throws -> [Value] {
        let sql = """
            SELECT ZVALUESTRING AS bundle,
                   SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) AS total,
                   COUNT(*) AS sessions
            FROM ZOBJECT
            WHERE ZSTREAMNAME = '/app/usage'
              AND ZVALUESTRING IS NOT NULL
              AND ZSTARTDATE < ?2
              AND ZENDDATE > ?1
            GROUP BY ZVALUESTRING
            ORDER BY total DESC
            LIMIT ?3
            """
        return try rows(sql, start: start, end: end, limit: limit) { row in
            guard let bundle = row.text(0) else { return nil }
            return [
                "bundleIdentifier": .string(bundle),
                "totalSeconds": .int(Int(row.double(1).rounded())),
                "sessions": .int(Int(row.int64(2))),
            ]
        }
    }

    /// Local-time day buckets match the Screen Time UI.
    func fetchDailyUsage(start: Date, end: Date, limit: Int) throws -> [Value] {
        let sql = """
            SELECT day, bundle, total, sessions FROM (
                SELECT \(Self.day) AS day,
                       ZVALUESTRING AS bundle,
                       SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) AS total,
                       COUNT(*) AS sessions,
                       ROW_NUMBER() OVER (
                           PARTITION BY \(Self.day)
                           ORDER BY SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) DESC
                       ) AS rank
                FROM ZOBJECT
                WHERE ZSTREAMNAME = '/app/usage'
                  AND ZVALUESTRING IS NOT NULL
                  AND ZSTARTDATE < ?2
                  AND ZENDDATE > ?1
                GROUP BY day, bundle
            )
            WHERE rank <= ?3
            ORDER BY day ASC, total DESC
            """
        return try rows(sql, start: start, end: end, limit: limit) { row in
            guard let day = row.text(0), let bundle = row.text(1) else { return nil }
            return [
                "date": .string(day),
                "bundleIdentifier": .string(bundle),
                "totalSeconds": .int(Int(row.double(2).rounded())),
                "sessions": .int(Int(row.int64(3))),
            ]
        }
    }

    /// Domain is on the structured-metadata row, not on ZOBJECT.
    func fetchWebUsage(start: Date, end: Date, limit: Int) throws -> [Value] {
        let sql = """
            SELECT metadata.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN AS domain,
                   SUM(MIN(object.ZENDDATE, ?2) - MAX(object.ZSTARTDATE, ?1)) AS total,
                   COUNT(*) AS visits
            FROM ZOBJECT object
            JOIN ZSTRUCTUREDMETADATA metadata
              ON object.ZSTRUCTUREDMETADATA = metadata.Z_PK
            WHERE object.ZSTREAMNAME = '/app/webUsage'
              AND metadata.Z_DKDIGITALHEALTHMETADATAKEY__WEBDOMAIN IS NOT NULL
              AND object.ZSTARTDATE < ?2
              AND object.ZENDDATE > ?1
            GROUP BY domain
            ORDER BY total DESC
            LIMIT ?3
            """
        return try rows(sql, start: start, end: end, limit: limit) { row in
            guard let domain = row.text(0) else { return nil }
            return [
                "domain": .string(domain),
                "totalSeconds": .int(Int(row.double(1).rounded())),
                "visits": .int(Int(row.int64(2))),
            ]
        }
    }

    func fetchDeviceActivity(start: Date, end: Date) throws -> [Value] {
        let sql = """
            SELECT \(Self.day) AS day,
                   SUM(MIN(ZENDDATE, ?2) - MAX(ZSTARTDATE, ?1)) AS total,
                   MIN(MAX(ZSTARTDATE, ?1)) AS firstOn,
                   MAX(MIN(ZENDDATE, ?2)) AS lastOff
            FROM ZOBJECT
            WHERE ZSTREAMNAME = '/display/isBacklit'
              AND ZVALUEINTEGER = 1
              AND ZSTARTDATE < ?2
              AND ZENDDATE > ?1
            GROUP BY day
            ORDER BY day ASC
            """
        return try rows(sql, start: start, end: end) { row in
            guard let day = row.text(0) else { return nil }
            return [
                "date": .string(day),
                "activeSeconds": .int(Int(row.double(1).rounded())),
                "firstOn": .string(row.coreDataDate(2).localISO8601),
                "lastOff": .string(row.coreDataDate(3).localISO8601),
            ]
        }
    }
}
