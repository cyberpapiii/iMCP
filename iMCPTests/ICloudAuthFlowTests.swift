import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

final class ICloudAuthFlowTests: XCTestCase {
    func testPasswordOnlySignInReachesAccountLogin() async throws {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub(
            "signin/init",
            headers: ["X-Apple-ID-Session-Id": "session-1"],
            json: challengeBody
        )
        transport.stub(
            "signin/complete",
            headers: [
                "X-Apple-Session-Token": "session-token",
                "X-Apple-ID-Account-Country": "USA",
            ]
        )
        transport.stub("accountLogin", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = try await client.signIn(accountName: "user@example.com", password: "pw")

        guard case .signedIn(let account) = outcome else {
            return XCTFail("expected a completed sign-in, got \(outcome)")
        }
        XCTAssertEqual(account.dsid, "12345")
        XCTAssertEqual(account.findMy.host, "p42-fmipweb.icloud.com")

        // The session token is what a later launch replays, so it has to reach
        // the Keychain rather than living only in memory.
        let saved = try XCTUnwrap(stored())
        let credentials = try JSONDecoder().decode(ICloudCredentials.self, from: saved)
        XCTAssertEqual(credentials.sessionToken, "session-token")
        XCTAssertEqual(credentials.accountCountry, "USA")
        XCTAssertEqual(credentials.accountName, "user@example.com")
    }

    /// Apple drops the flow when `scnt` or the session id is missing from a
    /// later step, and the failure looks like a wrong password.
    func testSessionHeadersAreEchoedOnEveryLaterStep() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub(
            "signin/init",
            headers: ["X-Apple-ID-Session-Id": "session-1"],
            json: challengeBody
        )
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")

        let complete = try XCTUnwrap(transport.requests(matching: "signin/complete").first)
        XCTAssertEqual(complete.header("scnt"), "scnt-1")
        XCTAssertEqual(complete.header("X-Apple-ID-Session-Id"), "session-1")
        XCTAssertEqual(complete.header("X-Apple-Widget-Key"), ICloudEndpoint.widgetKey)

        let initial = try XCTUnwrap(transport.requests(matching: "signin/init").first)
        XCTAssertEqual(initial.json["accountName"] as? String, "user@example.com")
        XCTAssertEqual(
            initial.json["protocols"] as? [String],
            SRPPasswordProtocol.offered
        )
    }

    func testTwoFactorAccountStopsForACodeThenTrustsTheSession() async throws {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub(
            "signin/init",
            headers: ["X-Apple-ID-Session-Id": "session-1"],
            json: challengeBody
        )
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub("appleauth/auth", json: ["trustedPhoneNumbers": []])
        transport.stub("verify/trusteddevice", json: [String: Any]())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = try await client.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertEqual(outcome, .needsTwoFactorCode(.trustedDevice))
        XCTAssertNil(stored(), "nothing is persisted until the code is verified")

        transport.stub(
            "verify/trusteddevice/securitycode",
            headers: ["X-Apple-TwoSV-Trust-Token": "trust-token"]
        )
        transport.stub("2sv/trust", headers: ["X-Apple-Session-Token": "session-token"])
        transport.stub("accountLogin", json: accountLoginBody())

        let account = try await client.submitTwoFactorCode("123456")
        XCTAssertEqual(account.dsid, "12345")

        let verify = try XCTUnwrap(
            transport.requests(matching: "verify/trusteddevice/securitycode").first
        )
        XCTAssertEqual((verify.json["securityCode"] as? [String: Any])?["code"] as? String, "123456")

        let saved = try XCTUnwrap(stored())
        let credentials = try JSONDecoder().decode(ICloudCredentials.self, from: saved)
        XCTAssertEqual(credentials.trustToken, "trust-token")
        XCTAssertEqual(credentials.sessionToken, "session-token")
    }

    func testRejectedCodeIsReportedAsSuchAndNotAsAWrongPassword() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub("appleauth/auth", json: [String: Any]())
        transport.stub("verify/trusteddevice", json: [String: Any]())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")

        transport.stub("verify/trusteddevice/securitycode", status: 400)
        do {
            _ = try await client.submitTwoFactorCode("000000")
            XCTFail("expected the rejected code to throw")
        } catch let error as ICloudAuthError {
            XCTAssertEqual(error, .twoFactorCodeRejected)
        }
    }

    func testWrongPasswordIsNotMistakenForATwoFactorPrompt() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 401, json: ["authType": "hsa2"])

        let client = ICloudAuthClient(transport: transport, storage: storage)
        do {
            _ = try await client.signIn(accountName: "user@example.com", password: "wrong")
            XCTFail("expected the wrong password to throw")
        } catch let error as ICloudAuthError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }

    /// What a sign-in throws when the two SRP calls, `signin/init` and
    /// `signin/complete`, answer with the given challenge and statuses.
    private func signInError(
        challenge: [String: Any] = challengeBody,
        initStatus: Int = 200,
        completeStatus: Int = 200
    ) async -> (ICloudAuthError?, ScriptedTransport) {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", status: initStatus, json: challenge)
        transport.stub("signin/complete", status: completeStatus)
        let client = ICloudAuthClient(transport: transport, storage: storage)
        do {
            _ = try await client.signIn(accountName: "user@example.com", password: "pw")
            return (nil, transport)
        } catch {
            return (error as? ICloudAuthError, transport)
        }
    }

    /// Only 401 says the password was wrong. Any other refusal ends the
    /// attempt without telling the user to doubt a password that may be fine.
    func testAnUnexpectedStatusIsNotCalledAWrongPassword() async {
        let (onComplete, _) = await signInError(completeStatus: 403)
        XCTAssertEqual(onComplete, .appleRejectedRequest(status: 403))

        let (onInit, _) = await signInError(initStatus: 400)
        XCTAssertEqual(onInit, .appleRejectedRequest(status: 400))
    }

    func testAnUndecodableChallengeIsUnreadableNotAWrongPassword() async {
        var badSalt = challengeBody
        badSalt["salt"] = "not base64!"
        let (saltError, saltTransport) = await signInError(challenge: badSalt)
        XCTAssertEqual(saltError, .unreadableResponse)
        XCTAssertTrue(saltTransport.requests(matching: "signin/complete").isEmpty)

        var unknownProtocol = challengeBody
        unknownProtocol["protocol"] = "s3k"
        let (protocolError, protocolTransport) = await signInError(challenge: unknownProtocol)
        XCTAssertEqual(protocolError, .unreadableResponse)
        XCTAssertTrue(protocolTransport.requests(matching: "signin/complete").isEmpty)
    }

    /// An account with Advanced Data Protection on and web access off signs in
    /// fine and then has no Find My endpoint. A generic error there sends the
    /// user looking at their password instead of at the one setting that fixes
    /// it.
    func testMissingFindMyEndpointIsReportedAsWebAccessDisabled() async throws {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody(includeFindMy: false))

        let client = ICloudAuthClient(transport: transport, storage: storage)
        do {
            _ = try await client.signIn(accountName: "user@example.com", password: "pw")
            XCTFail("expected the missing endpoint to throw")
        } catch let error as ICloudAuthError {
            XCTAssertEqual(error, .webAccessDisabled)
            XCTAssertTrue(error.errorDescription?.contains("Access iCloud Data on the Web") == true)
        }
        XCTAssertNil(stored(), "a session that cannot answer Find My is not worth storing")
    }

    func testSessionValidationStopsWhenAppleRequiresUpdatedTerms() async throws {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: "webauth",
                webAuthUser: "webuser",
                trustedAt: Date()
            )
        )
        var body = accountLoginBody()
        body["termsUpdateNeeded"] = true
        transport.stub("validate", json: body)

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = await client.recover(.launch)
        XCTAssertEqual(outcome.label, "accountRepairRequired", "expected pending terms to stop session validation")
        XCTAssertTrue(ICloudAuthError.accountRepairRequired.errorDescription?.contains("updated iCloud terms") == true)

        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(stored()))
        XCTAssertNil(saved.dsid, "an account behind a repair gate must not replace the usable snapshot")
    }

    func testSMSFallbackAsksForACodeAndVerifiesAgainstThatNumber() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub(
            "appleauth/auth",
            json: ["trustedPhoneNumbers": [["id": 7, "numberWithDialCode": "+1 (•••) •••-••12"]]]
        )
        // No other Apple device to push to.
        transport.stub("verify/trusteddevice", status: 412)
        transport.stub("verify/phone", json: [String: Any]())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = try await client.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertEqual(
            outcome,
            .needsTwoFactorCode(.sms(maskedNumber: "+1 (•••) •••-••12", phoneNumberID: 7))
        )

        transport.stub("verify/phone/securitycode")
        transport.stub("2sv/trust", headers: ["X-Apple-Session-Token": "session-token"])
        transport.stub("accountLogin", json: accountLoginBody())
        _ = try await client.submitTwoFactorCode("654321")

        let verify = try XCTUnwrap(transport.requests(matching: "verify/phone/securitycode").first)
        XCTAssertEqual((verify.json["phoneNumber"] as? [String: Any])?["id"] as? Int, 7)
        XCTAssertEqual(verify.json["mode"] as? String, "sms")
    }

    /// Apple serves the two-factor options as an HTML shell. Asking it for
    /// JSON returns an SMS-shaped subset that hides the trusted phone numbers,
    /// so the request has to say `text/html` and the state has to be read out
    /// of the page's `boot_args`.
    func testTwoFactorOptionsAreReadFromTheHTMLShell() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        let bootArguments: [String: Any] = [
            "direct": [
                "authInitialRoute": "auth/bridge/step",
                "twoSV": [
                    "phoneNumberVerification": [
                        "trustedPhoneNumbers": [
                            ["id": 3, "numberWithDialCode": "+1 (•••) •••-••34"]
                        ]
                    ]
                ],
                "trustedPhoneNumbers": [["id": 3, "numberWithDialCode": "+1 (•••) •••-••34"]],
            ]
        ]
        let json = String(
            data: try JSONSerialization.data(withJSONObject: bootArguments),
            encoding: .utf8
        )!
        transport.stubRaw(
            "appleauth/auth",
            body: "<html><head><script type=\"application/json\" class=\"boot_args\">\(json)</script></head></html>"
        )
        transport.stub("verify/trusteddevice", status: 412)
        transport.stub("verify/phone", json: [String: Any]())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = try await client.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertEqual(
            outcome,
            .needsTwoFactorCode(.sms(maskedNumber: "+1 (•••) •••-••34", phoneNumberID: 3))
        )

        let options = try XCTUnwrap(
            transport.recorded.first { $0.path.hasSuffix("/appleauth/auth") }
        )
        XCTAssertEqual(options.header("Accept"), "text/html")
    }

    /// 421 is Apple saying the session no longer exists. Reporting it as a bad
    /// code would send the user back to a field that can never succeed.
    func testInvalidatedSessionIsReportedSeparatelyFromABadCode() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", status: 409, json: ["authType": "hsa2"])
        transport.stub("appleauth/auth", json: [String: Any]())
        transport.stub("verify/trusteddevice", json: [String: Any]())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")

        transport.stub("verify/trusteddevice/securitycode", status: 421)
        do {
            _ = try await client.submitTwoFactorCode("123456")
            XCTFail("an invalidated session must not look like a completed sign-in")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .sessionExpired)
        }
    }

    func testRestoreValidatesStoredCookiesWithoutAPasswordSignIn() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: "webauth",
                webAuthUser: "webuser",
                trustedAt: Date()
            )
        )
        transport.stub("validate", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = await client.recover(.launch)
        let account = try XCTUnwrap(outcome.account)
        XCTAssertEqual(account.dsid, "12345")

        let validation = try XCTUnwrap(transport.requests(matching: "validate").first)
        XCTAssertEqual(String(data: try XCTUnwrap(validation.request.httpBody), encoding: .utf8), "null")
        XCTAssertTrue(transport.requests(matching: "accountLogin").isEmpty)
        XCTAssertTrue(transport.requests(matching: "signin").isEmpty)
        XCTAssertEqual(
            transport.cookies(for: ICloudEndpoint.home).map(\.name).sorted(),
            ["X-APPLE-WEBAUTH-TOKEN", "X-APPLE-WEBAUTH-USER"]
        )
    }

    /// A relaunch with a complete snapshot needs no network authentication.
    func testRestoreWithCachedEndpointsSkipsNetworkAuthentication() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: "webauth",
                webAuthUser: "webuser",
                trustedAt: Date(),
                dsid: "12345",
                webservices: ["findme": URL(string: "https://p42-fmipweb.icloud.com:443")!],
                cookies: [
                    ICloudStoredCookie(
                        name: "X-APPLE-WEBAUTH-VALIDATE",
                        value: "validate",
                        domain: ".icloud.com",
                        path: "/",
                        expiresAt: nil
                    )
                ]
            )
        )

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = await client.recover(.launch)
        let account = try XCTUnwrap(outcome.account)

        XCTAssertEqual(account.dsid, "12345")
        XCTAssertNotNil(account.findMy)
        XCTAssertTrue(transport.requests(matching: "accountLogin").isEmpty)
        XCTAssertTrue(transport.requests(matching: "validate").isEmpty)
        XCTAssertEqual(
            transport.cookies(for: ICloudEndpoint.home).map(\.name),
            ["X-APPLE-WEBAUTH-VALIDATE"]
        )
    }

    /// Endpoints without the jar that authenticates against them make Apple
    /// answer 450, which reads to the user as an expired session.
    func testRestoreWithoutTheWholeCookieJarUsesValidation() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: "webauth",
                webAuthUser: "webuser",
                trustedAt: Date(),
                dsid: "12345",
                webservices: ["findme": URL(string: "https://p42-fmipweb.icloud.com:443")!],
                cookies: []
            )
        )
        transport.stub("validate", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = await client.recover(.launch)

        XCTAssertEqual(transport.requests(matching: "validate").count, 1)
        XCTAssertTrue(transport.requests(matching: "accountLogin").isEmpty)
    }

    func testValidationKeepsTheWholeCookieJarForTheNextLaunch() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: "webauth",
                webAuthUser: "webuser",
                trustedAt: Date()
            )
        )
        transport.stub("validate", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = await client.recover(.launch)

        let saved = try JSONDecoder().decode(
            ICloudCredentials.self,
            from: try XCTUnwrap(storedData())
        )
        XCTAssertEqual(saved.dsid, "12345")
        XCTAssertNotNil(saved.webservices?["findme"])
        XCTAssertEqual(
            saved.cookies?.map(\.name).sorted(),
            ["X-APPLE-WEBAUTH-TOKEN", "X-APPLE-WEBAUTH-USER"]
        )
        XCTAssertNotNil(saved.storedAccount(asOf: Date()))
    }

    /// Local age is diagnostic only. Apple decides whether a saved browser
    /// session still works, so an old trust token must not force a new sign-in.
    func testOldTrustDoesNotOverrideAUsableCachedSession() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        let old = Date(timeIntervalSinceNow: -(ICloudStatusCommandLine.trustLifetime + 60))
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "stored-token",
                trustToken: "stored-trust",
                webAuthToken: "webauth",
                webAuthUser: "webuser",
                trustedAt: old,
                dsid: "12345",
                webservices: ["findme": URL(string: "https://p42-fmipweb.icloud.com:443")!],
                cookies: [storedWebAuthCookie("live")]
            )
        )

        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = await client.recover(.launch)
        let account = try XCTUnwrap(outcome.account)

        XCTAssertEqual(account.dsid, "12345")
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    func testRestoreWithoutStoredCredentialsSaysSoExplicitly() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        let client = ICloudAuthClient(transport: transport, storage: storage)
        let outcome = await client.recover(.launch)
        XCTAssertEqual(outcome.label, "nothingStored", "expected the missing session to say so")
    }

    func testSignOutClearsTheStoredSession() async throws {
        let transport = ScriptedTransport()
        let (storage, stored) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertNotNil(stored())

        try await client.signOut()
        XCTAssertNil(stored())
    }

    /// The actor suspends while the Keychain saves a sign-in, so sign-out
    /// can run in between. Its delete is queued behind the save, and the
    /// superseded sign-in reports so instead of a session that is gone.
    func testSignOutWhileASignInIsSavingLeavesItSignedOut() async throws {
        let transport = ScriptedTransport()
        transport.stub("authorize/signin", headers: ["scnt": "scnt-1"])
        transport.stub("signin/init", headers: ["X-Apple-ID-Session-Id": "session-1"], json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "session-token"])
        transport.stub("accountLogin", json: accountLoginBody())
        let keychain = InMemoryKeychainItem()
        let gate = DispatchSemaphore(value: 0)
        keychain.saveGate = gate
        let client = ICloudAuthClient(transport: transport, storage: keychain.iCloudCredentialStorage)

        let signIn = Task { try await client.signIn(accountName: "user@example.com", password: "pw") }
        await keychain.waitForSaves()
        XCTAssertEqual(keychain.saves, 1, "the sign-in is saving")
        let signOut = Task { try await client.signOut() }
        try await Task.sleep(for: .milliseconds(50))
        keychain.saveGate = nil
        gate.signal()

        do {
            _ = try await signIn.value
            XCTFail("the sign-in finished after sign-out")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .authenticationSuperseded)
        }
        try await signOut.value
        XCTAssertNil(keychain.data, "the delete landed after the save")
        let accountName = await client.currentAccountName()
        XCTAssertNil(accountName)
    }

    func testSignOutEmptiesTheCookieJar() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "X-APPLE-WEBAUTH-TOKEN", .value: "live", .domain: ".icloud.com", .path: "/",
            ])
        )
        transport.setCookies([cookie], for: ICloudEndpoint.home)

        try await client.signOut()
        XCTAssertTrue(transport.allCookies().isEmpty)
    }

    func testAccountLoginKeepsOnlyAppleHTTPSEndpoints() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "dsInfo": ["dsid": "12345"],
            "webservices": [
                "findme": ["url": "https://p42-fmipweb.icloud.com:443"],
                "china": ["url": "https://p42-fmipweb.icloud.com.cn:443"],
                "plain": ["url": "http://p42-fmipweb.icloud.com"],
                "lookalike": ["url": "https://evilicloud.com"],
            ],
        ])

        let account = try ICloudAccount(accountLoginBody: body)

        XCTAssertEqual(Set(account.webservices.keys), ["findme", "china"])
    }

    func testRestoreWhenStorageIsUnreadableDoesNotLookSignedOut() async throws {
        let transport = ScriptedTransport()
        let client = ICloudAuthClient(
            transport: transport,
            storage: InMemoryKeychainItem(loadFailure: errSecAuthFailed).iCloudCredentialStorage
        )
        let outcome = await client.recover(.launch)
        XCTAssertEqual(outcome.label, "keychainUnreadable", "expected an unreadable session to say so")
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    func testAFailedSaveDoesNotLookLikeACompletedSignIn() async throws {
        let transport = ScriptedTransport()
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())

        let client = ICloudAuthClient(
            transport: transport,
            storage: InMemoryKeychainItem(failSave: true).iCloudCredentialStorage
        )
        do {
            _ = try await client.signIn(accountName: "user@example.com", password: "pw")
            XCTFail("expected a failed persist to throw")
        } catch let error as ICloudAuthError {
            XCTAssertEqual(error, .couldNotStoreSession)
        }
    }

    func testSignOutReportsAFailedClearAndKeepsTheTokens() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem(failDelete: true)
        let storage = keychain.iCloudCredentialStorage
        let stored = { keychain.data }
        transport.stub("authorize/signin")
        transport.stub("signin/init", json: challengeBody)
        transport.stub("signin/complete", headers: ["X-Apple-Session-Token": "t"])
        transport.stub("accountLogin", json: accountLoginBody())

        let client = ICloudAuthClient(transport: transport, storage: storage)
        _ = try await client.signIn(accountName: "user@example.com", password: "pw")
        XCTAssertNotNil(stored())

        do {
            try await client.signOut()
            XCTFail("expected a failed clear to throw")
        } catch let error as ICloudAuthError {
            XCTAssertEqual(error, .couldNotClearSession)
        }
        XCTAssertNotNil(stored())
    }

    /// Every one of these errors reaches an MCP client verbatim, so none may
    /// carry a path, a token, or an Apple error payload.
    func testAuthErrorsCrossTheToolBoundaryAsGuidance() {
        for error in [
            ICloudAuthError.invalidCredentials,
            .twoFactorCodeRejected,
            .noStoredSession,
            .credentialsUnreadable,
            .trustExpired,
            .webAccessDisabled,
            .couldNotStoreSession,
            .couldNotClearSession,
            .appleRejectedRequest(status: 503),
        ] {
            let message = sanitizedToolErrorMessage(for: error)
            XCTAssertEqual(message, error.errorDescription)
            XCTAssertFalse(message.contains("/Users/"))
            XCTAssertNotEqual(message, sanitizedToolErrorMessage(for: NSError(domain: "x", code: 1)))
        }
    }
}
