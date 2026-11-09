import Combine
@testable import iMCP
import XCTest

/// A pairing code buys one client a trip past the approval dialog, so the two
/// things keeping it honest are single use and a short expiry.
final class PairingCodeIssuerTests: XCTestCase {
    func testIssuedCodeValidatesOnce() async {
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        let firstValidation = await issuer.validate(issued.code, at: Date(timeIntervalSince1970: 1_100))
        let secondValidation = await issuer.validate(issued.code, at: Date(timeIntervalSince1970: 1_200))
        XCTAssertTrue(firstValidation)
        XCTAssertFalse(secondValidation)
    }

    func testExpiredCodeRejected() async {
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        let expiredAt = issued.expiresAt.addingTimeInterval(1)
        let validation = await issuer.validate(issued.code, at: expiredAt)
        XCTAssertFalse(validation)
    }

    func testWrongCodeRejected() async {
        let issuer = PairingCodeIssuer()
        _ = await issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        let validation = await issuer.validate("WRONG12", at: Date(timeIntervalSince1970: 1_100))
        XCTAssertFalse(validation)
    }

    func testCodeIsDiscardedAfterThreeWrongGuesses() async {
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        let now = Date(timeIntervalSince1970: 1_100)
        for _ in 0 ..< PairingCodeIssuer.maxFailedAttempts {
            let wrong = await issuer.validate("WRONG12", at: now)
            XCTAssertFalse(wrong)
        }
        let validation = await issuer.validate(issued.code, at: now)
        XCTAssertFalse(validation)
    }

    /// The Connect window shows the code until told it is gone.
    @MainActor
    func testDiscardIsAnnouncedOnTheThirdWrongGuessOnly() {
        let issuer = PairingCodeIssuer()
        var events: [PairingCodeIssuer.Event] = []
        let subscription = issuer.events.sink { events.append($0) }
        defer { subscription.cancel() }

        let issued = issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        let now = Date(timeIntervalSince1970: 1_100)
        for expected in [0, 0, 1] {
            _ = issuer.validate("WRONG12", at: now)
            XCTAssertEqual(events.count, expected)
        }
        XCTAssertEqual(events, [.exhausted(code: issued.code)])
    }

    /// A used code is announced as used, which is what lets the Connect
    /// window wait to say who it paired.
    @MainActor
    func testRedeemingTheCodeAnnouncesItAsRedeemed() {
        let issuer = PairingCodeIssuer()
        var events: [PairingCodeIssuer.Event] = []
        let subscription = issuer.events.sink { events.append($0) }
        defer { subscription.cancel() }

        let issued = issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(issuer.validate(issued.code, at: Date(timeIntervalSince1970: 1_100)))
        XCTAssertFalse(issuer.validate(issued.code, at: Date(timeIntervalSince1970: 1_200)))

        XCTAssertEqual(events, [.redeemed(code: issued.code)])
    }

    func testCodeSurvivesTwoWrongGuesses() async {
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue(at: Date(timeIntervalSince1970: 1_000))
        let now = Date(timeIntervalSince1970: 1_100)
        for _ in 0 ..< 2 {
            let wrong = await issuer.validate("WRONG12", at: now)
            XCTAssertFalse(wrong)
        }
        let validation = await issuer.validate(issued.code, at: now)
        XCTAssertTrue(validation)
    }
}
