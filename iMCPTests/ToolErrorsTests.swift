import Foundation
import XCTest

@testable import iMCP

/// What crosses the trust boundary to a client when a tool fails.
final class ToolErrorsTests: XCTestCase {
    /// Tool errors travel back to the MCP client and end up in a model's
    /// context. Raw `NSError` text carries home directory paths and database
    /// filenames, which is more than the client asked for.
    func testSanitizedMessageOmitsPathsAndErrorDomain() {
        let error = NSError(
            domain: "me.mattt.iMCP.SQLiteError",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "unable to open database file /Users/test/secret/chat.db",
                NSFilePathErrorKey: "/Users/test/secret/chat.db",
            ]
        )

        let message = sanitizedToolErrorMessage(for: error)

        XCTAssertFalse(message.contains("chat.db"))
        XCTAssertFalse(message.contains("/Users/"))
        XCTAssertFalse(message.contains("me.mattt.iMCP.SQLiteError"))
        XCTAssertFalse(message.isEmpty)
    }

    func testSanitizedMessageIsStableAcrossErrors() {
        struct OtherError: Error {}
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: OtherError()),
            sanitizedToolErrorMessage(for: NSError(domain: "x", code: 1))
        )
    }

    /// An argument-level failure is the one kind of error the caller can fix
    /// on its own, so the text has to survive the sanitizer.
    func testSanitizedMessagePassesThroughToolInputErrors() {
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: ToolInputError("Search query is required")),
            "Search query is required"
        )
        XCTAssertNotEqual(
            sanitizedToolErrorMessage(for: ToolInputError("Search query is required")),
            sanitizedToolErrorMessage(for: NSError(domain: "x", code: 1))
        )
    }

    func testAuthoredServiceErrorsAreNotMasked() {
        XCTAssertThrowsError(
            try ToolArgument<NotificationSourceSelection>.choice("source", default: .all)(["source": "watch"])
        ) {
            XCTAssertEqual(sanitizedToolErrorMessage(for: $0), "Invalid source. Expected one of: all, mac, iphone.")
        }
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: BrowserHistoryService.unreadable),
            "No Safari, Chrome, or Arc history is readable. Allow iMCP in System Settings > "
                + "Privacy & Security > Full Disk Access."
        )
    }

    /// Choosing the database file happens in the menu, never in a tool call.
    func testDatabaseSelectionErrorsStayInTheLog() {
        XCTAssertEqual(
            sanitizedToolErrorMessage(
                for: BookmarkedSQLiteStore.SelectionError.userDeclinedAccess("the messages database")
            ),
            sanitizedToolErrorMessage(for: NSError(domain: "x", code: 1))
        )
    }

    func testToolFailureReachesTheCaller() {
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: ToolFailure("Display not found")),
            "Display not found"
        )
    }

    func testFallbackReplacesOnlyTheGenericText() {
        let hidden = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "/Users/test/chat.db"])
        XCTAssertEqual(sanitizedToolErrorMessage(for: hidden, fallback: "Search failed."), "Search failed.")
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: ToolFailure("Display not found"), fallback: "Search failed."),
            "Display not found"
        )
    }

}
