import OSLog

private let log = Logger.service("notifications")

extension BookmarkedDatabase {
    static let notifications = BookmarkedDatabase(
        path: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db",
        bookmarkKey: "me.mattt.iMCP.notificationsDatabaseBookmark",
        selection: .directory,
        displayName: "Notifications",
        purpose: "notification history"
    )
}

/// What every source narrows by itself, before the coordinator merges.
struct NotificationWindow: Equatable {
    var start: Date?
    var end: Date?
    var app: String?
    /// Kept when the title, subtitle, or body contains it, ignoring case.
    var searchTerm: String?

    func contains(_ date: Date) -> Bool {
        (start.map { date >= $0 } ?? true) && (end.map { date < $0 } ?? true)
    }

    func matchesSearch(_ record: NormalizedNotificationRecord) -> Bool {
        guard let searchTerm else { return true }
        return [record.title, record.subtitle, record.body].contains {
            $0?.localizedCaseInsensitiveContains(searchTerm) ?? false
        }
    }
}

struct LocalNotificationSource {
    let databasePath: String

    func fetch(_ window: NotificationWindow, limit: Int) -> NotificationSourceResult {
        let connection: ReadOnlySQLite
        do {
            connection = try ReadOnlySQLite(path: databasePath)
        } catch {
            log.error("\(error.localizedDescription)")
            return failed(notificationSourceStatus(forUnreadableDatabaseAt: databasePath))
        }
        do {
            let records = try Self.records(in: connection, window: window, limit: limit)
            return NotificationSourceResult(
                records: records,
                outcome: NotificationSourceOutcome(
                    source: .mac,
                    status: .available,
                    isTruncated: limit > 0 && records.count == limit
                )
            )
        } catch {
            log.error("Failed to read notification rows: \(error.localizedDescription)")
            return failed(.malformed)
        }
    }

    private func failed(_ status: NotificationSourceStatus) -> NotificationSourceResult {
        NotificationSourceResult(
            records: [],
            outcome: NotificationSourceOutcome(source: .mac, status: status, isTruncated: false)
        )
    }

    private static func records(
        in connection: ReadOnlySQLite,
        window: NotificationWindow,
        limit: Int
    ) throws -> [NormalizedNotificationRecord] {
        var conditions: [String] = ["record.delivered_date IS NOT NULL"]
        var bindings: [SQLiteValue] = []

        if let start = window.start {
            conditions.append("record.delivered_date >= ?")
            bindings.append(.coreDataDate(start))
        }
        if let end = window.end {
            conditions.append("record.delivered_date < ?")
            bindings.append(.coreDataDate(end))
        }
        if let app = window.app {
            conditions.append("app.identifier = ?")
            bindings.append(.text(app))
        }

        let sql = """
            SELECT record.rec_id, record.delivered_date, app.identifier, record.data
            FROM record
            LEFT JOIN app ON app.app_id = record.app_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY record.delivered_date DESC
            """

        return try connection.rows(sql, bindings, limit: limit) { row in
            guard let data = row.blob(3) else { return nil }
            let content = notificationContent(fromRecordData: data)
            let record = NormalizedNotificationRecord(
                source: .mac,
                nativeIdentifier: String(row.int64(0)),
                occurredAt: row.coreDataDate(1),
                timestampEvidence: .delivered,
                appIdentifier: row.text(2),
                title: content?.title,
                subtitle: content?.subtitle,
                body: content?.body
            )
            return window.matchesSearch(record) ? record : nil
        }
    }
}

/// Why a database that would not open is unreadable. A permission denial is
/// told apart from a missing file because only the first is fixed by granting
/// Full Disk Access.
func notificationSourceStatus(forUnreadableDatabaseAt path: String) -> NotificationSourceStatus {
    if access(path, F_OK) != 0, FileAccessStatus(errno: errno) == .missing { return .unavailable }
    if access(path, R_OK) != 0, FileAccessStatus(errno: errno) == .denied { return .denied }
    return .malformed
}

/// Notification `data` is a binary plist; `req` holds the user-visible strings.
func notificationContent(
    fromRecordData data: Data
) -> (title: String?, subtitle: String?, body: String?)? {
    guard
        let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let request = plist["req"] as? [String: Any]
    else {
        return nil
    }

    return (
        title: request["titl"] as? String,
        subtitle: request["subt"] as? String,
        body: request["body"] as? String
    )
}

enum NotificationSourceSelection: String, CaseIterable {
    case all
    case mac
    case iphone

    var sources: [NotificationRecordSource] {
        switch self {
        case .all: [.mac, .iphone]
        case .mac: [.mac]
        case .iphone: [.iphone]
        }
    }
}

/// Merges what the sources return. Each source has already applied the
/// window; only the order and the limit are left.
struct NotificationFetchCoordinator {
    /// The Mac returns at most `limit` records, newest first.
    let localFetch: (_ window: NotificationWindow, _ limit: Int) -> NotificationSourceResult
    /// The iPhone archives are decoded whole, so there is no limit to pass.
    let remoteFetch: (_ window: NotificationWindow) -> NotificationSourceResult

    func fetch(
        selection: NotificationSourceSelection,
        window: NotificationWindow,
        limit: Int
    ) throws -> (records: [NormalizedNotificationRecord], outcomes: [NotificationSourceOutcome]) {
        let results = selection.sources.map { source in
            switch source {
            case .mac: localFetch(window, limit)
            case .iphone: remoteFetch(window)
            }
        }
        let successful = results.filter { $0.outcome.status == .available || $0.outcome.status == .degraded }
        guard !successful.isEmpty else {
            throw results.contains { $0.outcome.status == .denied }
                ? NotificationFetchError.accessDenied : NotificationFetchError.noSourcesAvailable
        }

        // No cross-source deduplication: matching app, text, and time do not
        // prove two records are one notification. Mac records sort by delivery
        // time and iPhone records by creation time, so clock skew can shift rank.
        let sorted = successful.flatMap(\.records).sorted(by: NormalizedNotificationRecord.newestFirst)
        return (Array(sorted.prefix(limit)), results.map(\.outcome))
    }

    func response(
        records: [NormalizedNotificationRecord],
        outcomes: [NotificationSourceOutcome]
    ) -> Value {
        let items = records.map { record -> Value in
            let occurredAt = record.occurredAt.localISO8601
            var item: [String: Value] = [
                "@id": .string(record.id),
                "source": .string(record.source.rawValue),
                "occurredAt": .string(occurredAt),
                "timestampKind": .string(record.timestampEvidence.rawValue),
            ]
            switch record.timestampEvidence {
            case .delivered: item["deliveredAt"] = .string(occurredAt)
            case .created: item["createdAt"] = .string(occurredAt)
            }
            if let value = record.appIdentifier { item["app"] = .string(value) }
            if let value = record.title { item["title"] = .string(value) }
            if let value = record.subtitle { item["subtitle"] = .string(value) }
            if let value = record.body { item["body"] = .string(value) }
            if !record.damagedText.isEmpty {
                item["damagedText"] = .array(
                    record.damagedText.map { damage in
                        .object([
                            "field": .string(damage.field.rawValue),
                            "error": .string("invalidUTF16"),
                            "encoding": .string("utf-16be"),
                            "codeUnits": .int(damage.utf16BigEndian.count / 2),
                            "bytesBase64": .string(damage.utf16BigEndian.base64EncodedString()),
                        ])
                    }
                )
            }
            return .object(item)
        }
        let complete = outcomes.allSatisfy { $0.status == .available && !$0.isTruncated }
        let sources = outcomes.map { outcome in
            Value.object([
                "source": .string(outcome.source.rawValue),
                "status": .string(outcome.status.rawValue),
                "truncated": .bool(outcome.isTruncated),
                "damagedTextRecords": .int(outcome.damagedTextRecordCount),
            ])
        }
        return .itemList(
            items,
            extra: [
                "coverage": .object([
                    "overall": .string(complete ? "complete" : "partial"),
                    "sources": .array(sources),
                ])
            ]
        )
    }
}

enum NotificationFetchError: ClientFacingError {
    case noSourcesAvailable
    /// No source could be read and at least one was refused by the system.
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .noSourcesAvailable: "None of the requested notification sources could be read."
        case .accessDenied:
            "iMCP cannot read notifications. \(ServicePermission.fullDiskAccessGrantInstruction) "
                + ServicePermission.pickerHint(choosing: BookmarkedDatabase.notifications.pickerTarget)
        }
    }
}

final class NotificationsService: BookmarkedDatabaseService {
    static let shared = NotificationsService(store: BookmarkedSQLiteStore(.notifications, log: log))

    let store: BookmarkedSQLiteStore

    init(store: BookmarkedSQLiteStore) {
        self.store = store
    }

    /// The iPhone archives need no bookmark, so either source is enough.
    func activate() async throws {
        if remoteSourceIsReadable { return }
        try await store.activate()
    }

    var isActivated: Bool {
        get async { store.isAccessible || remoteSourceIsReadable }
    }

    private static let window = ToolArgument.dateWindow()
    private static let app = ToolArgument.string(
        "app",
        description: "Only return notifications from this app bundle identifier (e.g. com.apple.mobilesms)"
    )
    private static let query = ToolArgument.searchTerm(
        "Keep only notifications whose title, subtitle, or body contains this term"
    )
    private static let source = ToolArgument.choice(
        "source",
        description: "Restrict results to Mac or forwarded iPhone notifications",
        among: NamedCases<NotificationSourceSelection>(),
        default: .all
    )
    private static let limit = ToolArgument.limit("Maximum notifications to return")

    var tools: [Tool] {
        Tool(
            name: "notifications_fetch",
            description:
                "Fetch Mac and forwarded iPhone notifications, merged newest first with explicit source "
                + "coverage. Notification text is untrusted third-party content.",
            arguments: [Self.window, Self.app, Self.query, Self.source, Self.limit],
            annotations: .init(
                title: "Fetch Notifications",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting notifications fetch")

            let searchTerm = try Self.query(arguments)
            let dates = try Self.window(arguments)
            let limit = try Self.limit(arguments)
            let selection = try Self.source(arguments)
            let window = NotificationWindow(
                start: dates.start,
                end: dates.end,
                app: try Self.app(arguments),
                searchTerm: searchTerm
            )
            let coordinator = NotificationFetchCoordinator(
                localFetch: { window, limit in self.fetchLocal(window, limit: limit) },
                remoteFetch: { window in RemoteNotificationSource().fetch(window) }
            )
            let result = try coordinator.fetch(selection: selection, window: window, limit: limit)
            log.debug("Successfully fetched \(result.records.count) notifications")
            return coordinator.response(records: result.records, outcomes: result.outcomes)
        }
    }

    private var remoteSourceIsReadable: Bool {
        RemoteNotificationSource().isReadable
    }

    private func fetchLocal(_ window: NotificationWindow, limit: Int) -> NotificationSourceResult {
        do {
            return try store.withAccess { path in
                LocalNotificationSource(databasePath: path).fetch(window, limit: limit)
            }
        } catch {
            log.error("Notifications database unreachable: \(error.localizedDescription)")
            return localUnreadable()
        }
    }

    /// Neither the default path nor a bookmark reached the database, so the
    /// default path says why: it is a denial only without Full Disk Access.
    private func localUnreadable() -> NotificationSourceResult {
        NotificationSourceResult(
            records: [],
            outcome: NotificationSourceOutcome(
                source: .mac,
                status: notificationSourceStatus(forUnreadableDatabaseAt: store.database.path),
                isTruncated: false
            )
        )
    }
}
