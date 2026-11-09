import XCTest

@testable import iMCP

/// What the sign-in window says at each step.
@MainActor
final class ICloudSignInScreenTests: XCTestCase {
    func testSignInKeepsTheStepOnShowWhileItWorks() {
        let code = ICloudSignInScreen.Step.awaitingCode(.trustedDevice)
        XCTAssertEqual(ICloudSignInScreen.step(previous: .signedOut, current: .awaitingCode(.trustedDevice)), code)
        XCTAssertEqual(ICloudSignInScreen.step(previous: code, current: .working), code)
        XCTAssertEqual(
            ICloudSignInScreen.step(previous: code, current: .signedIn(accountName: "user@example.com")),
            .signedIn(accountName: "user@example.com")
        )
        XCTAssertEqual(ICloudSignInScreen.step(previous: .signedOut, current: .reconnecting), .reconnecting)
        XCTAssertEqual(ICloudSignInScreen.title(for: code), "Enter your verification code")
    }

    func testSignInButtonSaysWhatIsHappening() {
        XCTAssertEqual(ICloudSignInScreen.primary(for: .signedOut).idle, "Sign In")
        XCTAssertEqual(ICloudSignInScreen.primary(for: .needsReauthentication).working, "Signing In…")
        XCTAssertEqual(ICloudSignInScreen.primary(for: .reconnecting).idle, "Sign In")
        XCTAssertEqual(ICloudSignInScreen.primary(for: .awaitingCode(.trustedDevice)).idle, "Verify")
        XCTAssertEqual(ICloudSignInScreen.primary(for: .awaitingCode(.trustedDevice)).working, "Verifying…")
        XCTAssertEqual(ICloudSignInScreen.primary(for: .credentialsUnreadable).working, "Checking…")
        XCTAssertEqual(ICloudSignInScreen.primary(for: .signedIn(accountName: "user@example.com")).idle, "Done")
    }

    /// A queued restore retry is not an expired session.
    func testAReconnectingSessionIsNotCalledExpired() {
        let explanation = ICloudSignInScreen.explanation(for: .reconnecting)
        XCTAssertFalse(explanation.contains("expired"), explanation)
        XCTAssertTrue(explanation.contains("trying again"), explanation)
    }

    func testSignInFailureSaysWhatToDoNext() {
        XCTAssertEqual(
            ICloudSignInScreen.failureText(.auth(.invalidCredentials)),
            "Apple rejected that Apple ID and password. What you typed is still here: check both and try again."
        )
        XCTAssertEqual(
            ICloudSignInScreen.failureText(.auth(.twoFactorCodeRejected)),
            "Apple rejected that verification code. Check the code and try again, or start over to get a new one."
        )
        XCTAssertEqual(
            ICloudSignInScreen.failureText(.auth(.appleRejectedRequest(status: 503))),
            "iCloud rejected the request (HTTP 503). Try again in a few minutes."
        )
        XCTAssertEqual(
            ICloudSignInScreen.failureText(.unreachable),
            "Could not reach iCloud. Check your connection and try again."
        )
    }

    func testSignInWindowTitleUsesTheSameWords() {
        XCTAssertEqual(ICloudSignInScreen.title(for: .needsReauthentication), "Sign in to iCloud")
        XCTAssertEqual(ICloudSignInScreen.title(for: .signedOut), "Sign in to iCloud")
        XCTAssertEqual(ICloudSignInScreen.title(for: .reconnecting), "Reconnecting to iCloud")
        XCTAssertEqual(
            ICloudSignInScreen.title(for: .awaitingCode(.trustedDevice)),
            "Enter your verification code"
        )
        XCTAssertEqual(
            ICloudSignInScreen.title(for: .credentialsUnreadable),
            "Can't read your saved sign-in"
        )
        XCTAssertEqual(
            ICloudSignInScreen.title(for: .signedIn(accountName: "user@example.com")),
            "Signed in to iCloud"
        )
    }
}
