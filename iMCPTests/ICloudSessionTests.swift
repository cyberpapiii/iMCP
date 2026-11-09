import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

@MainActor
final class ICloudSessionTests: XCTestCase {
    func testStoredSessionSignsInAtLaunchWithoutAPrompt() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: nil,
                webAuthUser: nil,
                trustedAt: Date()
            )
        )
        transport.stub("validate", json: accountLoginBody())

        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()

        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertNotNil(session.findMy)
    }

    /// Restoring twice would ask Apple again for an answer that cannot have
    /// changed, and a failed replay counts against the account.
    func testRestoreRunsOnlyOncePerLaunch() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: transport, storage: storage)

        await session.restoreIfNeeded()
        await session.restoreIfNeeded()

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    func testExpiredSessionAsksToSignInAgainRatherThanLookingSignedOut() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: nil,
                webAuthUser: nil,
                trustedAt: Date(timeIntervalSinceNow: -(ICloudStatusCommandLine.trustLifetime + 60))
            )
        )
        // Apple's verdict on the stored session. A network failure would be
        // retried instead (`reconnecting`).
        transport.stub("validate", status: 421)

        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()

        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertFalse(session.isSignedIn)
    }

    /// Location's activation check, which runs before a tool, words a
    /// missing session as the tools do.
    func testActivatingLocationWithoutASessionUsesTheToolWords() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedSession())
        transport.fail("validate", with: URLError(.notConnectedToInternet))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        XCTAssertEqual(session.state, .reconnecting)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = LocationService.testing(
            peopleReadiness: peopleSwitchedOff(),
            historyStore: LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite")),
            session: { session }
        )

        do {
            try await service.activate()
            XCTFail("expected no session")
        } catch {
            XCTAssertEqual(error as? FindMyError, ICloudStatus.toolError(of: session))
            let words = (error as? FindMyError)?.errorDescription ?? ""
            XCTAssertTrue(words.contains("Reconnecting"), words)
        }
    }

    /// Launching at login beats the Wi-Fi to it, so a restore that cannot
    /// reach Apple tries again, three more times, each after a longer wait
    /// and once the network is back. Four attempts back to back would all
    /// land in the same outage.
    func testARestoreThatCannotReachAppleBacksOffBetweenAttempts() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedSession())
        for _ in 0 ..< 4 {
            transport.fail("validate", with: URLError(.notConnectedToInternet))
        }
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, clock: clock)

        await session.restoreIfNeeded()
        XCTAssertEqual(session.state, .reconnecting, "a queued retry is not a sign-in")
        XCTAssertEqual(ICloudStatus.toolError(of: session).errorDescription?.contains("Reconnecting"), true)
        guard case .restoreFailed = session.lastInvalidationReason else {
            return XCTFail(
                "expected a recorded restore failure, got \(String(describing: session.lastInvalidationReason))"
            )
        }

        var attempts: [Int] = []
        for wait in [10.0, 30, 90] {
            await session.advance(clock, by: wait - 1)
            attempts.append(transport.requests(matching: "validate").count)
            await session.advance(clock, by: 1)
            attempts.append(transport.requests(matching: "validate").count)
        }
        XCTAssertEqual(attempts, [1, 2, 2, 3, 3, 4])
        XCTAssertEqual(clock.networkWaits, 3)

        await session.advance(clock, by: 24 * 60 * 60)
        XCTAssertEqual(transport.requests(matching: "validate").count, 4, "four attempts in all")
        XCTAssertEqual(session.state, .needsReauthentication)
    }

    /// The menu, Settings, the Location window, and the tools all show this
    /// one text: the failure's own words, else the recorded reason.
    func testTheProblemIsTheLastFailureThenTheRecordedReason() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedSession())
        transport.fail("validate", with: URLError(.notConnectedToInternet))
        let session = ICloudSession(transport: transport, storage: storage)

        await session.restoreIfNeeded()
        XCTAssertEqual(session.problem, ICloudFailure.unreachable.message)
        XCTAssertEqual(ICloudStatus.report(of: session).note, "Last problem: \(ICloudFailure.unreachable.message)")

        session.beginManualSignIn()
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.problem, session.lastInvalidationReason?.description)
        XCTAssertNotNil(session.problem)
    }

    func testARestoreRetryThatReachesAppleSignsIn() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedSession())
        transport.fail("validate", with: URLError(.notConnectedToInternet))
        transport.stub("validate", json: accountLoginBody())
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, clock: clock)

        await session.restoreIfNeeded()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertEqual(session.state, .reconnecting)
        await session.advance(clock, by: 10)

        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertNil(session.failure)
    }

    /// A rejected code returns to the code field. Returning to the password
    /// field would throw away an accepted password and restart the flow.
    func testRejectedCodeKeepsTheUserOnTheCodeStep() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub("appleauth/auth", json: [String: Any]())
        transport.stub("verify/trusteddevice", json: [String: Any]())

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertEqual(session.state, .awaitingCode(.trustedDevice))

        transport.stub("verify/trusteddevice/securitycode", status: 400)
        await session.submitTwoFactorCode("000000")

        XCTAssertEqual(session.state, .awaitingCode(.trustedDevice))
        XCTAssertEqual(session.failure, ICloudAuthError.twoFactorCodeRejected.errorDescription)
    }

    /// An expired session cannot accept any code, so the UI returns to the
    /// start rather than leaving the user typing into a dead field.
    func testExpiredSessionSendsTheUserBackToTheStart() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub("appleauth/auth", json: [String: Any]())
        transport.stub("verify/trusteddevice", json: [String: Any]())

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")

        transport.stub("verify/trusteddevice/securitycode", status: 421)
        await session.submitTwoFactorCode("123456")

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertEqual(session.failure, ICloudAuthError.sessionExpired.errorDescription)
    }

    func testWrongPasswordReturnsToSignedOutWithAReason() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 401)

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "wrong")

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertEqual(session.failure, ICloudAuthError.invalidCredentials.errorDescription)
    }

    private func storedSession() -> ICloudCredentials {
        ICloudCredentials(
            accountName: "user@example.com",
            accountCountry: "USA",
            sessionToken: "stored-token",
            trustToken: "stored-trust",
            webAuthToken: nil,
            webAuthUser: nil,
            trustedAt: Date()
        )
    }

    /// A failed manual sign-in replaces nothing, so the earlier session is
    /// still on disk and the UI has to stay in a state that can sign it out.
    func testAFailedSignInOverAStoredSessionAsksToSignInAgain() async {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        await storage.save(storedSession())
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 401)

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "wrong")

        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertEqual(session.failure, ICloudAuthError.invalidCredentials.errorDescription)

        await session.signOut()

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(stored())
    }

    func testAnExpiredCodeOverAStoredSessionAsksToSignInAgain() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedSession())
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub("appleauth/auth", json: [String: Any]())
        transport.stub("verify/trusteddevice", json: [String: Any]())

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")

        transport.stub("verify/trusteddevice/securitycode", status: 421)
        await session.submitTwoFactorCode("123456")

        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertEqual(session.failure, ICloudAuthError.sessionExpired.errorDescription)
    }

    func testSigningOutForgetsTheAccount() async {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertTrue(session.isSignedIn)

        await session.signOut()
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(session.findMy)
        XCTAssertNil(stored())
    }

    func testUnreadableStorageDoesNotLookSignedOut() async {
        let transport = ScriptedTransport()
        let session = ICloudSession(
            transport: transport,
            storage: InMemoryKeychainItem(loadFailure: errSecAuthFailed).iCloudCredentialStorage
        )
        await session.restoreIfNeeded()

        XCTAssertEqual(session.state, .credentialsUnreadable)
        XCTAssertFalse(session.isSignedIn)
        XCTAssertEqual(session.failure, ICloudAuthError.credentialsUnreadable.errorDescription)
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    /// Try Again in the sign-in window reads the Keychain again; launching
    /// again is the only other thing that would.
    func testRetryingTheKeychainRestoresTheSessionItCouldNotRead() async throws {
        let keychain = InMemoryKeychainItem(try JSONEncoder().encode(storedSession()))
        keychain.failLoad(onAttempt: 1, with: errSecInteractionNotAllowed)
        let storage = keychain.iCloudCredentialStorage
        let transport = ScriptedTransport()
        transport.stub("validate", json: accountLoginBody())
        let session = ICloudSession(transport: transport, storage: storage)

        await session.restoreIfNeeded()
        XCTAssertEqual(session.state, .credentialsUnreadable)
        await session.restoreIfNeeded()
        XCTAssertEqual(keychain.loads, 1, "a launch restores once")

        await session.retryKeychain()

        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertNil(session.failure)
    }

    func testFailedSignOutKeepsTheSignedInSession() async {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem(failDelete: true)
        let storage = keychain.iCloudCredentialStorage
        let stored = { keychain.data }
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertTrue(session.isSignedIn)

        await session.signOut()
        XCTAssertTrue(session.isSignedIn)
        XCTAssertNotNil(session.findMy)
        XCTAssertNotNil(stored())
        XCTAssertEqual(session.failure, ICloudAuthError.couldNotClearSession.errorDescription)
    }

    func testRefreshDoesNotInvalidateOnANetworkFailure() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertTrue(session.isSignedIn)

        transport.stub("validate", status: 503)
        let refreshed = await session.renewRejectedClient()

        XCTAssertNil(refreshed)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertNotNil(session.findMy)
    }

    func testRefreshLetsAppleDecideWhetherOldTrustStillWorks() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        let session = ICloudSession(transport: transport, storage: storage)
        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertTrue(session.isSignedIn)

        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: nil,
                webAuthUser: nil,
                trustedAt: Date(timeIntervalSinceNow: -(ICloudStatusCommandLine.trustLifetime + 60))
            )
        )
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        let refreshed = await session.renewRejectedClient()
        XCTAssertNotNil(refreshed)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertNotNil(session.findMy)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
    }

    func testManualPasswordSignInEntersRepairRecoveryWhenTermsArePending() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        var body = accountLoginBody()
        body["termsUpdateNeeded"] = true
        transport.stub("accountLogin", json: body)
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60
        )

        await session.signIn(accountName: "user@example.com", password: "pw")

        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.accountRepairPending, true)
        XCTAssertEqual(saved.sessionToken, "t")
    }

    func testManualTwoFactorSignInEntersRepairRecoveryWhenTermsArePending() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stubRaw("appleauth/auth", body: "<html></html>")
        transport.stub("verify/trusteddevice")
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60
        )
        await session.signIn(accountName: "user@example.com", password: "pw")

        transport.stub("verify/trusteddevice/securitycode")
        transport.stub("2sv/trust", headers: ["X-Apple-Session-Token": "t"])
        var body = accountLoginBody()
        body["termsUpdateNeeded"] = true
        transport.stub("accountLogin", json: body)
        await session.submitTwoFactorCode("123456")

        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.accountRepairPending, true)
    }
}
