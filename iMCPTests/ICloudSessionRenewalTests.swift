import XCTest
import os

@testable import iMCP

/// The session failure seen live on 2026-09-03: after a reboot, Find My
/// answered 450, session validation answered 200, and Find My answered 450 again.
/// The session stayed "signed in" and nothing was recorded. These tests pin
/// the recovery: a renewed browser session Find My rejects gets one scoped
/// Find My authorization attempt, not a new browser sign-in.
@MainActor
final class ICloudSessionRenewalTests: XCTestCase {
    private func stored(password: String? = "pw", clientID: String? = nil) -> ICloudCredentials {
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
            password: password,
            clientID: clientID
        )
    }

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
        transport.stub("initClient", json: deviceListBody())
    }

    /// How Apple marks a session that is gated behind updated terms: the one
    /// rejection after Find My's page that clears without a sign-in.
    private let repairGate = ["Set-Cookie": "\(ICloudCookie.accountRepair)=1; Domain=.icloud.com; Path=/"]

    private func deviceListBody() -> [String: Any] {
        [
            "serverContext": ["a": 1],
            "content": [
                [
                    "id": "phone-1", "name": "Rob's iPhone", "deviceClass": "iPhone",
                    "location": ["latitude": 40.7, "longitude": -73.9, "timeStamp": 1_700_000_000_000.0],
                ]
            ],
        ]
    }

    func testARenewedSessionFindMyRejectsAuthorizesOnlyFindMy() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        XCTAssertTrue(session.isSignedIn)
        // The live sequence: validation 200, Find My 450.
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("initClient", json: deviceListBody())

        let findMy = await session.renewRejectedClient()

        XCTAssertNotNil(findMy)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(authorizer.attempts.count, 1)
        XCTAssertEqual(
            transport.requests(matching: "validate").count,
            1,
            "after the page Find My decides, on the stored endpoints"
        )
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)
        XCTAssertTrue(transport.requests(matching: "accountLogin").isEmpty)
    }

    func testARenewedSessionThatOwesASecondFactorSignsInAgain() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        var body = accountLoginBody()
        body["hsaChallengeRequired"] = true
        body["hsaTrustedBrowser"] = false
        transport.stub("validate", json: body)
        stubSignIn(transport)

        let findMy = await session.renewRejectedClient()

        XCTAssertNotNil(findMy)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
        // Fresh password sessions are verified against Find My before adoption.
        XCTAssertEqual(transport.requests(matching: "initClient").count, 1)
    }

    /// A rejected scoped Find My authorization must be visible rather than
    /// leaving the account looking healthy while nothing works. Apple refused
    /// the saved password itself, so the way out is a sign-in.
    func testARejectedFindMyAuthorizationIsVisible() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        authorizer.fail(with: FindMyWebAuthorizationError.credentialsRejected)
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertNil(session.pauseReason)
        XCTAssertEqual(session.failure, FindMyWebAuthorizationError.credentialsRejected.errorDescription)
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)
    }

    /// Seen live three times on 2026-11-09: Find My's page signed in, Find My
    /// answered the page, and the setup service then answered 421 to iMCP's
    /// validation of the same session. So Find My decides, not validation:
    /// iMCP takes the page's jar whole and its client id with it, and asks
    /// Find My on the endpoints it already has.
    func testFindMysPageHandsOverItsJarAndClientID() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(clientID: "stored-client-id"))
        let authorizer = ScriptedWebAuthorizer()
        authorizer.produce(
            [
                HTTPCookie(properties: [
                    .name: "X-APPLE-WEBAUTH-TOKEN", .value: "page", .domain: ".icloud.com", .path: "/",
                ])!,
                HTTPCookie(properties: [
                    .name: ICloudCookie.findMyAuthorization, .value: "fmip", .domain: ".icloud.com", .path: "/",
                ])!,
            ],
            clientID: "page-client-id"
        )
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("initClient", json: deviceListBody())

        let findMy = await session.renewRejectedClient()

        XCTAssertNotNil(findMy)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        let probe = try XCTUnwrap(transport.requests(matching: "initClient").last)
        XCTAssertTrue(probe.request.url!.absoluteString.contains("clientId=page-client-id"))
        let tokens = transport.allCookies().filter { $0.name == "X-APPLE-WEBAUTH-TOKEN" }.map(\.value)
        XCTAssertEqual(tokens, ["page"], "the superseded token must not ride beside the page's")
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.clientID, "page-client-id")
    }

    /// The page script's reports: only setup and Find My calls, path, status,
    /// and client id. An empty id is no id; anything else is an ordinary note.
    func testFindMysPageCallsAreReadFromTheScriptsReports() {
        let call = FindMyWebAuthorizer.PageCall(
            #"{"request":"/fmipservice/client/web/initClient","status":200,"clientId":"page-id"}"#
        )
        XCTAssertEqual(call?.clientID, "page-id")
        XCTAssertEqual(call?.accepted, true)
        XCTAssertEqual(call?.isFindMy, true)
        let validate = FindMyWebAuthorizer.PageCall(#"{"request":"/setup/ws/1/validate","status":421,"clientId":""}"#)
        XCTAssertNil(validate?.clientID)
        XCTAssertEqual(validate?.accepted, false)
        XCTAssertNil(FindMyWebAuthorizer.PageCall("identity frame loaded"))
    }

    /// When Apple still drops the session after the page, the one automatic
    /// password attempt is spent: the user is asked to sign in, not left on
    /// "waiting for Find My verification" while a dead session is polled.
    func testASessionAppleDropsAfterFindMysPageAsksForASignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        authorizer.produce(pageCookies(), clientID: "page-client-id")
        transport.stub("validate", json: accountLoginBody())
        // Before the page, with the page's session, with iMCP's own session.
        for _ in 0 ..< 6 { transport.stub("initClient", status: 450) }
        transport.stub("validate", status: 421)

        let findMy = await session.renewRejectedClient()

        XCTAssertNil(findMy)
        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertNil(session.pauseReason)
        XCTAssertEqual(authorizer.attempts.count, 1)
        XCTAssertEqual(transport.requests(matching: "initClient").count, 6)
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)
    }

    /// When Find My refuses the page's session as iMCP replays it, iMCP's own
    /// browser session gets one try carrying only the service cookie the
    /// page earned, under iMCP's own client id.
    func testFindMysServiceCookieOnTheOwnSessionIsTheSecondTry() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(clientID: "stored-client-id"))
        let authorizer = ScriptedWebAuthorizer()
        authorizer.produce(pageCookies(), clientID: "page-client-id")
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        for _ in 0 ..< 4 { transport.stub("initClient", status: 450) }
        transport.stub("initClient", json: deviceListBody())

        let findMy = await session.renewRejectedClient()

        XCTAssertNotNil(findMy)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        let probes = transport.requests(matching: "initClient").map { $0.request.url!.absoluteString }
        XCTAssertTrue(probes[2].contains("clientId=page-client-id"), "the page's session first")
        XCTAssertTrue(try XCTUnwrap(probes.last).contains("clientId=stored-client-id"))
        let jar = transport.allCookies()
        // The scripted jar appends rather than replaces, so compare as sets.
        XCTAssertEqual(Set(jar.filter { $0.name == "X-APPLE-WEBAUTH-TOKEN" }.map(\.value)), ["old"])
        XCTAssertEqual(Set(jar.filter { $0.name == ICloudCookie.findMyAuthorization }.map(\.value)), ["fmip"])
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.clientID, "stored-client-id")
    }

    private func pageCookies() -> [HTTPCookie] {
        [
            HTTPCookie(properties: [
                .name: "X-APPLE-WEBAUTH-TOKEN", .value: "page", .domain: ".icloud.com", .path: "/",
            ])!,
            HTTPCookie(properties: [
                .name: ICloudCookie.findMyAuthorization, .value: "fmip", .domain: ".icloud.com", .path: "/",
            ])!,
        ]
    }

    /// A paused session Apple has since dropped outright cannot come back on
    /// its own; the poll says so instead of asking again every five minutes.
    func testAPausedSessionAppleDropsAsksForASignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer, clock: clock)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("validate", headers: repairGate, json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        _ = await session.renewRejectedClient()
        XCTAssertEqual(session.pauseReason, .accountRepairRequired)

        transport.stub("validate", status: 421)
        clock.advance(by: 5 * 60)
        await session.settle()

        XCTAssertEqual(transport.requests(matching: "validate").count, 3, "the poll ran")
        XCTAssertEqual(session.state, .needsReauthentication)
        XCTAssertNil(session.pauseReason)
        XCTAssertEqual(authorizer.attempts.count, 1)
    }

    /// Apple's 400 with -900007 on `signin/init` is about the Apple ID as
    /// typed, not an outage: "try again in a few minutes" sent the user the
    /// wrong way on 2026-11-09.
    func testAnAppleIDAppleWillNotLookUpSaysSo() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: transport, storage: storage)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub(
            "signin/init",
            status: 400,
            json: ["iteration": 0, "serviceErrors": [["code": "-900007", "suppressDismissal": false]]]
        )

        await session.signIn(accountName: "5555550123", password: "pw")

        XCTAssertFalse(session.isSignedIn)
        XCTAssertEqual(session.failure, ICloudAuthError.accountNameNotAccepted.errorDescription)
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)
    }

    /// A renewed session Find My accepts is left alone: one probe, no sign-in.
    func testARenewedSessionFindMyAcceptsNeedsNoSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: deviceListBody())

        let findMy = await session.renewRejectedClient()

        XCTAssertNotNil(findMy)
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 0)
        XCTAssertEqual(transport.requests(matching: "initClient").count, 1)
    }

    func testTransientFindMyProbeRetriesWithCookiesInsteadOfSigningInAgain() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let clock = TestClock()
        let session = ICloudSession(
            transport: transport,
            storage: storage,
            recoveryRetryInterval: 60,
            clock: clock
        )
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 503)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: deviceListBody())

        let first = await session.renewRejectedClient()
        XCTAssertNil(first)
        XCTAssertEqual(session.lastInvalidationReason, .paused(.verificationPending))

        await session.advance(clock, by: 60)

        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertNil(session.lastInvalidationReason)
        XCTAssertEqual(transport.requests(matching: "validate").count, 2)
        XCTAssertEqual(transport.requests(matching: "initClient").count, 2)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    // MARK: - The renewal throttle

    /// The throttle spaces out password sign-ins. A renewal that only got as
    /// far as an unreachable cookie check sent no password, so it must not
    /// hold back the next tool call's renewal for five minutes.
    func testARenewalThatNeverReachedThePasswordDoesNotThrottleTheNext() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 503)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: deviceListBody())

        let unreachable = await session.renewRejectedClient()
        XCTAssertNil(unreachable)
        XCTAssertTrue(session.isSignedIn, "the old client stays: got \(session.state)")
        let toolError = ICloudStatus.toolError(of: session).errorDescription ?? ""
        XCTAssertTrue(toolError.contains("did not finish"), toolError)
        XCTAssertFalse(toolError.contains("Sign in"), toolError)

        let renewed = await session.renewRejectedClient()
        XCTAssertNotNil(renewed)
        XCTAssertEqual(transport.requests(matching: "validate").count, 2)
    }

    /// A sign-in that failed before the password-bearing call sent nothing,
    /// so it holds nothing back either.
    func testARenewalThatFailedBeforeThePasswordDoesNotThrottleTheNext() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.fail("signin/init", with: URLError(.notConnectedToInternet))
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: deviceListBody())

        let interrupted = await session.renewRejectedClient()
        XCTAssertNil(interrupted)
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)

        let renewed = await session.renewRejectedClient()
        XCTAssertNotNil(renewed)
        XCTAssertEqual(transport.requests(matching: "validate").count, 2)
    }

    /// A renewal that did send the password still spaces out the next one,
    /// even when the password-bearing call itself failed.
    func testARenewalThatSentThePasswordThrottlesTheNext() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", headers: ["X-Apple-ID-Session-Id": "session-1"], json: challengeBody)
        transport.fail("signin/complete", with: URLError(.notConnectedToInternet))

        let interrupted = await session.renewRejectedClient()
        XCTAssertNil(interrupted)
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
        XCTAssertTrue(session.isSignedIn, "the old client stays: got \(session.state)")

        let throttled = await session.renewRejectedClient()
        XCTAssertNil(throttled)
        XCTAssertEqual(transport.requests(matching: "validate").count, 1, "no second renewal within the interval")
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)
    }

    private func stubFindMyAuthorization(_ transport: ScriptedTransport) {
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("initClient", json: deviceListBody())
    }

    /// Find My's own password page sends the password as a full sign-in
    /// does. Its probe disarms the guard, so only the throttle stops a 450
    /// minutes later from typing the password in again.
    func testAFindMyAuthorizationThrottlesTheNextRenewal() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer, clock: clock)
        await session.restoreIfNeeded()
        stubFindMyAuthorization(transport)
        let first = await session.renewRejectedClient()
        XCTAssertNotNil(first)
        XCTAssertEqual(authorizer.attempts.count, 1)

        await session.advance(clock, by: 4 * 60)
        stubFindMyAuthorization(transport)
        let second = await session.renewRejectedClient()

        XCTAssertNil(second)
        XCTAssertEqual(authorizer.attempts.count, 1, "the password went out once")
        XCTAssertEqual(transport.requests(matching: "validate").count, 1, "the second renewal reached nothing")
        XCTAssertTrue(session.isSignedIn, "the old client stays: got \(session.state)")
        XCTAssertEqual(session.lastFailure, .renewedRecently)
        let toolError = ICloudStatus.toolError(of: session).errorDescription ?? ""
        XCTAssertTrue(toolError.contains("five minutes"), toolError)
        XCTAssertFalse(toolError.contains("Sign in"), toolError)

        await session.advance(clock, by: 60)
        let third = await session.renewRejectedClient()
        XCTAssertNotNil(third)
        XCTAssertEqual(authorizer.attempts.count, 2)
    }

    /// Find My answers 450 to a session a relaunch restored, as it does after
    /// a reboot. The moment the password last went out is in the stored
    /// record, so a relaunch inside the interval sends it no sooner.
    func testTheRenewalThrottleSurvivesARelaunch() async throws {
        let (storage, storedData) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        let clock = TestClock()
        let transport = ScriptedTransport()
        let before = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer, clock: clock)
        await before.restoreIfNeeded()
        stubFindMyAuthorization(transport)
        let renewed = await before.renewRejectedClient()
        XCTAssertNotNil(renewed)
        XCTAssertEqual(authorizer.attempts.count, 1)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertNil(saved.lastAutomaticReauthenticationAt, "Find My accepted, so the guard is disarmed")
        XCTAssertEqual(saved.lastUnattendedPasswordAt, clock.now)

        await before.advance(clock, by: 60)
        let relaunchedTransport = ScriptedTransport()
        let relaunched = ICloudSession(
            transport: relaunchedTransport,
            storage: storage,
            webAuthorizer: authorizer,
            clock: clock
        )
        await relaunched.restoreIfNeeded()
        XCTAssertTrue(relaunched.isSignedIn, "got \(relaunched.state)")
        stubFindMyAuthorization(relaunchedTransport)
        let throttled = await relaunched.renewRejectedClient()

        XCTAssertNil(throttled)
        XCTAssertEqual(authorizer.attempts.count, 1, "the relaunch sent no password")
        XCTAssertTrue(relaunchedTransport.requests(matching: "validate").isEmpty)
        XCTAssertEqual(relaunched.lastFailure, .renewedRecently)

        await relaunched.advance(clock, by: 4 * 60)
        let later = await relaunched.renewRejectedClient()
        XCTAssertNotNil(later)
        XCTAssertEqual(authorizer.attempts.count, 2)
    }

    /// Both ways of sending the password say so in the menu while they run,
    /// Find My's own page as well as a full sign-in.
    func testFindMysPasswordPageShowsAsSigningIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let authorizer = ScriptedWebAuthorizer()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        let during = OSAllocatedUnfairLock<ICloudSession.State?>(initialState: nil)
        authorizer.whileAuthorizing {
            let state = await MainActor.run { session.state }
            during.withLock { $0 = state }
        }
        stubFindMyAuthorization(transport)

        let renewed = await session.renewRejectedClient()

        XCTAssertNotNil(renewed)
        XCTAssertEqual(authorizer.attempts.count, 1)
        XCTAssertEqual(during.withLock { $0 }, .working)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
    }

    /// A renewal stopped by the one-attempt guard sends no password, so the
    /// menu goes from signed in to paused without ever saying "Signing in…".
    func testARenewalTheGuardStopsNeverShowsAsSigningIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedWithArmedGuard())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        var working = false
        let watch = session.$phase.sink { phase in
            switch phase {
            case .restoring, .signingIn, .renewing: working = true
            default: break
            }
        }
        defer { watch.cancel() }

        let renewed = await session.renewRejectedClient()

        XCTAssertNil(renewed)
        XCTAssertFalse(working)
        XCTAssertEqual(session.pauseReason, .repeatedAutomaticSignInStopped)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    /// A sign-out whose Keychain delete fails has still superseded the
    /// renewal under way. The session picks the stored one up again, as a
    /// relaunch would, says why it is still signed in, and keeps writing
    /// rotated cookies, instead of sitting in "Signing in…" with nothing
    /// left to finish it.
    func testAFailedSignOutDuringARenewalRestoresTheStoredSession() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        let storedData = { keychain.data }
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        transport.block("signin/complete")

        let renewal = Task { await session.renewRejectedClient() }
        await transport.waitUntilBlocked("signin/complete")
        XCTAssertEqual(session.state, .working)
        keychain.failDelete = true
        await session.signOut()
        transport.resume("signin/complete")
        _ = await renewal.value
        await session.settle()

        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertEqual(session.failure, ICloudAuthError.couldNotClearSession.errorDescription)
        let findMy = try XCTUnwrap(session.findMy)
        let savesBefore = keychain.saves
        transport.setCookies(
            [
                HTTPCookie(properties: [
                    .name: "X-APPLE-WEBAUTH-TOKEN", .value: "rotated", .domain: ".icloud.com", .path: "/",
                ])!
            ],
            for: ICloudEndpoint.home
        )
        _ = try await findMy.snapshot()
        XCTAssertGreaterThan(keychain.saves, savesBefore)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.cookies?.last?.value, "rotated")
    }

    /// A failed sign-out leaves a pause as it was, client and jar included,
    /// with its poll back on the clock instead of cancelled for good.
    func testAFailedSignOutWhilePausedKeepsPolling() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        await storage.save(storedWithArmedGuard())
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, clock: clock)
        await session.restoreIfNeeded()
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        _ = await session.renewRejectedClient()
        XCTAssertEqual(session.pauseReason, .repeatedAutomaticSignInStopped)
        let validations = transport.requests(matching: "validate").count

        keychain.failDelete = true
        await session.signOut()

        XCTAssertEqual(session.pauseReason, .repeatedAutomaticSignInStopped)
        XCTAssertNotNil(session.findMy)
        XCTAssertEqual(session.failure, ICloudAuthError.couldNotClearSession.errorDescription)
        await session.advance(clock, by: 5 * 60)
        XCTAssertEqual(transport.requests(matching: "validate").count, validations + 1, "the poll ran")
    }

    /// A launch restore that had to sign in by password counts too.
    func testALaunchSignInThrottlesTheFirstRenewal() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        var credentials = stored()
        credentials.webservices = nil
        await storage.save(credentials)
        transport.stub("validate", status: 421)
        stubSignIn(transport)
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        XCTAssertEqual(transport.requests(matching: "signin/complete").count, 1)

        let throttled = await session.renewRejectedClient()

        XCTAssertNil(throttled)
        XCTAssertEqual(transport.requests(matching: "validate").count, 1)
    }

    // MARK: - The password guard after a launch restore (decision 15)

    private func storedWithArmedGuard() -> ICloudCredentials {
        var credentials = stored()
        credentials.lastAutomaticReauthenticationAt = Date().addingTimeInterval(-86_400)
        return credentials
    }

    private func savedGuard(_ storedData: () -> Data?) throws -> Date? {
        try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
            .lastAutomaticReauthenticationAt
    }

    /// A launch restore adopts the cached endpoints without a probe. The
    /// first call Find My accepts on them ends the recovery episode, as a
    /// probe would have, so a rejection weeks later may renew by password.
    func testTheFirstAcceptedCallAfterALaunchRestoreDisarmsTheGuard() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(storedWithArmedGuard())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        XCTAssertTrue(session.isSignedIn)
        XCTAssertNotNil(try savedGuard(storedData), "restoring alone proves nothing")

        transport.stub("initClient", json: deviceListBody())
        _ = try await XCTUnwrap(session.findMy).snapshot()

        XCTAssertNil(try savedGuard(storedData))
    }

    /// Disarmed by an accepted call, the guard is still armed, and written
    /// down, before the next password goes out.
    func testTheGuardIsArmedAgainBeforeTheNextPasswordSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(storedWithArmedGuard())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("initClient", json: deviceListBody())
        _ = try await XCTUnwrap(session.findMy).snapshot()
        XCTAssertNil(try savedGuard(storedData))

        transport.stub("validate", status: 421)
        stubSignIn(transport)
        transport.block("signin/complete")
        let renewal = Task { await session.renewRejectedClient() }
        await transport.waitUntilBlocked("signin/complete")

        XCTAssertNotNil(try savedGuard(storedData), "armed before the password-bearing call")
        transport.resume("signin/complete")
        _ = await renewal.value
    }

    /// Without an accepted call the episode is not over: the guard a
    /// previous launch armed still stops a second password sign-in.
    func testARestoredSessionNoCallAcceptedKeepsTheGuard() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(storedWithArmedGuard())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("initClient", status: 421)
        transport.stub("validate", status: 421)
        stubSignIn(transport)

        do {
            _ = try await XCTUnwrap(session.findMy).snapshot()
            XCTFail("expected Apple to reject the session")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
        }
        await session.settle()

        XCTAssertNotNil(try savedGuard(storedData))
        XCTAssertTrue(transport.requests(matching: "signin/complete").isEmpty)
        XCTAssertEqual(session.pauseReason, .repeatedAutomaticSignInStopped)
    }

    /// A paused session still has its client, and Find My can still reject
    /// it. The tool then says what the menu says, not that a renewal broke.
    func testAPausedSessionsToolErrorSaysWhatTheMenuSays() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("validate", headers: repairGate, json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        _ = await session.renewRejectedClient()
        XCTAssertEqual(session.pauseReason, .accountRepairRequired)
        XCTAssertTrue(session.hasLiveClient)

        let renewed = await session.renewRejectedClient()
        XCTAssertNil(renewed)

        let menu = ICloudStatus.report(of: session).summary.detail
        let toolError = ICloudStatus.toolError(of: session).errorDescription ?? ""
        XCTAssertTrue(toolError.contains(menu), "\(toolError) / \(menu)")
        XCTAssertFalse(toolError.contains("did not finish"), toolError)
    }

    // MARK: - A Keychain that refuses mid-renewal

    private func lockedPartWay(
        at fragment: String,
        in transport: ScriptedTransport,
        keychain: InMemoryKeychainItem,
        renewing session: ICloudSession
    ) async -> FindMyClient? {
        transport.block(fragment)
        let renewal = Task { await session.renewRejectedClient() }
        await transport.waitUntilBlocked(fragment)
        keychain.loadFailure = errSecInteractionNotAllowed
        transport.resume(fragment)
        return await renewal.value
    }

    /// Whichever rung of a renewal the Keychain refuses on, the live client
    /// stays and nothing pauses: here, the full password sign-in.
    func testAKeychainThatRefusesBeforeASignInKeepsTheLiveClient() async throws {
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        await storage.save(stored())
        let transport = ScriptedTransport()
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        let before = try XCTUnwrap(session.findMy)
        transport.stub("validate", status: 421)
        stubSignIn(transport)

        let renewed = await lockedPartWay(at: "validate", in: transport, keychain: keychain, renewing: session)

        XCTAssertNil(renewed)
        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertTrue(session.findMy === before)
        XCTAssertNil(session.pauseReason)
        XCTAssertEqual(session.failure, ICloudAuthError.credentialsUnreadable.errorDescription)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
    }

    /// The same on the rung before it, Find My's own password page.
    func testAKeychainThatRefusesBeforeFindMyAuthorizationKeepsTheLiveClient() async throws {
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        await storage.save(stored())
        let transport = ScriptedTransport()
        let authorizer = ScriptedWebAuthorizer()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer)
        await session.restoreIfNeeded()
        let before = try XCTUnwrap(session.findMy)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)

        let renewed = await lockedPartWay(at: "initClient", in: transport, keychain: keychain, renewing: session)

        XCTAssertNil(renewed)
        XCTAssertEqual(session.state, .signedIn(accountName: "user@example.com"))
        XCTAssertTrue(session.findMy === before)
        XCTAssertNil(session.pauseReason)
        XCTAssertEqual(session.failure, ICloudAuthError.credentialsUnreadable.errorDescription)
        XCTAssertTrue(authorizer.attempts.isEmpty)
    }

    /// A paused poll that cannot read leaves the pause as it was, with the
    /// reason the owner is acting on.
    func testAKeychainThatRefusesDuringAPausedPollKeepsThePause() async throws {
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        await storage.save(stored())
        let transport = ScriptedTransport()
        let authorizer = ScriptedWebAuthorizer()
        let clock = TestClock()
        let session = ICloudSession(transport: transport, storage: storage, webAuthorizer: authorizer, clock: clock)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("validate", headers: repairGate, json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        _ = await session.renewRejectedClient()
        XCTAssertEqual(session.pauseReason, .accountRepairRequired)

        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.block("initClient")
        clock.advance(by: 5 * 60)
        await transport.waitUntilBlocked("initClient")
        keychain.loadFailure = errSecInteractionNotAllowed
        transport.resume("initClient")
        await session.settle()

        XCTAssertEqual(transport.requests(matching: "validate").count, 3, "the poll ran")
        XCTAssertEqual(session.pauseReason, .accountRepairRequired)
        XCTAssertEqual(authorizer.attempts.count, 1)
    }

    // MARK: - Ringing on a lapsed session

    /// `location_ring` on a session Apple has dropped renews it the way any
    /// other Find My call does, then rings on the renewed client.
    func testRingingOnALapsedSessionRenewsAndRings() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored())
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        var devices = deviceListBody()
        devices["content"] = [
            ["id": "phone-1", "name": "Rob's iPhone", "deviceClass": "iPhone", "features": ["SND": true]]
        ]
        transport.stub("initClient", json: devices)
        transport.stub("playSound", status: 421)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: devices)
        transport.stub("refreshClient", json: devices)
        transport.stub("playSound", json: ["status": 200])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = LocationService.testing(
            peopleReadiness: peopleSwitchedOff(),
            historyStore: LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite")),
            session: { session }
        )
        let ring = try XCTUnwrap(service.tools.first { $0.name == "location_ring" })

        _ = try await ring(["device": .string("Rob's iPhone")])

        XCTAssertEqual(transport.requests(matching: "playSound").count, 2)
        XCTAssertEqual(transport.requests(matching: "validate").count, 1)
        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
    }

    /// With nothing left to renew with, the ring says why in words.
    func testRingingWithNoSessionSaysWhy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let service = LocationService.testing(
            peopleReadiness: peopleSwitchedOff(),
            historyStore: LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        )
        let ring = try XCTUnwrap(service.tools.first { $0.name == "location_ring" })

        do {
            _ = try await ring(["device": .string("Rob's iPhone")])
            XCTFail("expected no session")
        } catch {
            XCTAssertEqual(error as? FindMyError, .notSignedIn)
        }
    }

    // MARK: - Client id continuity

    /// Quit and relaunch, or reboot: the next process must present the id
    /// the trust token was issued to on every Find My call.
    func testAStoredClientIDIsReusedAcrossProcesses() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(stored(clientID: "stable-client-id"))
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", json: deviceListBody())

        _ = await session.renewRejectedClient()

        let probe = try XCTUnwrap(transport.requests(matching: "initClient").first)
        XCTAssertTrue(probe.request.url!.absoluteString.contains("clientId=stable-client-id"))
    }

    func testAFreshSignInStoresItsClientIDAndTheNextClientAdoptsIt() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        let session = ICloudSession(transport: transport, storage: storage)
        stubSignIn(transport)

        await session.signIn(accountName: "user@example.com", password: "pw")

        XCTAssertTrue(session.isSignedIn, "got \(session.state)")
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        let id = try XCTUnwrap(saved.clientID)
        XCTAssertFalse(id.isEmpty)
        let login = try XCTUnwrap(transport.requests(matching: "accountLogin").first)
        XCTAssertTrue(login.request.url!.absoluteString.contains("clientId=\(id)"))

        let nextTransport = ScriptedTransport()
        nextTransport.stub("validate", json: accountLoginBody())
        let next = ICloudAuthClient(transport: nextTransport, storage: storage)
        _ = await next.recover(.launch)
        let adopted = await next.clientID
        XCTAssertEqual(adopted, id)
    }

    /// Credentials from before the id was stored: the first cookie write
    /// after restore writes the process's id down, so it is stable from then on.
    func testACredentialWithoutAClientIDGetsOneOnTheNextCookieWrite() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(stored(clientID: nil))
        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = await client.recover(.launch)
        transport.setCookies(
            [
                HTTPCookie(properties: [
                    .name: "X-APPLE-WEBAUTH-TOKEN", .value: "new", .domain: ".icloud.com", .path: "/",
                ])!
            ],
            for: ICloudEndpoint.home
        )

        let didWrite = await client.persistRotatedCookies()
        XCTAssertTrue(didWrite)

        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        let adopted = await client.clientID
        XCTAssertEqual(saved.clientID, adopted)
    }

    func testTheStatusReportSaysWhetherAClientIDIsStored() {
        let report = ICloudStatusCommandLine.report(.found(stored(clientID: "x")))
        XCTAssertTrue(report.contains("client id: present"), report)
        let without = ICloudStatusCommandLine.report(.found(stored(clientID: nil)))
        XCTAssertTrue(without.contains("client id: absent"), without)
    }

    // MARK: - One writer for the stored record

    private func rotatedCookie() -> HTTPCookie {
        HTTPCookie(properties: [
            .name: "X-APPLE-WEBAUTH-TOKEN", .value: "rotated", .domain: ".icloud.com", .path: "/",
        ])!
    }

    /// Returns once the Keychain has been asked for more than `count` reads.
    private func waitForLoads(beyond count: Int, of keychain: InMemoryKeychainItem) async throws {
        let deadline = Date().addingTimeInterval(5)
        while keychain.loads <= count {
            guard Date() < deadline else { return XCTFail("the read never started") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A cookie write and Find My's password page both rewrite the stored
    /// record. Each reads the record and saves its change in one Keychain
    /// call, so a cookie write whose read was in flight when the guard was
    /// armed erases neither the guard nor the moment the password went out.
    func testACookieWriteRacingTheGuardKeepsBoth() async throws {
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        await storage.save(stored())
        let transport = ScriptedTransport()
        let authorizer = ScriptedWebAuthorizer()
        let client = ICloudAuthClient(transport: transport, storage: storage, webAuthorizer: authorizer)
        _ = await client.recover(.launch)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        let atHook = AsyncGate()
        let atPage = AsyncGate()
        authorizer.whileAuthorizing { await atPage.wait() }
        authorizer.fail(with: URLError(.notConnectedToInternet))

        let renewal = Task { await client.recover(.findMyRejected, willSignIn: { await atHook.wait() }) }
        await atHook.waitUntilWaiting()
        transport.setCookies([rotatedCookie()], for: ICloudEndpoint.home)
        let readGate = DispatchSemaphore(value: 0)
        let loadsBefore = keychain.loads
        keychain.loadGate = readGate
        let cookieWrite = Task { await client.persistRotatedCookies() }
        try await waitForLoads(beyond: loadsBefore, of: keychain)
        await atHook.open()
        // The guard's write queues behind the cookie write's held read.
        try await Task.sleep(for: .milliseconds(50))
        keychain.loadGate = nil
        readGate.signal()
        let didWrite = await cookieWrite.value
        await atPage.waitUntilWaiting()

        XCTAssertTrue(didWrite)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(keychain.data))
        XCTAssertTrue(saved.cookies?.contains { $0.value == "rotated" } ?? false, "the rotated jar was lost")
        XCTAssertNotNil(saved.lastAutomaticReauthenticationAt, "the guard was erased")
        XCTAssertNotNil(saved.lastUnattendedPasswordAt, "the password moment was erased")

        await atPage.open()
        let outcome = await renewal.value
        XCTAssertEqual(outcome.label, "verificationPending")
        let next = await client.recover(.findMyRejected)
        XCTAssertEqual(next.label, "renewedRecently", "the client's own record lost the password moment")
    }

    /// Sign-out can run while the session hears that Find My's page is
    /// about to open. The page then opens for nobody: no password goes out.
    func testASignOutAsThePageOpensSendsNoPassword() async throws {
        let (storage, storedData) = storageInMemory()
        await storage.save(stored())
        let transport = ScriptedTransport()
        let authorizer = ScriptedWebAuthorizer()
        let client = ICloudAuthClient(transport: transport, storage: storage, webAuthorizer: authorizer)
        _ = await client.recover(.launch)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        let atHook = AsyncGate()

        let renewal = Task { await client.recover(.findMyRejected, willSignIn: { await atHook.wait() }) }
        await atHook.waitUntilWaiting()
        try await client.signOut()
        await atHook.open()
        let outcome = await renewal.value

        XCTAssertEqual(outcome.label, "superseded")
        XCTAssertTrue(authorizer.attempts.isEmpty)
        XCTAssertNil(storedData())
    }

    /// A sign-out while the page is open leaves the jar it cleared empty:
    /// the old account's cookies from the page are not installed.
    func testASignOutDuringThePageInstallsNoCookies() async throws {
        let (storage, storedData) = storageInMemory()
        await storage.save(stored())
        let transport = ScriptedTransport()
        let authorizer = ScriptedWebAuthorizer()
        authorizer.produce([rotatedCookie()])
        let client = ICloudAuthClient(transport: transport, storage: storage, webAuthorizer: authorizer)
        _ = await client.recover(.launch)
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        let atPage = AsyncGate()
        authorizer.whileAuthorizing { await atPage.wait() }

        let renewal = Task { await client.recover(.findMyRejected) }
        await atPage.waitUntilWaiting()
        try await client.signOut()
        await atPage.open()
        let outcome = await renewal.value

        XCTAssertEqual(outcome.label, "superseded")
        XCTAssertTrue(transport.allCookies().isEmpty)
        XCTAssertNil(storedData())
    }
}
