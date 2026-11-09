import Foundation
import XCTest

@testable import iMCP

/// The words every screen shows for the iCloud session, and whether the
/// iCloud row waits for the owner.
final class ICloudStatusTests: XCTestCase {
    func testICloudRowSaysWhoAndHowFresh() {
        let now = Date(timeIntervalSince1970: 100_000)
        let summary = ICloudStatus.summary(
            state: .signedIn(accountName: "user@example.com"),
            lastRenewedAt: now.addingTimeInterval(-240),
            now: now
        )
        XCTAssertEqual(summary.level, .ok)
        XCTAssertEqual(summary.detail, "user@example.com · renewed 4m ago")
    }

    func testICloudRowEscalatesByState() {
        XCTAssertEqual(ICloudStatus.summary(state: .working, lastRenewedAt: nil).level, .attention)
        XCTAssertEqual(
            ICloudStatus.summary(state: .awaitingCode(.trustedDevice), lastRenewedAt: nil).level,
            .attention
        )
        XCTAssertEqual(ICloudStatus.summary(state: .needsReauthentication, lastRenewedAt: nil).level, .problem)
        XCTAssertEqual(ICloudStatus.summary(state: .credentialsUnreadable, lastRenewedAt: nil).level, .problem)
        XCTAssertEqual(ICloudStatus.summary(state: .signedOut, lastRenewedAt: nil).level, .problem)
    }

    func testICloudWordsAreTheApprovedOnes() {
        func detail(_ state: ICloudSession.State) -> String {
            ICloudStatus.summary(state: state, lastRenewedAt: nil).detail
        }
        XCTAssertEqual(detail(.needsReauthentication), "Sign in to iCloud")
        XCTAssertEqual(detail(.signedOut), "Not signed in to iCloud")
        XCTAssertEqual(
            detail(.credentialsUnreadable),
            "Can't read your saved sign-in. Unlock your Mac's keychain"
        )
        XCTAssertEqual(detail(.awaitingCode(.trustedDevice)), "Enter your verification code")
        XCTAssertEqual(detail(.working), "Signing in…")
        XCTAssertEqual(detail(.reconnecting), "Reconnecting · retrying automatically")
    }

    /// A queued restore retry needs nobody: it is not the sign-in row, and it
    /// is not a problem.
    func testAReconnectingSessionIsNotAskedToSignIn() {
        let summary = ICloudStatus.summary(state: .reconnecting, lastRenewedAt: nil)
        XCTAssertEqual(summary.level, .attention)
        XCTAssertFalse(ICloudStatus.needsOwner(state: .reconnecting, pauseReason: nil))
        XCTAssertFalse(ICloudStatus.report(state: .reconnecting, lastRenewedAt: nil).needsOwner)
    }

    func testICloudRowShowsPausedAutomaticRecovery() {
        let repair = ICloudStatus.summary(
            state: .signedIn(accountName: "user@example.com"),
            lastRenewedAt: Date(),
            pauseReason: .accountRepairRequired
        )
        XCTAssertEqual(repair.level, .problem)
        XCTAssertEqual(repair.detail, "Account action required")

        let signedOutRepair = ICloudStatus.summary(
            state: .needsReauthentication,
            lastRenewedAt: nil,
            pauseReason: .accountRepairRequired
        )
        XCTAssertEqual(signedOutRepair.detail, "Account action required")

        let guarded = ICloudStatus.summary(
            state: .signedIn(accountName: "user@example.com"),
            lastRenewedAt: Date(),
            pauseReason: .repeatedAutomaticSignInStopped
        )
        XCTAssertEqual(guarded.level, .problem)
        XCTAssertEqual(guarded.detail, "Automatic sign-in paused")
    }

    private static let pauseReasons: [ICloudSession.PauseReason?] = [
        nil, .accountRepairRequired, .verificationPending, .repeatedAutomaticSignInStopped,
    ]

    private static let states: [ICloudSession.State] = [
        .signedOut, .working, .awaitingCode(.trustedDevice), .signedIn(accountName: "user@example.com"),
        .needsReauthentication, .reconnecting, .credentialsUnreadable,
    ]

    /// A code to type, and a paused recovery, wait for the owner; Settings
    /// moves the row first and calls it not granted, and the menu lists it.
    func testICloudNeedsOwnerForACodeAndForAPausedRecovery() {
        XCTAssertTrue(ICloudStatus.needsOwner(state: .awaitingCode(.trustedDevice), pauseReason: nil))
        XCTAssertTrue(
            ICloudStatus.needsOwner(
                state: .signedIn(accountName: "user@example.com"),
                pauseReason: .verificationPending
            )
        )
        XCTAssertFalse(ICloudStatus.needsOwner(state: .signedIn(accountName: "user@example.com"), pauseReason: nil))
        XCTAssertFalse(ICloudStatus.needsOwner(state: .working, pauseReason: nil))

        let code = ICloudStatus.report(state: .awaitingCode(.trustedDevice), lastRenewedAt: nil)
        XCTAssertEqual(ServicePermissionStatus(code), .notGranted)
        let verifying = ICloudStatus.report(
            state: .signedIn(accountName: "user@example.com"),
            lastRenewedAt: nil,
            pauseReason: .verificationPending
        )
        XCTAssertEqual(ServicePermissionStatus(verifying), .notGranted)
        XCTAssertTrue(verifying.offersSignInAgain)
        XCTAssertEqual(
            ServicePermissionStatus(ICloudStatus.report(state: .working, lastRenewedAt: nil)),
            .checking
        )
        XCTAssertEqual(
            ServicePermissionStatus(
                ICloudStatus.report(state: .signedIn(accountName: "user@example.com"), lastRenewedAt: nil)
            ),
            .granted
        )
    }

    /// The menu lists every row that is not fine, so a row Settings says
    /// needs the owner is always one the menu shows too.
    func testEveryICloudStateThatNeedsTheOwnerIsListedInTheMenu() {
        for state in Self.states {
            for pause in Self.pauseReasons {
                let report = ICloudStatus.report(state: state, lastRenewedAt: nil, pauseReason: pause)
                let status = AppStatus(
                    locationEnabled: true,
                    iCloud: report,
                    clients: ClientsStatus.summary(pairedCount: 1)
                )
                let listed = status.rowsNeedingOwner.contains { $0.subject == .iCloud }
                XCTAssertEqual(
                    report.needsOwner,
                    ServicePermissionStatus(report) == .notGranted,
                    "\(state) \(String(describing: pause))"
                )
                if report.needsOwner {
                    XCTAssertTrue(listed, "\(state) \(String(describing: pause))")
                }
            }
        }
    }

    /// A paused recovery and a held session lead to Settings, where the
    /// account's details are; every other state leads to the sign-in form.
    func testICloudRowLeadsToTheSignInFormOnlyWhenTheFormCanFixIt() {
        let cases: [(ICloudSession.State, ICloudSession.PauseReason?, StatusDestination)] = [
            (.signedOut, nil, .iCloudSignIn),
            (.needsReauthentication, nil, .iCloudSignIn),
            (.signedIn(accountName: "user@example.com"), nil, .settings),
            (.signedIn(accountName: "user@example.com"), .accountRepairRequired, .settings),
            (.needsReauthentication, .verificationPending, .settings),
        ]
        for (state, pause, destination) in cases {
            let report = ICloudStatus.report(state: state, lastRenewedAt: nil, pauseReason: pause)
            XCTAssertEqual(report.destination, destination, "\(state) \(String(describing: pause))")
        }
    }

    /// Settings shows the session's one problem text, the words the tools
    /// and the Location window show too.
    func testICloudNoteIsTheSessionsProblem() {
        let note = ICloudStatus.report(state: .needsReauthentication, lastRenewedAt: nil, problem: "Network down.")
        XCTAssertEqual(note.note, "Last problem: Network down.")
        XCTAssertNil(ICloudStatus.report(state: .signedOut, lastRenewedAt: nil).note)
    }
}
