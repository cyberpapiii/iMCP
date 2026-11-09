import Foundation
import XCTest

@testable import iMCP

final class DoctorFactsCommandLineTests: XCTestCase {
    func testReportListsEveryKeychainServiceOnceAndThePathsScriptsRead() {
        let lines = DoctorFactsCommandLine.report().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "configuration=debug")
        let prefix = "keychain-service="
        let services = lines.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        XCTAssertEqual(services, DoctorFactsCommandLine.keychainServices)
        XCTAssertEqual(Set(services).count, services.count)
        XCTAssertTrue(lines.contains("bundle-id=\(WireContract.appBundleIdentifier)"))
        XCTAssertTrue(lines.contains("app-support-dir=\(WireContract.appSupportDirectory().path)"))
        XCTAssertTrue(lines.contains("endpoint-file=\(ListenerEndpointFile.fileURL().path)"))
    }

    /// `doctor.sh` checks only the services listed, so a Keychain service
    /// named anywhere in the app must be one of them. The private key tag is
    /// a key, not a generic password, and the plist names the agent.
    func testEveryKeychainServiceTheAppNamesIsListed() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        let notServices: Set<String> = [
            "co.dododo.iMCP.always-on.plist",
            "co.dododo.iMCP.find-my-people-bootstrap-rsa",
        ]
        let literal = try NSRegularExpression(pattern: #""(co\.dododo\.iMCP\.[^"]+)""#)
        var named: Set<String> = []
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in literal.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                named.insert(String(source[Range(match.range(at: 1), in: source)!]))
            }
        }
        XCTAssertFalse(named.isEmpty, "the scan found no sources at \(app.path)")
        XCTAssertEqual(named.subtracting(notServices).subtracting(DoctorFactsCommandLine.keychainServices), [])
    }
}
