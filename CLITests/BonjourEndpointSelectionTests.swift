import XCTest

/// The CLI picks its endpoint by advertised name. Matching too loosely points
/// the proxy at some other `_mcp._tcp` advertiser, and matching two records at
/// once makes the choice arbitrary, so both cases have to throw.
final class BonjourEndpointSelectionTests: XCTestCase {
    func testSelectsSingleIMCPEndpoint() throws {
        let description = "iMCP._mcp._tcp.local."
        XCTAssertEqual(try selectUniqueIMCPEndpointDescription(from: [description]), description)
    }

    /// Regression for d53b9a1: hostname-only Bonjour advertisements must not match.
    func testRejectsHostnameOnlyAdvertisement() {
        XCTAssertThrowsError(try selectUniqueIMCPEndpointDescription(from: ["Example-MacBook-Pro._mcp._tcp.local."])) {
            error in
            XCTAssertEqual(error as? BonjourEndpointSelectionError, .noMatch)
        }
    }

    func testRejectsEmptySet() {
        XCTAssertThrowsError(try selectUniqueIMCPEndpointDescription(from: [])) { error in
            XCTAssertEqual(error as? BonjourEndpointSelectionError, .noMatch)
        }
    }

    func testRejectsSubstringImpostors() {
        XCTAssertThrowsError(
            try selectUniqueIMCPEndpointDescription(from: ["iMCP-2._mcp._tcp.local."])
        ) { error in
            XCTAssertEqual(error as? BonjourEndpointSelectionError, .noMatch)
        }
        XCTAssertThrowsError(
            try selectUniqueIMCPEndpointDescription(from: ["NotiMCP._mcp._tcp.local."])
        ) { error in
            XCTAssertEqual(error as? BonjourEndpointSelectionError, .noMatch)
        }
    }

    func testRejectsMultipleExactIMCPCandidates() {
        let descriptions = [
            "iMCP._mcp._tcp.local.",
            "iMCP._mcp._tcp.local.",
        ]
        XCTAssertThrowsError(try selectUniqueIMCPEndpointDescription(from: descriptions)) { error in
            XCTAssertEqual(error as? BonjourEndpointSelectionError, .ambiguous(count: 2))
        }
    }

    /// A relaunch while the old record is still being withdrawn advertises as
    /// `iMCP (2)`. Rejecting that left the CLI with nothing to connect to.
    func testSelectsConflictRenamedInstance() throws {
        let renamed = "iMCP\\032(2)._mcp._tcp.local."
        XCTAssertEqual(try selectUniqueIMCPEndpointDescription(from: [renamed]), renamed)

        let unescaped = "iMCP (3)._mcp._tcp.local."
        XCTAssertEqual(try selectUniqueIMCPEndpointDescription(from: [unescaped]), unescaped)
    }

    /// The plain record is the one the system considers current; a rename means
    /// something else already holds that name.
    func testPrefersUnrenamedInstanceOverConflictRename() throws {
        let plain = "iMCP._mcp._tcp.local."
        let selected = try selectUniqueIMCPEndpointDescription(from: [
            "iMCP\\032(2)._mcp._tcp.local.",
            plain,
        ])
        XCTAssertEqual(selected, plain)
    }

    func testRejectsMultipleConflictRenamedInstances() {
        let descriptions = [
            "iMCP\\032(2)._mcp._tcp.local.",
            "iMCP\\032(3)._mcp._tcp.local.",
        ]
        XCTAssertThrowsError(try selectUniqueIMCPEndpointDescription(from: descriptions)) { error in
            XCTAssertEqual(error as? BonjourEndpointSelectionError, .ambiguous(count: 2))
        }
    }

    func testRejectsMalformedConflictSuffix() {
        for description in [
            "iMCP\\032()._mcp._tcp.local.",
            "iMCP\\032(0)._mcp._tcp.local.",
            "iMCP\\032(two)._mcp._tcp.local.",
            "iMCP\\032(2._mcp._tcp.local.",
        ] {
            XCTAssertThrowsError(
                try selectUniqueIMCPEndpointDescription(from: [description]),
                description
            ) { error in
                XCTAssertEqual(error as? BonjourEndpointSelectionError, .noMatch, description)
            }
        }
    }

    func testSelectsIMCPAmongMixedCandidates() throws {
        let imcpDescription = "iMCP._mcp._tcp.local."
        let selected = try selectUniqueIMCPEndpointDescription(from: [
            "Example-MacBook-Pro._mcp._tcp.local.",
            imcpDescription,
        ])
        XCTAssertEqual(selected, imcpDescription)
    }

    /// A browse result that holds only another MCP server's record, or two
    /// of ours while one is withdrawn, keeps discovery browsing; it used to
    /// end the attempt and cost a 5 s rediscover.
    func testABrowseResultWithoutOneIMCPRecordKeepsBrowsing() {
        XCTAssertEqual(bonjourBrowseStep(for: ["Example-MacBook-Pro._mcp._tcp.local."]), .keepBrowsing(.noMatch))
        XCTAssertEqual(
            bonjourBrowseStep(for: ["iMCP (2)._mcp._tcp.local.", "iMCP (3)._mcp._tcp.local."]),
            .keepBrowsing(.ambiguous(count: 2))
        )
        XCTAssertEqual(
            bonjourBrowseStep(for: ["Example-MacBook-Pro._mcp._tcp.local.", "iMCP._mcp._tcp.local."]),
            .connect(endpointDescription: "iMCP._mcp._tcp.local.")
        )
    }
}
