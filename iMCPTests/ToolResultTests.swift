import XCTest
@testable import iMCP

final class ToolResultTests: XCTestCase {
    /// Image bytes have to leave as a binary result. Falling through to the JSON
    /// encoder would ship a photo as a base64 string inside a JSON blob.
    func testToolReturnsBinaryForImageDataValue() async throws {
        let imageData = Data([0x01, 0x02, 0x03])
        let tool = Tool(
            name: "image_tool",
            description: "Returns image data",
            arguments: [],
            annotations: .init(title: "Image Tool", readOnlyHint: true)
        ) { _ in
            Value.data(mimeType: "image/png", imageData)
        }

        let result = try await tool([:])

        guard case .binary(let mimeType, let data) = result else {
            return XCTFail("Expected binary tool result")
        }
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertEqual(data, imageData)
    }

    func testToolEncodesNonBinaryResultsAsJSON() async throws {
        let tool = Tool(
            name: "json_tool",
            description: "Returns JSON",
            arguments: [],
            annotations: .init(title: "JSON Tool", readOnlyHint: true)
        ) { _ in
            ["ok": true]
        }

        let result = try await tool([:])

        guard case .json(let data) = result else {
            return XCTFail("Expected JSON tool result")
        }

        let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
        XCTAssertEqual(decoded, ["ok": true])
    }
}
