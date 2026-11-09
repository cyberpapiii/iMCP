import XCTest

@testable import iMCP

final class NotesServiceTests: XCTestCase {
    func testEscapePassesPlainStringsThrough() {
        XCTAssertEqual(notesEscapeAppleScriptString("groceries"), "groceries")
    }

    func testEscapeQuotesAndBackslashes() {
        // Tool arguments are embedded in double-quoted AppleScript literals,
        // so quotes and backslashes must be escaped to prevent injection.
        XCTAssertEqual(
            notesEscapeAppleScriptString(#"say "hi" \ bye"#),
            #"say \"hi\" \\ bye"#
        )
    }

    func testEscapeBlocksScriptInjection() {
        // Every quote must come out escaped, so the payload cannot terminate
        // the surrounding AppleScript string literal.
        let malicious = #"" & (do shell script "whoami") & ""#
        XCTAssertEqual(
            notesEscapeAppleScriptString(malicious),
            #"\" & (do shell script \"whoami\") & \""#
        )
    }

    func testAutomationProbeAcceptsGrantedStatus() {
        XCTAssertTrue(notesAutomationIsActivated(status: noErr, previouslyActivated: false))
    }

    func testAutomationProbeUsesProvenGrantWhenNotesIsNotRunning() {
        XCTAssertFalse(
            notesAutomationIsActivated(
                status: OSStatus(procNotFound),
                previouslyActivated: false
            )
        )
        XCTAssertTrue(
            notesAutomationIsActivated(
                status: OSStatus(procNotFound),
                previouslyActivated: true
            )
        )
    }

    func testAutomationProbeRejectsDeniedStatus() {
        XCTAssertFalse(
            notesAutomationIsActivated(
                status: OSStatus(errAEEventNotPermitted),
                previouslyActivated: true
            )
        )
    }
}
