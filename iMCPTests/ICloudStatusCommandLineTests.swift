import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

final class ICloudStatusCommandLineTests: XCTestCase {
    func testReportNamesTheSnapshotAgeAndCookieExpiryWithoutValues() {
        let now = Date(timeIntervalSince1970: 200_000)
        let credentials = ICloudCredentials(
            accountName: "user@example.com",
            accountCountry: "USA",
            sessionToken: "secret-session",
            trustToken: "secret-trust",
            webAuthToken: "secret-web",
            webAuthUser: "secret-user",
            trustedAt: now.addingTimeInterval(-90_000),
            dsid: "12345",
            webservices: ["findme": URL(string: "https://p42-fmipweb.icloud.com:443")!],
            cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "secret-web",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: now.addingTimeInterval(-60)
                ),
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-USER",
                    value: "secret-user",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                ),
            ],
            updatedAt: now.addingTimeInterval(-600),
            password: "secret-password",
            lastAutomaticReauthenticationAt: now.addingTimeInterval(-300)
        )

        let report = ICloudStatusCommandLine.report(.found(credentials), now: now)
        XCTAssertTrue(report.contains("saved password: present"), report)

        XCTAssertTrue(report.contains("stored: yes"))
        XCTAssertTrue(report.contains("(1d 1h ago)"), report)
        XCTAssertTrue(report.contains("snapshot written: ") && report.contains("(10m ago)"), report)
        XCTAssertTrue(report.contains("X-APPLE-WEBAUTH-TOKEN: expired"), report)
        XCTAssertTrue(report.contains("X-APPLE-WEBAUTH-USER: session cookie"), report)
        XCTAssertTrue(report.contains("Find My endpoint present"), report)
        XCTAssertTrue(report.contains("automatic browser sign-in last tried:"), report)
        XCTAssertTrue(report.contains("(5m ago)"), report)
        for secret in ["secret", "user@example.com", "12345"] {
            XCTAssertFalse(report.contains(secret), "report leaked \(secret)")
        }
    }

    /// The trust age is a local estimate, reported for diagnosis only.
    func testReportSaysWhetherTheTrustIsOlderThanItsEstimatedLifetime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func trustLine(signedInDaysAgo days: Double) -> String? {
            let credentials = ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "session",
                trustedAt: now.addingTimeInterval(-days * 86400)
            )
            return ICloudStatusCommandLine.report(.found(credentials), now: now)
                .split(separator: "\n")
                .first { $0.contains("trust age:") }
                .map(String.init)
        }

        XCTAssertEqual(
            trustLine(signedInDaysAgo: 29)?.hasPrefix("  trust age: within 30 days (Apple decides validity)"),
            true
        )
        XCTAssertEqual(
            trustLine(signedInDaysAgo: 31)?.hasPrefix("  trust age: older than 30 days (Apple decides validity)"),
            true
        )
    }

    /// A recovery flag the report does not name still shows up, by name and
    /// without anything but its yes or no.
    func testReportListsEveryRecoveryFlagOfTheRecord() {
        let credentials = ICloudCredentials(
            accountName: "user@example.com",
            accountCountry: "USA",
            sessionToken: "secret-session",
            trustToken: nil,
            webAuthToken: nil,
            webAuthUser: nil,
            trustedAt: Date(),
            accountRepairPending: true
        )
        let report = ICloudStatusCommandLine.report(.found(credentials))
        XCTAssertTrue(report.contains("  accountRepairPending: yes"), report)
        XCTAssertFalse(report.contains("secret"), report)
        XCTAssertFalse(report.contains("user@example.com"), report)

        var cleared = credentials
        cleared.accountRepairPending = nil
        XCTAssertTrue(
            ICloudStatusCommandLine.report(.found(cleared)).contains("  accountRepairPending: absent")
        )
    }

    func testReportDistinguishesMissingFromUnreadable() {
        XCTAssertTrue(ICloudStatusCommandLine.report(.missing).contains("stored: no"))
        XCTAssertTrue(ICloudStatusCommandLine.report(.unavailable).contains("stored: unreadable"))
    }
}
