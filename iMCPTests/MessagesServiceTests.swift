import MapKit
import XCTest

@testable import iMCP

/// Participants that match no handle used to fall through to an unfiltered
/// read of every conversation, because madrid ignores an empty handle set.
final class MessagesParticipantFilterTests: XCTestCase {
    func testUnmatchedParticipantsAreAnErrorNotAnUnfilteredRead() {
        XCTAssertThrowsError(
            try MessageService.participantFilter(requested: ["+15550000000"], resolved: [String]())
        ) { error in
            XCTAssertTrue(error is ToolInputError)
            XCTAssertTrue(sanitizedToolErrorMessage(for: error).contains("No Messages conversation matches"))
        }
    }

    func testNoParticipantsMeansNoFilter() throws {
        XCTAssertNil(try MessageService.participantFilter(requested: [], resolved: [String]()))
    }

    func testMatchedParticipantsFilterToTheirHandles() throws {
        let filter = try MessageService.participantFilter(
            requested: ["a@example.com"],
            resolved: ["a@example.com", "a@example.com"]
        )
        XCTAssertEqual(filter, ["a@example.com"])
    }
}

/// The filters and clean-up `messages_fetch` applies around madrid.
final class MessagesFetchArgumentTests: XCTestCase {
    func testEitherDateBoundMayBeGivenAlone() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertNil(MessageService.dateRange(start: nil, end: nil))
        XCTAssertEqual(MessageService.dateRange(start: date, end: nil)?.lowerBound, date)
        XCTAssertEqual(MessageService.dateRange(start: nil, end: date)?.upperBound, date)
    }

    func testOpenEndsStayWithinWhatTheDatabaseCanHold() {
        let range = MessageService.representable(Date.distantPast ..< Date.distantFuture)
        // chat.db dates are Int64 nanoseconds; madrid throws on anything wider.
        XCTAssertNotNil(Int64(exactly: range.lowerBound.timeIntervalSinceReferenceDate * 1_000_000_000))
        XCTAssertNotNil(Int64(exactly: range.upperBound.timeIntervalSinceReferenceDate * 1_000_000_000))
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    func testAttachmentPlaceholdersAreNotMessageText() {
        let guid = "at_0_1A2B3C4D-1111-2222-3333-1A2B3C4D5E6F"
        XCTAssertEqual(MessageService.textWithoutAttachmentPlaceholders("\u{FFFC}"), "")
        XCTAssertEqual(MessageService.textWithoutAttachmentPlaceholders(guid), "")
        XCTAssertEqual(
            MessageService.textWithoutAttachmentPlaceholders("look at this\n\(guid)"),
            "look at this"
        )
        XCTAssertEqual(MessageService.textWithoutAttachmentPlaceholders("at_0_home"), "at_0_home")
    }

    func testMalformedChatIDIsAnErrorNotAnUnfilteredRead() throws {
        XCTAssertNil(try MessageService.chatID([:]))
        XCTAssertEqual(
            try MessageService.chatID(["chatId": "iMessage;+;chat123"])?.rawValue,
            "iMessage;+;chat123"
        )
        for malformed: Value in ["", "  ", 7] {
            XCTAssertThrowsError(try MessageService.chatID(["chatId": malformed])) { error in
                XCTAssertEqual(
                    (error as? ToolInputError)?.message,
                    "Invalid chatId. Use the @id of a message's isPartOf."
                )
            }
        }
    }
}

/// messages_fetch used to fetch one page of five times the limit and filter
/// it, so a search only ever saw the newest few hundred messages.
final class MessagesNewestMatchesTests: XCTestCase {
    private struct Row {
        let id: Int
        let date: Date
        let text: String
    }

    /// One row per minute, newest first, like the Messages query.
    private let rows: [Row] = (0 ..< 3_000).map { (minute: Int) -> Row in
        let seconds: Double = 800_000_000.123_456_789 - Double(minute) * 60
        var text = "hello"
        if minute % 3 == 0 { text = "" }
        if minute == 2_900 { text = "the dentist moved" }
        return Row(id: minute, date: Date(timeIntervalSinceReferenceDate: seconds), text: text)
    }

    private func page(_ range: Range<Date>, _ size: Int) -> [Row] {
        Array(rows.filter { range.contains($0.date) }.prefix(size))
    }

    func testSearchReachesMessagesBeyondTheFirstPage() {
        let found = MessageService.newestMatches(
            in: nil,
            limit: 30,
            pageSize: 100,
            id: \.id,
            date: \.date,
            matching: { $0.text.localizedCaseInsensitiveContains("dentist") },
            fetchPage: page
        )
        XCTAssertEqual(found.map(\.id), [2_900])
    }

    func testEmptyTextDoesNotShortenResultsAndNothingRepeats() {
        let found = MessageService.newestMatches(
            in: nil,
            limit: 250,
            pageSize: 100,
            id: \.id,
            date: \.date,
            matching: { !$0.text.isEmpty },
            fetchPage: page
        )
        XCTAssertEqual(found.count, 250)
        XCTAssertEqual(Set(found.map(\.id)).count, 250)
        XCTAssertEqual(found.map(\.id), found.map(\.id).sorted())
    }

    func testScanningStopsAtTheBudget() {
        var fetched = 0
        let found = MessageService.newestMatches(
            in: nil,
            limit: 30,
            pageSize: 100,
            maxScanned: 500,
            id: \.id,
            date: \.date,
            matching: { $0.text == "no such text" },
            fetchPage: { range, size in
                let rows = self.page(range, size)
                fetched += rows.count
                return rows
            }
        )
        XCTAssertTrue(found.isEmpty)
        XCTAssertLessThanOrEqual(fetched, 500)
    }
}
