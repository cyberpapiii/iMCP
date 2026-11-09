import Foundation
import OSLog

private let log = Logger.service("browserhistory")

/// Seconds between the Windows/WebKit epoch (1601-01-01) and the Unix epoch,
/// used by Chromium's `visits.visit_time` (stored in microseconds).
private let webKitReferenceOffset: TimeInterval = 11_644_473_600

enum Browser: String, CaseIterable {
    case chrome
    case arc
    case safari

    var databasePath: String {
        let home = NSHomeDirectory()
        switch self {
        case .chrome:
            return "\(home)/Library/Application Support/Google/Chrome/Default/History"
        case .arc:
            return "\(home)/Library/Application Support/Arc/User Data/Default/History"
        case .safari:
            return "\(home)/Library/Safari/History.db"
        }
    }

    /// Chromium browsers (Chrome, Arc) share one schema and epoch; Safari
    /// uses its own.
    var isChromium: Bool {
        switch self {
        case .chrome, .arc:
            return true
        case .safari:
            return false
        }
    }

    func timestamp(from date: Date) -> Double {
        if isChromium {
            return (date.timeIntervalSince1970 + webKitReferenceOffset) * 1_000_000
        }
        return date.timeIntervalSinceReferenceDate
    }

    func date(fromTimestamp value: Double) -> Date {
        if isChromium {
            return Date(timeIntervalSince1970: value / 1_000_000 - webKitReferenceOffset)
        }
        return Date(timeIntervalSinceReferenceDate: value)
    }
}

final class BrowserHistoryService: Service {
    static let shared = BrowserHistoryService()

    /// No picker: Safari, Chrome, and Arc are read only with the grant.
    var permission: ServicePermission { .fullDiskAccess(hasPicker: false) }

    static let unreadable = ToolFailure(
        "No Safari, Chrome, or Arc history is readable. \(ServicePermission.fullDiskAccessGrantInstruction)"
    )

    func activate() async throws {
        if await isActivated { return }
        throw Self.unreadable
    }

    var isActivated: Bool {
        get async { !Self.readableDatabases(Browser.allCases).isEmpty }
    }

    /// The databases of `browsers` that open. `isReadableFile` can be true
    /// for Safari without Full Disk Access, so only a real open proves access.
    private static func readableDatabases(_ browsers: [Browser]) -> [BrowserHistoryDatabase] {
        browsers.compactMap { browser in
            guard FileManager.default.isReadableFile(atPath: browser.databasePath) else {
                log.debug("Skipping absent browser database: \(browser.rawValue)")
                return nil
            }
            do {
                return try BrowserHistoryDatabase(browser: browser)
            } catch {
                log.error("Failed to open \(browser.rawValue) history: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static let window = ToolArgument.dateWindow()
    /// The one choice that falls back by design, as its description says.
    private static let browser = ToolArgument.choice(
        "browser",
        description: "Restrict results to a single browser. Unknown values fall back to all.",
        among: NamedCases<Browser?>([("all", nil)] + Browser.allCases.map { ($0.rawValue, $0) }),
        default: nil,
        unknownFallsBack: true
    )
    private static let query = ToolArgument.searchTerm(
        "Keep only pages whose URL or title contains this term",
        trimmed: true
    )
    private static let limit = ToolArgument.limit("Maximum pages to return")

    var tools: [Tool] {
        Tool(
            name: "browser_history_search",
            description:
                "Search browsing history across Chrome, Arc, and Safari by date range and "
                + "search term, returning visited pages (url, title, visit time, browser) "
                + "most recent first",
            arguments: [Self.window, Self.browser, Self.query, Self.limit],
            annotations: .init(
                title: "Search Browser History",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            log.debug("Starting browser history search")

            let searchTerm = try Self.query(arguments)
            let window = try Self.window(arguments)
            let limit = try Self.limit(arguments)
            let browsers = try Self.browser(arguments).map { [$0] } ?? Browser.allCases

            var visits: [BrowserHistoryDatabase.Visit] = []
            var readSucceeded = false
            for db in Self.readableDatabases(browsers) {
                do {
                    visits += try db.fetchVisits(
                        startDate: window.start,
                        endDate: window.end,
                        searchTerm: searchTerm,
                        limit: limit
                    )
                    readSucceeded = true
                } catch {
                    log.error("Failed to read \(db.browser.rawValue) history: \(error.localizedDescription)")
                }
            }

            guard readSucceeded else {
                throw Self.unreadable
            }

            visits.sort { $0.visitedAt > $1.visitedAt }
            let limited = Array(visits.prefix(limit))

            let items = limited.map { visit in
                var object: [String: Value] = [
                    "url": .string(visit.url),
                    "browser": .string(visit.browser.rawValue),
                    "visitedAt": .string(visit.visitedAt.localISO8601),
                ]
                if let title = visit.title, !title.isEmpty {
                    object["title"] = .string(title)
                }
                return Value.object(object)
            }

            return Value.itemList(items)
        }
    }

    private struct BrowserHistoryDatabase {
        struct Visit {
            let browser: Browser
            let url: String
            let title: String?
            let visitedAt: Date
        }

        let browser: Browser
        private let connection: ReadOnlySQLite

        init(browser: Browser) throws {
            self.browser = browser
            connection = try ReadOnlySQLite(path: browser.databasePath, mode: .immutable)
        }

        func fetchVisits(
            startDate: Date?,
            endDate: Date?,
            searchTerm: String?,
            limit: Int
        ) throws -> [Visit] {
            let timeColumn = browser.isChromium ? "visits.visit_time" : "history_visits.visit_time"
            let urlColumn = browser.isChromium ? "urls.url" : "history_items.url"
            let titleColumn = browser.isChromium ? "urls.title" : "history_visits.title"

            var conditions: [String] = []
            var bindings: [SQLiteValue] = []
            if let startDate {
                conditions.append("\(timeColumn) >= ?")
                bindings.append(.double(browser.timestamp(from: startDate)))
            }
            if let endDate {
                conditions.append("\(timeColumn) < ?")
                bindings.append(.double(browser.timestamp(from: endDate)))
            }
            // Filter by search term in SQL so LIMIT applies to matching rows,
            // not just the newest rows (which client-side filtering would miss).
            if let searchTerm {
                conditions.append(
                    "(\(urlColumn) LIKE ? ESCAPE '\\' OR \(titleColumn) LIKE ? ESCAPE '\\')"
                )
                let pattern = "%\(Self.escapeLikePattern(searchTerm))%"
                bindings.append(.text(pattern))
                bindings.append(.text(pattern))
            }

            let whereClause =
                conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

            let sql: String
            if browser.isChromium {
                sql = """
                    SELECT urls.url, urls.title, visits.visit_time
                    FROM visits
                    JOIN urls ON urls.id = visits.url
                    \(whereClause)
                    ORDER BY visits.visit_time DESC
                    LIMIT ?
                    """
            } else {
                sql = """
                    SELECT history_items.url, history_visits.title, history_visits.visit_time
                    FROM history_visits
                    JOIN history_items ON history_items.id = history_visits.history_item
                    \(whereClause)
                    ORDER BY history_visits.visit_time DESC
                    LIMIT ?
                    """
            }

            bindings.append(.int(Int64(limit)))
            return try connection.rows(sql, bindings) { row in
                guard let url = row.text(0) else { return nil }
                return Visit(
                    browser: browser,
                    url: url,
                    title: row.text(1),
                    visitedAt: browser.date(fromTimestamp: row.double(2))
                )
            }
        }

        /// Escapes SQL `LIKE` wildcards so a user's literal `%`, `_`, or `\`
        /// are matched literally under `ESCAPE '\'`.
        private static func escapeLikePattern(_ term: String) -> String {
            var escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
            escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
            return escaped
        }
    }
}
