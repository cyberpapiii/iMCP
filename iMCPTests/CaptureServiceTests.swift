import XCTest
@testable import iMCP

final class CameraPhotoCaptureGateTests: XCTestCase {
    /// Two MCP clients can call the capture tool at the same moment. The second
    /// must be rejected outright rather than queued behind the camera.
    func testSecondConcurrentCaptureIsRejected() async throws {
        let gate = CameraPhotoCaptureGate()
        let firstStarted = expectation(description: "first capture started")
        let releaseFirst = expectation(description: "release first capture")

        let firstTask = Task {
            try await gate.perform {
                firstStarted.fulfill()
                await fulfillment(of: [releaseFirst], timeout: 1)
                return true
            }
        }

        await fulfillment(of: [firstStarted], timeout: 1)

        do {
            _ = try await gate.perform {
                XCTFail("Second capture should not run while first is in flight")
                return false
            }
            XCTFail("Expected a concurrent-capture rejection")
        } catch {
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Camera capture already in progress")
        }

        releaseFirst.fulfill()

        let firstResult = try await firstTask.value
        XCTAssertTrue(firstResult)
    }
}

final class CaptureArgumentTests: XCTestCase {
    func testCaptureIdentifierNeverTraps() throws {
        let displayID = captureIdentifier("displayId", description: "")
        XCTAssertNil(try displayID([:]))
        XCTAssertNil(try displayID(["displayId": .null]))
        XCTAssertEqual(try displayID(["displayId": .int(7)]), 7)
        XCTAssertEqual(try displayID(["displayId": .double(7.0)]), 7)
        for value: Value in [.int(-1), .int(5_000_000_000), .double(1.5), .string("7")] {
            XCTAssertThrowsError(try displayID(["displayId": value])) { error in
                XCTAssertTrue(error is ToolInputError)
            }
        }
    }
}
