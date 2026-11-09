import Foundation
import XCTest

@testable import iMCP

/// Stands in for the network so the real `URLSession`, its redirect delegate,
/// and its cookie jar are all exercised. Only the socket is fake.
final class ICloudStubProtocol: URLProtocol {
    struct Reply {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requestedURLs: [URL] = []

    static func stub(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    static func reset() {
        lock.withLock {
            replies = [:]
            requestedURLs = []
        }
    }

    static var requested: [URL] {
        lock.withLock { requestedURLs }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.requestedURLs.append(url) }
        let reply =
            Self.lock.withLock { Self.replies[url.absoluteString] }
            ?? Reply(statusCode: 404, headers: [:], body: Data())
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ICloudHTTPClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ICloudStubProtocol.reset()
    }

    /// The whole reason this client exists. Apple returns the session token and
    /// `scnt` on a 302; following the redirect throws that response away and
    /// the sign-in fails with no visible cause.
    func testRedirectsAreNotFollowedSoAuthHeadersSurvive() async throws {
        ICloudStubProtocol.stub(
            "https://idmsa.apple.com/appleauth/auth/signin/complete",
            .init(
                statusCode: 302,
                headers: [
                    "Location": "https://www.icloud.com/",
                    "X-Apple-Session-Token": "session-token-value",
                    "scnt": "scnt-value",
                ],
                body: Data()
            )
        )
        ICloudStubProtocol.stub(
            "https://www.icloud.com/",
            .init(statusCode: 200, headers: [:], body: Data())
        )

        let client = ICloudHTTPClient(protocolClasses: [ICloudStubProtocol.self])
        let url = URL(string: "https://idmsa.apple.com/appleauth/auth/signin/complete")!
        let response = try await client.send(URLRequest(url: url))

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.header("X-Apple-Session-Token"), "session-token-value")
        XCTAssertEqual(ICloudStubProtocol.requested, [url])
    }

    /// Apple sends `scnt` lowercase and the rest capitalized, and URLSession
    /// may recase either.
    func testHeaderLookupIsCaseInsensitive() {
        let response = ICloudHTTPResponse(
            statusCode: 200,
            headers: ["SCNT": "value"],
            body: Data()
        )
        XCTAssertEqual(response.header("scnt"), "value")
        XCTAssertNil(response.header("X-Apple-Session-Token"))
    }

    /// Apple's auth cookies authenticate every later service call. In
    /// `HTTPCookieStorage.shared` they would ride along on unrelated requests
    /// from elsewhere in the process, and anything else in the process could
    /// read them back out.
    func testCookiesStayOutOfTheSharedJar() throws {
        let url = URL(string: "https://idmsa.apple.com/appleauth/auth/signin/init")!
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "X-APPLE-WEBAUTH-TOKEN",
                .value: "secret",
                .domain: "idmsa.apple.com",
                .path: "/",
            ])
        )

        let client = ICloudHTTPClient(protocolClasses: [ICloudStubProtocol.self])
        client.setCookies([cookie], for: url)

        XCTAssertEqual(client.cookies(for: url).map(\.name), ["X-APPLE-WEBAUTH-TOKEN"])
        XCTAssertEqual(client.allCookies().map(\.name), ["X-APPLE-WEBAUTH-TOKEN"])
        XCTAssertFalse(
            HTTPCookieStorage.shared.cookies(for: url)?
                .contains { $0.name == "X-APPLE-WEBAUTH-TOKEN" } ?? false
        )

        // A second client must not inherit the first client's session.
        let other = ICloudHTTPClient(protocolClasses: [ICloudStubProtocol.self])
        XCTAssertTrue(other.cookies(for: url).isEmpty)
        XCTAssertTrue(other.allCookies().isEmpty)
    }

    /// The iCloud homepage is Apple's source of truth for the service-client
    /// identifiers. A stale bundled value makes valid Find My cookies answer 450.
    func testPublishedWebBuildDrivesFindMyRequest() async throws {
        let homepage = """
            <!doctype html><html data-cw-private-build-number="2640Build24" \
            data-cw-private-mastering-number="2640Build24"></html>
            """
        ICloudStubProtocol.stub(
            "https://www.icloud.com/",
            .init(statusCode: 200, headers: [:], body: Data(homepage.utf8))
        )
        let findMyURL =
            "https://p1-fmipweb.icloud.com/fmipservice/client/web/initClient"
            + "?clientBuildNumber=2640Build24&clientMasteringNumber=2640Build24"
            + "&clientId=client-id&dsid=1234"
        let body = try JSONSerialization.data(withJSONObject: [
            "serverContext": ["prsId": 1234],
            "content": [["id": "phone", "name": "Phone"]],
        ])
        ICloudStubProtocol.stub(
            findMyURL,
            .init(statusCode: 200, headers: [:], body: body)
        )

        let transport = ICloudHTTPClient(protocolClasses: [ICloudStubProtocol.self])
        let client = FindMyClient(
            transport: transport,
            account: try! ICloudAccount(
                dsid: "1234",
                webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
            ),
            clientID: "client-id"
        )

        let snapshot = try await client.snapshot()

        XCTAssertEqual(snapshot.devices.map(\.id), ["phone"])
        XCTAssertEqual(
            ICloudStubProtocol.requested.map(\.absoluteString),
            [ICloudEndpoint.home.appending(path: "").absoluteString, findMyURL]
        )
    }

    /// Apple serves China-partition accounts from `icloud.com.cn`. Their
    /// cookies have to reach Find My's own sign-in page just as the endpoints
    /// on that domain are accepted, or the page starts without a session.
    func testChinaPartitionCookiesAndEndpointsAreBothApples() throws {
        func cookie(_ domain: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [.name: "c", .value: "v", .domain: domain, .path: "/"]))
        }
        for domain in [".icloud.com.cn", "p42-fmipweb.icloud.com.cn", ".icloud.com", "idmsa.apple.com"] {
            XCTAssertTrue(AppleDomain.isSessionCookie(try cookie(domain)), domain)
        }
        for domain in ["evilicloud.com", "icloud.com.evil.net", ".example.com"] {
            XCTAssertFalse(AppleDomain.isSessionCookie(try cookie(domain)), domain)
        }
        XCTAssertTrue(AppleDomain.isServiceURL(try XCTUnwrap(URL(string: "https://p42-fmipweb.icloud.com.cn"))))
        XCTAssertFalse(AppleDomain.isServiceURL(try XCTUnwrap(URL(string: "https://icloud.com.cn"))))
    }

    /// Find My's page signs in on a copy of the session's jar. What it leaves
    /// behind has to land back in the jar the next Find My call sends.
    func testFindMyAuthorizationCookiesLandInTheSessionJar() async throws {
        let transport = ScriptedTransport()
        let (storage, _) = storageInMemory()
        await storage.save(
            ICloudCredentials(
                accountName: "user@example.com",
                accountCountry: "USA",
                sessionToken: "token",
                trustToken: "trust",
                webAuthToken: nil,
                webAuthUser: nil,
                trustedAt: Date(),
                cookies: [storedWebAuthCookie("live")],
                password: "pw"
            )
        )
        let authorizer = ScriptedWebAuthorizer()
        let fmip = try XCTUnwrap(
            HTTPCookie(properties: [.name: "X-APPLE-WEBAUTH-FMIP", .value: "f", .domain: ".icloud.com", .path: "/"])
        )
        authorizer.produce([fmip])
        transport.stub("validate", json: accountLoginBody())
        transport.stub("initClient", status: 450)
        transport.stub("initClient", status: 450)
        transport.stub("validate", json: accountLoginBody())
        let client = ICloudAuthClient(transport: transport, storage: storage, webAuthorizer: authorizer)

        _ = await client.recover(.findMyRejected)

        let attempt = try XCTUnwrap(authorizer.attempts.first)
        XCTAssertEqual(attempt.cookies.map(\.name), ["X-APPLE-WEBAUTH-TOKEN"])
        XCTAssertTrue(transport.allCookies().contains { $0.name == "X-APPLE-WEBAUTH-FMIP" })
    }
}
