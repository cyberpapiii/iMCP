import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

/// The live session outlives the snapshot that restores it. Apple rotates the
/// web-auth cookies on ordinary Find My calls, and only the in-memory jar sees
/// that, so a snapshot written once at sign-in is what makes a reboot a day
/// later end in "sign in again".
final class ICloudCookiePersistenceTests: XCTestCase {
    private func storedCredentials(cookies: [ICloudStoredCookie]) -> ICloudCredentials {
        ICloudCredentials(
            accountName: "user@example.com",
            accountCountry: "USA",
            sessionToken: "stored-token",
            trustToken: "stored-trust",
            webAuthToken: "webauth",
            webAuthUser: "webuser",
            trustedAt: Date().addingTimeInterval(-3_600),
            dsid: "12345",
            webservices: ["findme": URL(string: "https://p42-fmipweb.icloud.com:443")!],
            cookies: cookies
        )
    }

    private func cookie(_ name: String, _ value: String, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: ".icloud.com", .path: "/",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testClearingADeadSessionRemovesFindMyHostCookiesToo() {
        let transport = ICloudHTTPClient()
        let home = HTTPCookie(properties: [
            .name: "home", .value: "value", .domain: ".icloud.com", .path: "/",
        ])!
        let findMy = HTTPCookie(properties: [
            .name: "find-my", .value: "value", .domain: "p42-fmipweb.icloud.com", .path: "/",
        ])!
        let findMyURL = URL(string: "https://p42-fmipweb.icloud.com")!
        transport.setCookies([home], for: ICloudEndpoint.home)
        transport.setCookies([findMy], for: findMyURL)

        transport.clearCookies()

        XCTAssertTrue(transport.cookies(for: ICloudEndpoint.home).isEmpty)
        XCTAssertTrue(transport.cookies(for: findMyURL).isEmpty)
    }

    /// The stored form has no Secure flag, so restore has to put it back for
    /// both the saved jar and the two-cookie fallback older snapshots use.
    func testRestoredCookiesAreSecure() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(storedCredentials(cookies: [storedWebAuthCookie("v")]))
        _ = await ICloudAuthClient(transport: transport, storage: storage).recover(.launch)

        XCTAssertFalse(transport.allCookies().isEmpty)
        XCTAssertTrue(transport.allCookies().allSatisfy(\.isSecure))

        let fallbackTransport = ScriptedTransport()
        let (fallbackStorage, _) = storageInMemory()
        await fallbackStorage.save(storedCredentials(cookies: []))
        fallbackTransport.stub("validate", json: accountLoginBody())
        _ = await ICloudAuthClient(transport: fallbackTransport, storage: fallbackStorage).recover(.launch)

        XCTAssertFalse(fallbackTransport.allCookies().isEmpty)
        XCTAssertTrue(fallbackTransport.allCookies().allSatisfy(\.isSecure))
    }

    func testFindMyHostCookiesSurvivePersistenceAndRestore() async throws {
        let transport = ICloudHTTPClient()
        let (storage, storedData) = storageInMemory()
        await storage.save(
            storedCredentials(cookies: [
                ICloudStoredCookie(
                    name: "session",
                    value: "same-value",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ])
        )
        let home = HTTPCookie(properties: [
            .name: "session", .value: "same-value", .domain: ".icloud.com", .path: "/",
        ])!
        let findMy = HTTPCookie(properties: [
            .name: "session", .value: "same-value", .domain: "p42-fmipweb.icloud.com", .path: "/",
        ])!
        let findMyURL = URL(string: "https://p42-fmipweb.icloud.com")!
        transport.setCookies([home], for: ICloudEndpoint.home)
        transport.setCookies([findMy], for: findMyURL)
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let didPersist = await client.persistRotatedCookies()
        XCTAssertTrue(didPersist)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.cookies?.count, 2)

        let restoredTransport = ICloudHTTPClient()
        let restoredClient = ICloudAuthClient(transport: restoredTransport, storage: storage)
        _ = await restoredClient.recover(.launch)

        XCTAssertEqual(restoredTransport.cookies(for: findMyURL).filter { $0.name == "session" }.count, 2)
        XCTAssertEqual(restoredTransport.allCookies().count, 2)
    }

    func testRotatedCookiesAreWrittenBackWithTheSameTokens() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(
            storedCredentials(cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "old",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ])
        )
        let later = Date(timeIntervalSince1970: 5_000)
        transport.setCookies(
            [cookie("X-APPLE-WEBAUTH-TOKEN", "new", expires: later.addingTimeInterval(86_400))],
            for: ICloudEndpoint.home
        )
        let client = ICloudAuthClient(transport: transport, storage: storage, now: { later })

        let didWrite = await client.persistRotatedCookies()

        XCTAssertTrue(didWrite)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.cookies?.map(\.value), ["new"])
        XCTAssertEqual(saved.webAuthToken, "new")
        XCTAssertEqual(saved.sessionToken, "stored-token")
        XCTAssertEqual(saved.trustToken, "stored-trust")
        XCTAssertNotNil(saved.trustedAt)
        XCTAssertEqual(saved.updatedAt, later)
        XCTAssertNotNil(saved.storedAccount(asOf: later))
    }

    /// Saving a rotated jar is routine; ending a recovery episode is a
    /// decision about Apple's answer. Only the second may drop the markers.
    func testARotationWriteLeavesTheRecoveryMarkersAlone() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        var credentials = storedCredentials(cookies: [storedWebAuthCookie("old")])
        credentials.lastAutomaticReauthenticationAt = Date(timeIntervalSince1970: 1_000)
        credentials.accountRepairPending = true
        await storage.save(credentials)
        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "new")], for: ICloudEndpoint.home)
        let client = ICloudAuthClient(transport: transport, storage: storage)
        func saved() throws -> ICloudCredentials {
            try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        }

        let rotated = await client.persistRotatedCookies()
        XCTAssertTrue(rotated)
        XCTAssertEqual(try saved().cookies?.map(\.value), ["new"])
        XCTAssertNotNil(try saved().lastAutomaticReauthenticationAt)
        XCTAssertEqual(try saved().accountRepairPending, true)

        let endedWithoutGuard = await client.endRecoveryEpisode(disarmingPasswordGuard: false)
        XCTAssertTrue(endedWithoutGuard)
        XCTAssertEqual(try saved().accountRepairPending, false)
        XCTAssertNotNil(try saved().lastAutomaticReauthenticationAt)

        let ended = await client.endRecoveryEpisode(disarmingPasswordGuard: true)
        XCTAssertTrue(ended)
        XCTAssertNil(try saved().lastAutomaticReauthenticationAt)
    }

    func testAnUnchangedJarIsNotRewritten() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(
            storedCredentials(cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "same",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ])
        )
        let before = storedData()
        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "same")], for: ICloudEndpoint.home)
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let didWrite = await client.persistRotatedCookies()

        XCTAssertFalse(didWrite)
        XCTAssertEqual(storedData(), before)
    }

    /// An empty jar is what a transport looks like before any call has run,
    /// not what Apple told us. Writing it would erase the only good copy.
    func testAnEmptyJarNeverOverwritesTheSnapshot() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(
            storedCredentials(cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "keep",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ])
        )
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let didWrite = await client.persistRotatedCookies()

        XCTAssertFalse(didWrite)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertEqual(saved.cookies?.map(\.value), ["keep"])
    }

    func testNothingIsWrittenWhenThereIsNoStoredSession() async {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "new")], for: ICloudEndpoint.home)
        let client = ICloudAuthClient(transport: transport, storage: storage)

        let didWrite = await client.persistRotatedCookies()

        XCTAssertFalse(didWrite)
        XCTAssertNil(storedData())
    }

    /// A Find My call that Apple accepted is the moment the jar may have
    /// moved, so it is also the moment the session writes it down.
    @MainActor
    func testASuccessfulFindMyCallPersistsTheRotatedJar() async throws {
        let transport = ScriptedTransport()
        let (storage, storedData) = storageInMemory()
        await storage.save(
            storedCredentials(cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "old",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ])
        )
        transport.stub(
            "initClient",
            json: [
                "serverContext": ["x": 1],
                "content": [["id": "d1", "name": "Phone", "deviceClass": "iPhone", "thisDevice": false]],
            ]
        )
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        XCTAssertTrue(session.isSignedIn)
        // The transport's jar changes as if Apple had rotated it on the call.
        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "rotated")], for: ICloudEndpoint.home)

        _ = try await XCTUnwrap(session.findMy).snapshot()

        // The call returns only after the session has heard of it.
        try assertStored("rotated", storedData)
    }

    /// Apple rotates a cookie on every Find My call. Two calls inside the
    /// write window cost one Keychain write, and the second rotation is
    /// still written once the window closes.
    @MainActor
    func testRotationsInsideTheWriteWindowCoalesceIntoOneTrailingWrite() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        let storedData = { keychain.data }
        await storage.save(storedCredentials(cookies: [storedWebAuthCookie("old")]))
        // Replies are one-shot: one initClient, then a refreshClient per snapshot.
        for path in ["initClient", "refreshClient", "refreshClient", "refreshClient"] {
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
        XCTAssertTrue(session.isSignedIn)
        let findMy = try XCTUnwrap(session.findMy)

        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "first")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        try assertStored("first", storedData)
        let writesAfterFirst = keychain.saves

        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "second")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "third")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        await session.advance(clock, by: 59)
        XCTAssertEqual(keychain.saves, writesAfterFirst, "a rotation inside the window must not write yet")

        await session.advance(clock, by: 1)
        try assertStored("third", storedData)
        XCTAssertEqual(keychain.saves, writesAfterFirst + 1, "both rotations share one trailing write")
    }

    /// Quit must not wait out the window: the pending rotation is written now.
    @MainActor
    func testFlushWritesAPendingRotationImmediately() async throws {
        let transport = ScriptedTransport()
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        let storedData = { keychain.data }
        await storage.save(storedCredentials(cookies: [storedWebAuthCookie("old")]))
        // Replies are one-shot: one initClient, then a refreshClient per snapshot.
        for path in ["initClient", "refreshClient", "refreshClient", "refreshClient"] {
            transport.stub(
                path,
                json: [
                    "serverContext": ["x": 1],
                    "content": [["id": "d1", "name": "Phone", "deviceClass": "iPhone", "thisDevice": false]],
                ]
            )
        }
        let session = ICloudSession(transport: transport, storage: storage, cookieWriteInterval: 60)
        await session.restoreIfNeeded()
        let findMy = try XCTUnwrap(session.findMy)

        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "first")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        try assertStored("first", storedData)
        transport.setCookies([cookie("X-APPLE-WEBAUTH-TOKEN", "second")], for: ICloudEndpoint.home)
        _ = try await findMy.snapshot()
        await session.settle()
        let writesBeforeFlush = keychain.saves

        await session.flushCookies()

        XCTAssertEqual(keychain.saves, writesBeforeFlush + 1)
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertTrue(saved.cookies?.contains { $0.value == "second" } ?? false)
    }

    private func assertStored(
        _ value: String,
        _ storedData: () -> Data?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let saved = try JSONDecoder().decode(ICloudCredentials.self, from: try XCTUnwrap(storedData()))
        XCTAssertTrue(
            saved.cookies?.contains { $0.value == value } ?? false,
            "cookie \(value) was not written",
            file: file,
            line: line
        )
    }

    @MainActor
    func testARejectedAccountLoginRecordsWhyTheSessionDied() async {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            storedCredentials(cookies: [
                ICloudStoredCookie(
                    name: "X-APPLE-WEBAUTH-TOKEN",
                    value: "old",
                    domain: ".icloud.com",
                    path: "/",
                    expiresAt: nil
                )
            ])
        )
        transport.stub("validate", status: 421)
        let session = ICloudSession(transport: transport, storage: storage)
        await session.restoreIfNeeded()
        XCTAssertTrue(session.isSignedIn)

        let refreshed = await session.renewRejectedClient()

        XCTAssertNil(refreshed)
        XCTAssertEqual(session.state, .needsReauthentication)
        guard case .appleRejectedStoredSession = session.lastInvalidationReason else {
            return XCTFail("expected an Apple rejection, got \(String(describing: session.lastInvalidationReason))")
        }
    }
}
