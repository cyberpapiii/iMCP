import Foundation
import XCTest

@testable import iMCP

/// Ownership, permissions, and symlink checks are load-bearing: a writable
/// endpoint file redirects the CLI's MCP traffic.
final class ListenerEndpointFileTests: XCTestCase {
    func testRoundTripPortAndPidForLiveProcess() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)

        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { $0 == 4242 }, isTrustedProcess: { _ in true }),
            .usable(ListenerEndpointFile.Contents(port: 57744, pid: 4242))
        )
    }

    func testRemoveDeletesFileAndToleratesAbsence() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)
        ListenerEndpointFile.remove(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ListenerEndpointFile.fileURL(in: dir).path))

        ListenerEndpointFile.remove(in: dir)
    }

    func testDefaultLivenessCheckAcceptsOwnPidAndRejectsNonsense() {
        XCTAssertTrue(
            ListenerEndpointFile.defaultIsProcessAlive(ProcessInfo.processInfo.processIdentifier)
        )
        XCTAssertFalse(ListenerEndpointFile.defaultIsProcessAlive(-1))
        XCTAssertFalse(ListenerEndpointFile.defaultIsProcessAlive(0))
    }

    func testWriteSetsOwnerOnlyPermissionsOnFileAndDirectory() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)

        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: ListenerEndpointFile.fileURL(in: dir).path
        )
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)

        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)
    }

    func testWriteTightensPreExistingLooselyPermissionedDirectory() throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)

        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.uint16Value, 0o700)
    }

    func testInspectNamesMissingFile() throws {
        let dir = try makeTemporaryDirectory()

        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { _ in true }, isTrustedProcess: { _ in true }),
            .missing
        )
    }

    func testInspectNamesDeadProcess() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)

        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { _ in false }, isTrustedProcess: { _ in true }),
            .processDead(pid: 4242)
        )
    }

    func testInspectNamesUntrustedProcess() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)

        XCTAssertEqual(
            ListenerEndpointFile.inspect(
                in: dir,
                isProcessAlive: { _ in true },
                isTrustedProcess: { _ in false }
            ),
            .processUntrusted(pid: 4242)
        )
    }

    func testInspectNamesMalformedAndInvalidPort() throws {
        let dir = try makeTemporaryDirectory()

        try Data("not json".utf8).write(to: ListenerEndpointFile.fileURL(in: dir))
        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { _ in true }, isTrustedProcess: { _ in true }),
            .malformed
        )

        try ListenerEndpointFile.write(port: 0, pid: 4242, in: dir)
        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { _ in true }, isTrustedProcess: { _ in true }),
            .invalidPort
        )
    }

    func testInspectNamesUntrustedFileShape() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)
        XCTAssertEqual(
            ListenerEndpointFile.inspect(
                in: dir,
                isProcessAlive: { _ in true },
                isTrustedProcess: { _ in true },
                currentUserID: getuid() + 1
            ),
            .untrustedOwner
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o620],
            ofItemAtPath: ListenerEndpointFile.fileURL(in: dir).path
        )
        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { _ in true }, isTrustedProcess: { _ in true }),
            .loosePermissions
        )

        let targetDir = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: targetDir)
        try FileManager.default.removeItem(at: ListenerEndpointFile.fileURL(in: dir))
        try FileManager.default.createSymbolicLink(
            at: ListenerEndpointFile.fileURL(in: dir),
            withDestinationURL: ListenerEndpointFile.fileURL(in: targetDir)
        )
        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { _ in true }, isTrustedProcess: { _ in true }),
            .notRegularFile
        )
    }

    func testWriteRoundTripsEnabledServices() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(
            port: 57744,
            pid: 4242,
            enabledServices: ["Messages", "Utilities"],
            in: dir
        )
        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { $0 == 4242 }, isTrustedProcess: { _ in true }),
            .usable(ListenerEndpointFile.Contents(port: 57744, pid: 4242, enabledServices: ["Messages", "Utilities"]))
        )
    }

    func testLegacyFileOmitsEnabledServices() throws {
        let dir = try makeTemporaryDirectory()

        try ListenerEndpointFile.write(port: 57744, pid: 4242, in: dir)
        let data = try Data(contentsOf: ListenerEndpointFile.fileURL(in: dir))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["enabledServices"])

        XCTAssertEqual(
            ListenerEndpointFile.inspect(in: dir, isProcessAlive: { $0 == 4242 }, isTrustedProcess: { _ in true }),
            .usable(ListenerEndpointFile.Contents(port: 57744, pid: 4242, enabledServices: nil))
        )
    }

    func testInvalidPidsAreNotSignedAsIMCP() {
        XCTAssertFalse(AppSigningTrust.isSignedIMCPProcess(0))
        XCTAssertFalse(AppSigningTrust.isSignedIMCPProcess(-1))
    }

    /// iMCPTests is hosted by the app, so the current pid must verify as iMCP.
    /// Debug stays green via the ad-hoc exception; omit that and
    /// this assertion goes red on the `CODE_SIGN_IDENTITY = "-"` host.
    func testAppTestHostIsSignedAsIMCP() {
        XCTAssertTrue(
            AppSigningTrust.isSignedIMCPProcess(ProcessInfo.processInfo.processIdentifier)
        )
    }

    /// A spoofed-plist pid cannot be constructed in-process: this suite runs
    /// inside the real iMCP host. The Info.plist `CFBundleIdentifier` fallback
    /// is gone, so the check cannot succeed on plist identity alone.
    func testReleaseRequirementPinsTeamIDNotPlistIdentifier() {
        let requirement = AppSigningTrust.designatedRequirement(forTeam: "TTY35UM57S")
        XCTAssertTrue(requirement.contains("TTY35UM57S"))
        XCTAssertTrue(requirement.contains(#"identifier "co.dododo.iMCP""#))
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertFalse(requirement.contains("CFBundleIdentifier"))
        XCTAssertFalse(requirement.contains("kSecCodeInfoIdentifier"))
    }

}
