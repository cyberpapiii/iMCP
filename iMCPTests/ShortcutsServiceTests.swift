import XCTest

@testable import iMCP

final class ShortcutsServiceTests: XCTestCase {
    func testOutputTextKeepsNonUTF8Bytes() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "shortcut-output-\(UUID().uuidString).txt")
        try Data([0x68, 0xFF, 0x69]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(shortcutOutputText(at: url), "h\u{FFFD}i")
    }

    func testOutputTextIsNilWhenFileIsMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "shortcut-output-\(UUID().uuidString).txt")
        XCTAssertNil(shortcutOutputText(at: url))
    }

    /// A pipe holds about 64 KB. Without a reader the child blocks on its
    /// write and never exits, so the child exiting is the regression test.
    func testDrainLetsAChildWriteMoreThanAPipeHolds() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "head -c 300000 /dev/zero >&2"]
        let pipe = Pipe()
        process.standardError = pipe
        _ = drain(pipe)
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        let exited = expectation(description: "child exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(process.terminationStatus, 0)
    }
}
