import Foundation
import XCTest

@testable import iMCP

final class ErrorTypeNameTests: XCTestCase {
    func testANetworkFailureHasOneNameHoweverFoundationBridgedIt() {
        let bridged = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        XCTAssertEqual(errorTypeName(for: bridged), "URLError")
        XCTAssertEqual(errorTypeName(for: URLError(.timedOut)), "URLError")
        XCTAssertEqual(errorTypeName(for: NSError(domain: "x", code: 1)), "NSError")
        XCTAssertEqual(errorTypeName(for: ToolFailure("Display not found")), "ToolFailure")
    }
}
