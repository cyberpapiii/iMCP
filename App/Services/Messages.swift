import Foundation
import OSLog
import iMessage

private let log = Logger.service("messages")

extension BookmarkedDatabase {
    static let messages = BookmarkedDatabase(
        path: NSHomeDirectory() + "/Library/Messages/chat.db",
        bookmarkKey: "me.mattt.iMCP.messagesDatabaseBookmark",
        selection: .file,
        displayName: "Messages",
        purpose: "Messages history"
    )
}

final class MessageService: BookmarkedDatabaseService {
    static let shared = MessageService()

    let store = BookmarkedSQLiteStore(.messages, log: log)

    static let participants = ToolArgument<[String]>(
        "participants",
        .array(
            description: "Participant handles (phone or email). Phone numbers should use E.164 format",
            items: .string()
        )
    ) { present in
        // A blank handle used to be dropped, and with nothing left the read
        // went unfiltered: every conversation came back.
        try present.map { value in
            try ArgumentValue.array(value, "participants") { try ArgumentValue.trimmedNonBlankString($0, "handle") }
        } ?? []
    }
    /// An empty or non-string `chatId` is rejected rather than ignored, so a
    /// malformed filter cannot quietly widen the read to every conversation.
    static let chatID = ToolArgument<Chat.ID?>(
        "chatId",
        .string(
            description:
                "Keep only messages from this conversation. Use the @id of a message's isPartOf, which tells group chats apart from one-to-one chats with the same people"
        )
    ) { present in
        try present.map {
            Chat.ID(
                rawValue: try ArgumentValue.trimmedNonBlankString(
                    $0,
                    "chatId",
                    message: "Invalid chatId. Use the @id of a message's isPartOf."
                )
            )
        }
    }
    static let window = ToolArgument.dateWindow(
        start: "start",
        "Start of the date range (inclusive). May be given without end. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        end: "end",
        "End of the date range (exclusive). May be given without start. \(ArgumentDescription.localTimeAssumed) Date-only uses local midnight.",
        aliases: ("startDate", "endDate")
    )
    private static let query = ToolArgument.searchTerm(
        "Keep only messages whose text contains this term"
    )
    private static let isRead = ToolArgument<Bool?>.bool(
        "isRead",
        description: "true keeps only read messages; false keeps only messages received and not yet read"
    )
    private static let attachments = ToolArgument.bool(
        "attachments",
        description:
            "List each message's attachments (name, type, size) and include messages that are an attachment with no text. File contents are not returned",
        default: false
    )
    private static let limit = ToolArgument.limit("Maximum messages to return")

    var tools: [Tool] {
        Tool(
            name: "messages_fetch",
            description:
                "Fetch iMessage and SMS messages from the Messages database, returning sender, text, time, read state, and the conversation each message belongs to",
            arguments: [
                Self.participants, Self.chatID, Self.window, Self.query, Self.isRead, Self.attachments, Self.limit,
            ],
            annotations: .init(
                title: "Fetch Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await self.fetchMessages(arguments)
        }
    }

    private func fetchMessages(_ arguments: [String: Value]) async throws -> Value {
        log.debug("Starting message fetch with arguments: \(arguments)")

        let participants = try Self.participants(arguments)
        let chatID = try Self.chatID(arguments)
        let searchTerm = try Self.query(arguments)
        let isReadFilter = try Self.isRead(arguments)
        let includeAttachments = try Self.attachments(arguments)
        let window = try Self.window(arguments)
        let dateRange = Self.dateRange(start: window.start, end: window.end)
        let requestedLimit = try Self.limit(arguments)

        return try store.withAccess { (path: String) -> Value in
            let db = try iMessage.Database(path: path)
            log.debug("Fetching handles for participants: \(participants)")
            let handles = try Self.participantFilter(
                requested: participants,
                resolved: db.fetchParticipant(matching: participants)
            )
            var requested: [MessagePredicate] = []
            if let handles { requested.append(.participantHandles(handles)) }
            if let chatID { requested.append(.chatID(chatID)) }
            let filters = requested

            let attachmentReader =
                includeAttachments
                ? try AttachmentReader(path: path, immutable: db.accessMode == .immutable) : nil

            log.debug(
                "Fetching messages with date range: \(String(describing: dateRange)), limit: \(requestedLimit)"
            )
            let found: [FetchedMessage] = try Self.newestMatches(
                in: dateRange,
                limit: requestedLimit,
                id: \FetchedMessage.message.id,
                date: \FetchedMessage.message.date,
                matching: { (entry: FetchedMessage) -> Bool in
                    guard !entry.text.isEmpty || !entry.attachments.isEmpty else { return false }
                    if let isReadFilter {
                        // A message the user sent is neither read nor unread by them.
                        let isRead = entry.message.isFromMe || entry.message.isRead
                        guard isRead == isReadFilter else { return false }
                    }
                    return searchTerm.map { entry.text.localizedCaseInsensitiveContains($0) } ?? true
                },
                fetchPage: { (range: Range<Date>, pageSize: Int) -> [FetchedMessage] in
                    let page = try db.fetch(
                        FetchRequest<Message>(
                            predicate: .and(filters + [.dateRange(Self.representable(range))]),
                            limit: pageSize
                        )
                    )
                    let attachments: [String: [[String: Value]]] =
                        try attachmentReader?.attachments(ofMessages: page.map(\.id.rawValue)) ?? [:]
                    return page.map { (message: Message) -> FetchedMessage in
                        let listed = attachments[message.id.rawValue] ?? []
                        return FetchedMessage(
                            message: message,
                            text: includeAttachments
                                ? Self.textWithoutAttachmentPlaceholders(message.text) : message.text,
                            attachments: listed
                        )
                    }
                }
            )

            var conversations: [Chat.ID: [String: Value]] = [:]
            var messages: [[String: Value]] = []
            for entry in found {
                let message = entry.message
                let sender: String
                if message.isFromMe {
                    sender = "me"
                } else if let messageSender = message.sender {
                    sender = messageSender.rawValue
                } else {
                    sender = "unknown"
                }

                var object: [String: Value] = [
                    "@id": .string(message.id.description),
                    "sender": [
                        "@id": .string(sender)
                    ],
                    "text": .string(entry.text),
                    "createdAt": .string(message.date.localISO8601),
                ]
                if !message.isFromMe {
                    object["isRead"] = .bool(message.isRead)
                }
                if let readAt = message.readAt {
                    object["dateRead"] = .string(readAt.localISO8601)
                }
                if !entry.attachments.isEmpty {
                    object["attachment"] = .array(entry.attachments.map { .object($0) })
                }
                if let chatID = message.chatID {
                    if conversations[chatID] == nil {
                        conversations[chatID] = try Self.conversation(for: chatID, in: db)
                    }
                    object["isPartOf"] = conversations[chatID].map { .object($0) }
                }
                messages.append(object)
            }

            log.debug("Successfully fetched \(messages.count) messages")
            return [
                "@context": "https://schema.org",
                "@type": "Conversation",
                "hasPart": Value.array(messages.map({ .object($0) })),
            ]
        }
    }

    private struct FetchedMessage {
        let message: Message
        /// The message text with attachment placeholders removed, when
        /// attachments are listed separately.
        let text: String
        let attachments: [[String: Value]]
    }

    /// chat.db stores dates as Int64 nanoseconds since 2001, and madrid
    /// rejects a bound that does not fit. These stand in for an open end.
    private static let earliestDate = Date(timeIntervalSinceReferenceDate: -9_000_000_000)
    private static let latestDate = Date(timeIntervalSinceReferenceDate: 9_000_000_000)

    static func dateRange(start: Date?, end: Date?) -> Range<Date>? {
        guard start != nil || end != nil else { return nil }
        let lowerBound = start ?? earliestDate
        return lowerBound ..< max(lowerBound, end ?? latestDate)
    }

    /// Clamps a range to dates chat.db can hold, so paging from
    /// `Date.distantPast` or to `Date.distantFuture` is not a query error.
    static func representable(_ range: Range<Date>) -> Range<Date> {
        let lowerBound = min(max(range.lowerBound, earliestDate), latestDate)
        let upperBound = min(max(range.upperBound, lowerBound), latestDate)
        return lowerBound ..< upperBound
    }

    /// Messages marks where an attachment sits in the body with U+FFFC, and
    /// madrid renders that mark as the attachment's guid (`at_<n>_<UUID>`) on
    /// a line of its own. Neither is text the sender wrote.
    static func textWithoutAttachmentPlaceholders(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                line.trimmingCharacters(in: .whitespaces).range(
                    of: #"^at_\d+_[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#,
                    options: .regularExpression
                ) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chat a message belongs to: its identifier, its name (group chats
    /// that have one), and its participants.
    private static func conversation(
        for chatID: Chat.ID,
        in db: iMessage.Database
    ) throws -> [String: Value] {
        var conversation: [String: Value] = [
            "@type": "Conversation",
            "@id": .string(chatID.rawValue),
        ]
        if let chat = try db.fetch(FetchRequest<Chat>(predicate: .id(chatID), limit: 1)).first {
            if let name = chat.displayName, !name.isEmpty {
                conversation["name"] = .string(name)
            }
            conversation["participant"] = .array(
                chat.participants.map { .object(["@id": .string($0.rawValue)]) }
            )
        }
        return conversation
    }

    /// Pages back through time, newest first, until `limit` items match.
    /// Fetching one page of five times the limit and filtering it meant a
    /// search only ever saw the newest few hundred messages, and reactions and
    /// attachments with no text shortened even unfiltered results.
    /// `maxScanned` bounds the work for a term that matches nothing.
    static func newestMatches<Item, ID: Hashable>(
        in range: Range<Date>?,
        limit: Int,
        pageSize: Int = 500,
        maxScanned: Int = 20_000,
        id: (Item) -> ID,
        date: (Item) -> Date,
        matching matches: (Item) -> Bool,
        fetchPage: (Range<Date>, Int) throws -> [Item]
    ) rethrows -> [Item] {
        let lowerBound = range?.lowerBound ?? .distantPast
        var upperBound = range?.upperBound ?? .distantFuture
        var found: [Item] = []
        var seen = Set<ID>()
        var scanned = 0
        while found.count < limit, scanned < maxScanned, lowerBound < upperBound {
            let page = try fetchPage(lowerBound ..< upperBound, pageSize)
            scanned += page.count
            for item in page where seen.insert(id(item)).inserted && matches(item) {
                found.append(item)
                if found.count == limit { return found }
            }
            // A short page is the end of the range. Otherwise continue from
            // the oldest item's second. madrid rejects a bound whose
            // nanoseconds are not an exact integer, which a raw message date
            // can be; a whole second is always exact. Rounding up refetches
            // that second's items, which `seen` skips.
            guard page.count == pageSize, let oldest = page.last else { break }
            upperBound = Date(
                timeIntervalSinceReferenceDate: date(oldest).timeIntervalSinceReferenceDate.rounded(.up)
            )
        }
        return found
    }

    /// madrid drops the participant condition when the handle set is empty,
    /// so participants that match no handle would return every conversation.
    /// Nil means no participants were asked for; a request that matches no
    /// handle is an error, never an unfiltered read.
    static func participantFilter<Handle: Hashable>(
        requested: [String],
        resolved: [Handle]
    ) throws -> Set<Handle>? {
        guard !requested.isEmpty else { return nil }
        guard !resolved.isEmpty else {
            throw ToolInputError(
                "No Messages conversation matches the given participants. "
                    + "Use a phone number or email address as it appears in Messages."
            )
        }
        return Set(resolved)
    }
}

/// A second, read-only connection for the attachment tables, which madrid
/// does not model.
private struct AttachmentReader {
    private let connection: ReadOnlySQLite

    init(path: String, immutable: Bool) throws {
        connection = try ReadOnlySQLite(
            path: path,
            mode: .companion(immutable: immutable, busyTimeoutMilliseconds: 1000)
        )
    }

    /// Attachments keyed by message guid, in chat.db order. Hidden
    /// attachments (Messages' own plug-in payloads) are left out.
    func attachments(ofMessages guids: [String]) throws -> [String: [[String: Value]]] {
        var result: [String: [[String: Value]]] = [:]
        for start in stride(from: 0, to: guids.count, by: 500) {
            let chunk = guids[start ..< min(start + 500, guids.count)]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT m.guid, a.guid, a.filename, a.transfer_name, a.mime_type, a.total_bytes, a.is_sticker
                FROM message m
                JOIN message_attachment_join j ON j.message_id = m.ROWID
                JOIN attachment a ON a.ROWID = j.attachment_id
                WHERE m.guid IN (\(placeholders)) AND a.hide_attachment = 0
                ORDER BY m.ROWID, a.ROWID
                """
            let rows = try connection.rows(sql, chunk.map { .text($0) }) { row -> (String, [String: Value])? in
                guard let messageGuid = row.text(0), let id = row.text(1) else { return nil }
                var attachment: [String: Value] = ["@type": "MediaObject", "@id": .string(id)]
                // The transfer name is what the sender called the file; the
                // stored filename is a path under ~/Library/Messages.
                let name = row.text(3) ?? row.text(2).map { ($0 as NSString).lastPathComponent }
                if let name, !name.isEmpty {
                    attachment["name"] = .string(name)
                }
                if let mimeType = row.text(4), !mimeType.isEmpty {
                    attachment["encodingFormat"] = .string(mimeType)
                }
                attachment["contentSize"] = .int(Int(row.int64(5)))
                if row.bool(6) {
                    attachment["sticker"] = .bool(true)
                }
                return (messageGuid, attachment)
            }
            for (messageGuid, attachment) in rows {
                result[messageGuid, default: []].append(attachment)
            }
        }
        return result
    }
}
