import Foundation
import OSLog
import XCTest

@testable import iMCP

final class BookmarkedSQLiteStoreTests: XCTestCase {
    /// Every name the picker shows comes from the path; the bookmark keys are
    /// persisted and must never move.
    func testBookmarkedDatabasesDeriveTheirNamesAndKeepTheirKeys() {
        XCTAssertEqual(BookmarkedDatabase.callHistory.expectedName, "CallHistory.storedata")
        XCTAssertEqual(BookmarkedDatabase.notifications.expectedName, "db2")
        XCTAssertEqual(BookmarkedDatabase.notifications.fileName, "db")
        XCTAssertEqual(
            [
                BookmarkedDatabase.callHistory, .knowledge, .messages, .notifications,
            ].map(\.bookmarkKey),
            [
                "me.mattt.iMCP.callHistoryDatabaseBookmark",
                "me.mattt.iMCP.knowledgeDatabaseBookmark",
                "me.mattt.iMCP.messagesDatabaseBookmark",
                "me.mattt.iMCP.notificationsDatabaseBookmark",
            ]
        )
    }

    /// Tool handlers no longer open the database dialog, so this text is what
    /// a client sees when iMCP has no access.
    func testMissingDatabaseAccessSaysWhatToDo() {
        let database = BookmarkedDatabase(
            path: "/nonexistent/iMCP/db",
            bookmarkKey: "unusedBookmark",
            selection: .directory,
            displayName: "Notifications",
            purpose: "notifications"
        )
        let store = BookmarkedSQLiteStore(database, log: Logger.service("test"), defaults: makeTemporaryDefaults())
        XCTAssertThrowsError(try store.withAccess { _ in }) { error in
            let message = sanitizedToolErrorMessage(for: error)
            XCTAssertTrue(message.contains("Full Disk Access"), message)
            XCTAssertTrue(
                message.hasSuffix(
                    "Or switch the service off and on in the iMCP menu to choose the Notifications database folder."
                ),
                message
            )
        }
    }
}
