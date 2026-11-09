import Foundation
import SQLite3
import SRP
import XCTest
import os

@testable import iMCP

/// Apple discards web sessions on its own schedule. The only way "sign in
/// once" can be true is if the app can sign in again by itself, which takes
/// the password and the trust token that lets the sign-in skip the code.
final class ICloudSilentReauthenticationTests: XCTestCase {
    private func stubSignIn(_ transport: ScriptedTransport) {
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub(
            "signin/init",
            headers: ["X-Apple-ID-Session-Id": "session-1"],
            json: challengeBody
        )
        transport.stub(
            "signin/complete",
            headers: [
                "X-Apple-Session-Token": "fresh-session-token",
                "X-Apple-TwoSV-Trust-Token": "fresh-trust-token",
                "X-Apple-ID-Account-Country": "USA",
            ]
        )
        transport.stub("accountLogin", json: accountLoginBody())
    }

    /// Apple rejects the stored cookies, so the renewal goes straight to a
    /// password sign-in.
    private func reauthenticate(
        _ client: ICloudAuthClient,
        _ transport: ScriptedTransport
    ) async -> ICloudRecoveryOutcome {
        transport.stub("validate", status: 421)
        return await client.recover(.findMyRejected)
    }

    private func stored(password: String?) -> ICloudCredentials {
        ICloudCredentials(
            accountName: "user@example.com",
            accountCountry: "USA",
            sessionToken: "dead-session-token",
            trustToken: "stored-trust-token",
            webAuthToken: "webauth",
            webAuthUser: "webuser",
            trustedAt: Date().addingTimeInterval(-3_600),
            dsid: "12345",
            webservices: ["findme": URL(string: "https://p42-fmipweb.icloud.com:443")!],
            cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "old",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ],
            password: password
        )
    }

    func testSignInKeepsThePasswordWithTheTokens() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        stubSignIn(transport)
        let client = ICloudAuthClient(transport: transport, storage: storage)

        _ = try await client.signIn(accountName: "user@example.com", password: "pw")

        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.password, "pw")
    }

    func testReauthenticateSignsInWithTheStoredPasswordAndTrustToken() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(password: "pw"))
        stubSignIn(transport)
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let outcome = await reauthenticate(client, transport)

        let account = try XCTUnwrap(outcome.account, "expected a live session, got \(outcome.label)")
        XCTAssertEqual(account.dsid, "12345")
        let complete = try XCTUnwrap(transport.requests(matching: "signin/complete").first)
        XCTAssertEqual(complete.json["trustTokens"] as? [String], ["stored-trust-token"])
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.sessionToken, "fresh-session-token")
        XCTAssertEqual(saved.trustToken, "fresh-trust-token")
        XCTAssertEqual(saved.password, "pw")
    }

    func testAutomaticReauthenticationIsLimitedAcrossClientRestarts() async throws {
        let firstTransport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        stubSignIn(firstTransport)
        let firstClient = ICloudAuthClient(transport: firstTransport, storage: storage)
        _ = await reauthenticate(firstClient, firstTransport)

        let secondTransport = ScriptedTransport()
        stubSignIn(secondTransport)
        let secondClient = ICloudAuthClient(transport: secondTransport, storage: storage)
        let outcome = await reauthenticate(secondClient, secondTransport)

        XCTAssertEqual(outcome.label, "passwordAttemptSpent", "expected repeated automatic browser sign-in to stop")

        XCTAssertTrue(secondTransport.requests(matching: "signin").isEmpty)
    }

    func testAutomaticReauthenticationGuardDoesNotExpireIntoDailyEmails() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        var credentials = stored(password: "pw")
        credentials.lastAutomaticReauthenticationAt = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        await storage.save(credentials)
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let outcome = await reauthenticate(client, transport)

        XCTAssertEqual(outcome.label, "passwordAttemptSpent", "expected the recovery episode guard to remain active")
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    func testAutomaticGuardSurvivesAKeychainReadFailureDuringSessionPersist() async throws {
        let keychain = InMemoryKeychainItem(try JSONEncoder().encode(stored(password: "pw")))
        // The first write arms the guard; the read after it is the one
        // before the new session is written.
        keychain.failNextLoad(afterSaves: 1)
        let storage = keychain.iCloudCredentialStorage
        let transport = ScriptedTransport()
        stubSignIn(transport)
        let client = ICloudAuthClient(transport: transport, storage: storage)

        _ = await reauthenticate(client, transport)

        let data = try XCTUnwrap(keychain.data)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: data)
        XCTAssertNotNil(saved.lastAutomaticReauthenticationAt)
        XCTAssertEqual(keychain.failedLoads, 1)
    }

    func testFailureBeforePasswordCompletionDoesNotConsumeTheAutomaticGuard() async throws {
        let firstTransport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(password: "pw"))
        firstTransport.fail("signin/init", with: URLError(.notConnectedToInternet))
        let firstClient = ICloudAuthClient(transport: firstTransport, storage: storage)

        let interrupted = await reauthenticate(firstClient, firstTransport)
        XCTAssertEqual(interrupted.label, "renewalInterrupted")
        XCTAssertTrue(interrupted.error is URLError)

        var saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertNil(saved.lastAutomaticReauthenticationAt)
        XCTAssertTrue(firstTransport.allCookies().contains { $0.value == "old" })

        let secondTransport = ScriptedTransport()
        stubSignIn(secondTransport)
        let secondClient = ICloudAuthClient(transport: secondTransport, storage: storage)
        _ = await reauthenticate(secondClient, secondTransport)

        saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertNotNil(saved.lastAutomaticReauthenticationAt)
        XCTAssertEqual(secondTransport.requests(matching: "signin/complete").count, 1)
    }

    /// `trustedAt` is the trust token's birth. A silent re-sign-in that Apple
    /// honors with the same token keeps it; a new token starts the clock over.
    func testReauthenticateKeepsTrustedAtForTheSameTokenAndResetsItForANewOne() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        let birth = Date().addingTimeInterval(-20 * 24 * 3_600)
        var credentials = stored(password: "pw")
        credentials.trustedAt = birth
        await storage.save(credentials)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", headers: ["X-Apple-ID-Session-Id": "session-1"], json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "fresh-session-token"])
        transport.stub("accountLogin", json: accountLoginBody())
        let clock = TestClock()
        let client = ICloudAuthClient(transport: transport, storage: storage, now: { clock.now })

        _ = await reauthenticate(client, transport)
        var saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.trustToken, "stored-trust-token")
        XCTAssertEqual(saved.trustedAt.timeIntervalSince1970, birth.timeIntervalSince1970, accuracy: 1)

        _ = await client.endRecoveryEpisode(disarmingPasswordGuard: true)
        clock.advance(by: PasswordAttemptGuard.retryInterval)
        stubSignIn(transport)
        _ = await reauthenticate(client, transport)
        saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.trustToken, "fresh-trust-token")
        XCTAssertGreaterThan(saved.trustedAt, birth.addingTimeInterval(60))
    }

    func testReauthenticateWithoutAPasswordSaysSo() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: nil))
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let outcome = await reauthenticate(client, transport)

        XCTAssertEqual(outcome.label, "needsSignIn")
        XCTAssertEqual(outcome.error as? ICloudAuthError, .noStoredPassword)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    /// The Keychain copy is the one that lasts. A validation long after the
    /// sign-in must not write back a password the actor was still holding.
    func testValidationWritesTheStoredPasswordNotOneLeftInMemory() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        stubSignIn(transport)
        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")

        var onDisk = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        onDisk.password = "changed-on-disk"
        onDisk.webservices = nil
        await storage.save(onDisk)
        transport.stub("validate", json: accountLoginBody())

        _ = await client.recover(.pausedPoll)

        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertNotNil(saved.webservices, "validation wrote the session")
        XCTAssertEqual(saved.password, "changed-on-disk")
    }

    /// With no password in hand, the stored snapshot is the only copy. A
    /// write that could not read it first would save a session without one.
    func testAnUnreadableKeychainDuringValidationDoesNotEraseThePassword() async throws {
        var credentials = stored(password: "pw")
        credentials.webservices = nil
        let keychain = InMemoryKeychainItem(try JSONEncoder().encode(credentials))
        keychain.failLoad(onAttempt: 2)
        let storage = keychain.iCloudCredentialStorage
        let transport = ScriptedTransport()
        transport.stub("validate", json: accountLoginBody())
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let outcome = await client.recover(.launch)
        XCTAssertEqual(outcome.label, "keychainUnreadable")

        let data = try XCTUnwrap(keychain.data)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: data)
        XCTAssertEqual(saved.password, "pw")
    }

    func testRestoreThenValidationKeepsThePassword() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        var credentials = stored(password: "pw")
        credentials.webservices = nil
        await storage.save(credentials)
        transport.stub("validate", json: accountLoginBody())
        let client = ICloudAuthClient(transport: transport, storage: storage)

        _ = await client.recover(.launch)

        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertNotNil(saved.webservices, "validation wrote the session")
        XCTAssertEqual(saved.password, "pw")
    }

    /// A valid browser session can lose only Find My authorization. Repairing
    /// that service must use Apple's narrower Find My web challenge, not create
    /// a new browser sign-in and its account email.
    @MainActor
    func testFindMy450UsesServiceAuthorizationBeforeBrowserSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        var credentials = stored(password: "pw")
        credentials.clientID = "client-id"
        await storage.save(credentials)
        let authorizer = ScriptedWebAuthorizer()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        XCTAssertTrue(session.isSignedIn)

        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        let findMy = await session.renewRejectedClient()

        XCTAssertNotNil(findMy)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertNil(session.lastInvalidationReason)
        let authorization = try XCTUnwrap(authorizer.attempts.first)
        XCTAssertEqual(authorization.accountName, "user@example.com")
        XCTAssertEqual(authorization.password, "pw")
        XCTAssertTrue(transport.requests(matching: "accountLogin").isEmpty)
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)
    }

    func testFailedFindMyAuthorizationIsNotRetriedAfterRestart() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let authorizer = ScriptedWebAuthorizer()
        authorizer.fail(with: FindMyWebAuthorizationError.credentialsRejected)
        let client = ICloudAuthClient(transport: transport, storage: storage, webAuthorizer: authorizer)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)

        let rejected = await client.recover(.findMyRejected)

        XCTAssertEqual(rejected.label, "needsSignIn")
        XCTAssertEqual(rejected.error as? FindMyWebAuthorizationError, .credentialsRejected)

        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertNotNil(saved.lastAutomaticReauthenticationAt)

        let restartedTransport = ScriptedTransport()
        let restartedAuthorizer = ScriptedWebAuthorizer()
        let restarted = ICloudAuthClient(
            transport: restartedTransport,
            storage: storage,
            webAuthorizer: restartedAuthorizer
        )
        restartedTransport.stub("validate", json: accountLoginBody())
        restartedTransport.stub("initClient", status: 450)
        restartedTransport.stub("initClient", status: 450)

        let stopped = await restarted.recover(.findMyRejected)

        XCTAssertEqual(stopped.label, "passwordAttemptSpent", "expected the durable one-attempt guard")
        XCTAssertTrue(restartedAuthorizer.attempts.isEmpty)
    }

    /// Apple's own Find My page refusing the saved password is a verdict
    /// nothing automatic can change, so the session asks for a sign-in
    /// instead of polling a password Apple has already turned down.
    @MainActor
    func testRejectedFindMyPasswordAsksForAManualSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let authorizer = ScriptedWebAuthorizer()
        authorizer.fail(with: FindMyWebAuthorizationError.credentialsRejected)
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer, clock: clock)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertNil(session.pauseReason)
        XCTAssertFalse(session.hasLiveClient)
        XCTAssertEqual(
            session.lastInvalidationReason,
            .appleRejectedStoredSession("Find My rejected the renewed session (450)")
        )
        XCTAssertEqual(session.lastFailure, .findMyAuthorization(.credentialsRejected))

        await session.advance(clock, by: 24 * 60 * 60)
        XCTAssertEqual(transport.requests(matching: "validate").count, 1, "nothing polls a refused password")
        XCTAssertEqual(authorizer.attempts.count, 1)
    }

    @MainActor
    func testAReauthenticatedSessionMustPassFindMyBeforeItIsAdopted() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertNotNil(session.failure)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
    }

    @MainActor
    func testPendingTermsPauseRecoveryWithoutAnotherPasswordSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        var body = accountLoginBody()
        body["termsUpdateNeeded"] = true
        transport.stub("validate", json: body)

        let first = await session.renewRejectedClient()
        let second = await session.renewRejectedClient()

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        XCTAssertEqual(transport.requests(matching: "validate").count, 1)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    @MainActor
    func testAcceptedTermsRecoverOnCookieValidationWithoutAnotherPasswordSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        var credentials = stored(password: "pw")
        credentials.webservices = nil
        await storage.save(credentials)
        var repairBody = accountLoginBody()
        repairBody["termsUpdateNeeded"] = true
        transport.stub("validate", json: repairBody)
        transport.stub("validate", status: 503)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])
        let clock = TestClock()
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60,
            clock: clock
        )

        await session.restoreIfNeeded()
        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))

        await session.advance(clock, by: 59)
        XCTAssertEqual(transport.requests(matching: "validate").count, 1, "nothing before the interval")
        await session.advance(clock, by: 1)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        await session.advance(clock, by: 60)

        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(transport.requests(matching: "validate").count, 3)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    @MainActor
    func testAutomaticTermsGateKeepsFreshSessionAndRecoversWithoutAnotherEmail() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let clock = TestClock()
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60,
            clock: clock
        )
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", headers: ["X-Apple-ID-Session-Id": "session-1"], json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "fresh-session-token"])
        var repairBody = accountLoginBody()
        repairBody["termsUpdateNeeded"] = true
        transport.stub("accountLogin", json: repairBody)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        _ = await session.renewRejectedClient()
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        await session.advance(clock, by: 60)

        XCTAssertTrue(session.isSignedIn)
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.sessionToken, "fresh-session-token")
        XCTAssertNil(saved.lastAutomaticReauthenticationAt)
        XCTAssertEqual(saved.accountRepairPending, false)
    }

    @MainActor
    func testSignedInRepairRecoveryRetriesAfterATransientValidationFailure() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let clock = TestClock()
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60,
            clock: clock
        )
        await session.restoreIfNeeded()
        var repairBody = accountLoginBody()
        repairBody["termsUpdateNeeded"] = true
        transport.stub("validate", json: repairBody)
        transport.stub("validate", status: 503)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        _ = await session.renewRejectedClient()
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        await session.advance(clock, by: 60)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired), "a 503 changes nothing")
        await session.advance(clock, by: 60)

        XCTAssertTrue(session.isSignedIn)
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(transport.requests(matching: "validate").count, 3)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    @MainActor
    func testRejectedManualSessionIsNotReadoptedUntilFindMyAcceptsIt() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])
        let clock = TestClock()
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60,
            clock: clock
        )

        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertEqual(session.lastInvalidationReason, .paused(.accountRepairRequired))
        XCTAssertFalse(session.isSignedIn)
        await session.advance(clock, by: 60)

        XCTAssertTrue(session.isSignedIn)
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(transport.requests(matching: "validate").count, 1)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
    }

    @MainActor
    func testIndeterminateFindMyProbeRetriesWithoutAnotherPasswordSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.stub("initClient", status: 503)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])
        let clock = TestClock()
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60,
            clock: clock
        )

        await session.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertEqual(session.lastInvalidationReason, .paused(.verificationPending))
        await session.advance(clock, by: 60)

        XCTAssertTrue(session.isSignedIn)
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
    }

    /// The network dropping in the middle of the silent re-sign-in is not
    /// Apple's verdict. The session keeps its client and stays signed in, so
    /// the next 421 retries the refresh instead of leaving the app parked in
    /// `working` where nothing ever runs again.
    @MainActor
    func testANetworkFailureDuringSilentReauthKeepsTheSession() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.fail("signin/init", with: URLError(.notConnectedToInternet))

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertNotNil(session.findMy)
        XCTAssertNotNil(session.failure)
    }

    /// Apple answering 503 to the SRP handshake is not a wrong password.
    @MainActor
    func testAppleBeingDownDuringSilentReauthKeepsTheSession() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", status: 503)

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertEqual(session.failure, ICloudAuthError.appleRejectedRequest(status: 503).errorDescription)
    }

    /// The sampler and a tool call that see the same 421 share one login.
    @MainActor
    func testConcurrentRefreshesShareOneLogin() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        async let first = session.renewRejectedClient()
        async let second = session.renewRejectedClient()
        let results = await [first, second]

        XCTAssertEqual(results.compactMap { $0 }.count, 2)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertNil(session.lastInvalidationReason)
    }

    private func webAuthCookie(_ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: "X-APPLE-WEBAUTH-TOKEN", .value: value, .domain: ".icloud.com", .path: "/"])!
    }

    private func storedCookieValues(_ storedData: () -> Data?) throws -> [String] {
        try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData())).cookies?.map(\.value) ?? []
    }

    /// A sign-in clears the jar and builds a new one, which is no session
    /// until it is saved. A cookie write meanwhile writes nothing, so a
    /// sign-in that then fails for a reason Apple did not decide puts back
    /// the last stored session, and the next rotation is written again.
    func testACookieWriteDuringASignInPersistsNothing() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = await client.recover(.launch)
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.fail("signin/init", with: URLError(.notConnectedToInternet))
        transport.block("signin/init")

        let renewal = Task { await client.recover(.findMyRejected) }
        await transport.waitUntilBlocked("signin/init")
        // What Apple's sign-in shell leaves in the cleared jar.
        transport.setCookies([webAuthCookie("shell")], for: ICloudEndpoint.home)
        let rotated = await client.persistRotatedCookies()
        let ended = await client.endRecoveryEpisode(disarmingPasswordGuard: true)
        transport.resume("signin/init")
        let outcome = await renewal.value

        XCTAssertFalse(rotated)
        XCTAssertFalse(ended)
        XCTAssertEqual(outcome.label, "renewalInterrupted")
        XCTAssertEqual(try storedCookieValues(storedData), ["old"])
        XCTAssertEqual(transport.allCookies().map(\.value), ["old"], "the last stored jar is back")

        transport.setCookies([webAuthCookie("rotated")], for: ICloudEndpoint.home)
        let afterwards = await client.persistRotatedCookies()
        XCTAssertTrue(afterwards)
        XCTAssertEqual(try storedCookieValues(storedData), ["old", "rotated"])
    }

    /// A sign-out supersedes the sign-in in progress. When the Keychain
    /// then refuses to delete the record, the client goes back to that
    /// record: its jar is the live one again, and the next rotation is
    /// written instead of being refused for a sign-in nothing will finish.
    func testAFailedSignOutDuringASignInPutsTheStoredSessionBack() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        let storedData = { keychain.data }
        await storage.save(stored(password: "pw"))
        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = await client.recover(.launch)
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        transport.block("signin/init")

        let renewal = Task { await client.recover(.findMyRejected) }
        await transport.waitUntilBlocked("signin/init")
        keychain.failDelete = true
        do {
            try await client.signOut()
            XCTFail("expected the failed delete to throw")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .couldNotClearSession)
        }
        transport.resume("signin/init")
        let outcome = await renewal.value

        XCTAssertEqual(outcome.label, "superseded")
        XCTAssertEqual(transport.allCookies().map(\.value), ["old"], "the stored jar is back")
        let accountName = await client.currentAccountName()
        XCTAssertEqual(accountName, "user@example.com")
        transport.setCookies([webAuthCookie("rotated")], for: ICloudEndpoint.home)
        let written = await client.persistRotatedCookies()
        XCTAssertTrue(written)
        XCTAssertEqual(try storedCookieValues(storedData), ["old", "rotated"])
    }

    /// No password goes out without a stored password and a disarmed
    /// one-attempt guard, so the menu never says "Signing in…" for one.
    func testAFullSignInThatCannotSendAPasswordNeverSignalsSigningIn() async throws {
        var armed = stored(password: "pw")
        armed.lastAutomaticReauthenticationAt = Date().addingTimeInterval(-86_400)
        for (record, expected) in [(armed, "passwordAttemptSpent"), (stored(password: nil), "needsSignIn")] {
            let transport = ScriptedTransport()
            let (storage, _) = storageInMemory()
            await storage.save(record)
            let client = ICloudAuthClient(transport: transport, storage: storage)
            _ = await client.recover(.launch)
            transport.stub("validate", status: 421)
            stubSignIn(transport)
            let signals = OSAllocatedUnfairLock(initialState: 0)

            let outcome = await client.recover(.findMyRejected, willSignIn: { signals.withLock { $0 += 1 } })

            XCTAssertEqual(outcome.label, expected)
            XCTAssertEqual(signals.withLock { $0 }, 0, "\(expected) signalled a sign-in")
            XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
        }
    }

    /// The menu says "Signing in…" from the first request of a full
    /// sign-in, and neither the trailing cookie write that comes due during
    /// it nor a quit's flush writes the half-built jar. The sign-in then
    /// fails on the network, and the session it would have replaced goes
    /// back to work with its own jar.
    @MainActor
    func testAFullSignInShowsAsSigningInFromItsStartAndWritesNoCookies() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        let storedData = { keychain.data }
        await storage.save(stored(password: "pw"))
        for path in ["initClient", "refreshClient"] {
            transport.stub(
                path,
                json: [
                    "serverContext": ["x": 1],
                    "content": [["id": "d1", "name": "Phone", "deviceClass": "iPhone", "thisDevice": false]],
                ]
            )
        }
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, cookieWriteInterval: 60, clock: clock)
        await session.restoreIfNeeded()
        let findMy = try XCTUnwrap(session.findMy)
        transport.setCookies([webAuthCookie("first")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        XCTAssertEqual(try storedCookieValues(storedData), ["old", "first"])
        // Inside the write window, so this rotation waits for a trailing write.
        transport.setCookies([webAuthCookie("second")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        let savesBefore = keychain.saves

        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.fail("signin/init", with: URLError(.notConnectedToInternet))
        transport.block("authorize/signin")
        let renewal = Task { await session.renewRejectedClient() }
        await transport.waitUntilBlocked("authorize/signin")

        XCTAssertEqual(session.state, .working)
        transport.setCookies([webAuthCookie("shell")], for: ICloudEndpoint.home)
        clock.advance(by: 60)
        for _ in 0 ..< 20 { await Task.yield() }
        await session.flushCookies()
        XCTAssertEqual(keychain.saves, savesBefore, "nothing was written during the sign-in")

        transport.resume("authorize/signin")
        let renewed = await renewal.value
        await session.settle()

        XCTAssertNil(renewed)
        XCTAssertTrue(session.findMy === findMy)
        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertEqual(try storedCookieValues(storedData), ["old", "first"])
        XCTAssertFalse(transport.allCookies().contains { $0.value == "shell" })
    }

    /// A silent renewal keeps the old client until the new one is proved,
    /// so Location's tools stay listed instead of dropping out and coming
    /// back, which every connected agent would see as a tools/list change.
    @MainActor
    func testLocationStaysActivatedWhileTheSessionRenews() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])
        transport.block("signin/complete")
        let location = LocationService.testing(
            peopleReadiness: peopleSwitchedOff(),
            historyStore: LocationHistoryStore(url: temporaryDirectoryURL().appendingPathComponent("history.sqlite")),
            session: { session }
        )

        let renewal = Task { await session.renewRejectedClient() }
        await transport.waitUntilBlocked("signin/complete")

        XCTAssertEqual(session.state, .working)
        let activatedDuringRenewal = await location.isActivated
        XCTAssertTrue(activatedDuringRenewal)

        transport.resume("signin/complete")
        let renewed = await renewal.value
        XCTAssertNotNil(renewed)
        let activatedAfterRenewal = await location.isActivated
        XCTAssertTrue(activatedAfterRenewal)
    }

    @MainActor
    func testSignOutSupersedesAnInFlightAutomaticSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", headers: ["X-Apple-ID-Session-Id": "session-1"], json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "fresh-session-token"])
        transport.stub("accountLogin", json: accountLoginBody())
        transport.block("signin/complete")

        let refresh = Task { await session.renewRejectedClient() }
        await transport.waitUntilBlocked("signin/complete")
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)

        await session.signOut()
        transport.resume("signin/complete")
        _ = await refresh.value

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(session.findMy)
        XCTAssertNil(storedData())
    }

    @MainActor
    func testARejectedSessionWithoutAPasswordAsksForASignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: nil))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertNotNil(session.lastInvalidationReason)
        XCTAssertEqual(session.failure, ICloudAuthError.noStoredPassword.errorDescription)
    }

    @MainActor
    func testALapsedTrustTokenStopsAtTheCodeInsteadOfAFullSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(password: "pw"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", headers: ["X-Apple-ID-Session-Id": "session-1"], json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stubRaw("appleauth/auth", body: "<html></html>")

        _ = await session.renewRejectedClient()

        guard case .awaitingCode = session.state else {
            return XCTFail("expected awaitingCode, got \(session.state)")
        }
    }
}
