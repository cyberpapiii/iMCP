import XCTest

@testable import iMCP

final class AlwaysOnCommandLineTests: XCTestCase {
    func testOrdinaryLaunchArgumentsAskForNothing() {
        XCTAssertNil(AlwaysOnCommandLine.request(from: ["/Applications/iMCP.app/Contents/MacOS/iMCP"]))
        XCTAssertNil(AlwaysOnCommandLine.request(from: ["iMCP", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testFlagAcceptsSeparateAndJoinedValues() {
        XCTAssertEqual(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on", "on"]), .enable)
        XCTAssertEqual(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on=off"]), .disable)
        XCTAssertEqual(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on", "TRUE"]), .enable)
        XCTAssertEqual(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on=0"]), .disable)
    }

    func testUnknownOrMissingValueIsNotARequest() {
        XCTAssertNil(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on"]))
        XCTAssertNil(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on", "maybe"]))
        XCTAssertNil(AlwaysOnCommandLine.request(from: ["iMCP", "--always-on="]))
    }

    func testLastValueWins() {
        XCTAssertEqual(
            AlwaysOnCommandLine.request(from: ["iMCP", "--always-on=on", "--always-on", "off"]),
            .disable
        )
    }
}
