import Foundation
import OSLog

/// The public iCloud shell publishes these identifiers on its root element.
/// Apple rotates them independently of browser-session cookies and rejects
/// otherwise valid service requests that keep using a retired build.
struct ICloudWebClientVersion: Sendable, Equatable {
    let buildNumber: String
    let masteringNumber: String

    /// Last known good values. Used only when the public shell cannot be read.
    static let fallback = ICloudWebClientVersion(
        buildNumber: "2640Build24",
        masteringNumber: "2640Build24"
    )

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "clientBuildNumber", value: buildNumber),
            URLQueryItem(name: "clientMasteringNumber", value: masteringNumber),
        ]
    }

    init(buildNumber: String, masteringNumber: String) {
        self.buildNumber = buildNumber
        self.masteringNumber = masteringNumber
    }

    init?(homepage: Data) {
        guard let html = String(data: homepage, encoding: .utf8),
            let buildNumber = Self.attribute("data-cw-private-build-number", in: html),
            let masteringNumber = Self.attribute("data-cw-private-mastering-number", in: html),
            Self.isValid(buildNumber), Self.isValid(masteringNumber)
        else { return nil }
        self.init(buildNumber: buildNumber, masteringNumber: masteringNumber)
    }

    private static func attribute(_ name: String, in html: String) -> String? {
        let marker = name + "=\""
        guard let start = html.range(of: marker),
            let end = html[start.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return String(html[start.upperBound ..< end])
    }

    private static func isValid(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}

struct ICloudHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    var isSuccess: Bool { (200 ..< 300).contains(statusCode) }

    /// HTTP header names are case-insensitive, and Apple is not consistent
    /// about the casing of `scnt` in particular.
    func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

/// What Apple means by its two session statuses. The setup endpoints and Find
/// My both send them, and each needs a different remedy.
enum AppleSessionStatus: Equatable {
    /// 421: the browser session no longer exists.
    case browserSessionGone
    /// 450: on the setup endpoints it accompanies a dead session. On Find My
    /// it can instead mean a retired web build, or that only Find My's own
    /// authorization lapsed while the browser session lives on.
    case serviceAuthorizationLapsed

    init?(statusCode: Int) {
        switch statusCode {
        case 421: self = .browserSessionGone
        case 450: self = .serviceAuthorizationLapsed
        default: return nil
        }
    }
}

/// Which hosts are Apple's, for the cookies, endpoints, and pages a session
/// may touch. Apple serves China-partition accounts from `icloud.com.cn`.
enum AppleDomain {
    static let iCloud = ["icloud.com", "icloud.com.cn"]
    static let account = ["apple.com"]
    /// Hosts Apple's own web pages load from besides the account domains.
    static let webContent = ["cdn-apple.com", "apple-cloudkit.com"]

    /// A cookie domain's leading dot is ignored.
    static func contains(_ host: String, in domains: [String], subdomainsOnly: Bool = false) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { domain in
            host.hasSuffix(".\(domain)") || (!subdomainsOnly && host == domain)
        }
    }

    /// Service calls carry the session's cookies, so an endpoint is only
    /// taken when it is HTTPS on a subdomain of Apple's iCloud domain.
    static func isServiceURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host else { return false }
        return contains(host, in: iCloud, subdomainsOnly: true)
    }

    /// The cookies a sign-in may hand to, or take back from, Apple's pages.
    static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        contains(cookie.domain, in: account + iCloud)
    }
}

/// A request to one of iCloud's service endpoints — setup, Find My, and the
/// rest — as the iCloud web app makes it.
///
/// These are a different service from Apple's identity endpoints and reject the
/// identity service's OAuth and session headers, so they get nothing but what
/// the browser itself would send. Authentication rides on the cookies
/// iCloud's session bootstrap and validator set.
enum ICloudWebRequest {
    static func post(_ url: URL, body: [String: Any]) throws -> URLRequest {
        try post(url, encodedBody: JSONSerialization.data(withJSONObject: body))
    }

    /// Apple's cookie-session validator expects the JSON literal `null`, not
    /// an object. Keep that exceptional wire shape out of every other call.
    static func postNull(_ url: URL) -> URLRequest {
        post(url, encodedBody: Data("null".utf8))
    }

    private static func post(_ url: URL, encodedBody: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Origin": ICloudEndpoint.home.absoluteString,
            "Referer": ICloudEndpoint.home.absoluteString + "/",
        ] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = encodedBody
        return request
    }

    /// Every iCloud service call carries the web app's own client identifiers.
    /// Apple answers a request without them inconsistently.
    static func url(
        _ base: URL,
        path: String,
        version: ICloudWebClientVersion,
        clientID: String,
        extra: [URLQueryItem] = []
    ) -> URL {
        var url = base.appending(path: path)
        url.append(queryItems: version.queryItems + [URLQueryItem(name: "clientId", value: clientID)] + extra)
        return url
    }
}

/// HTTP and a cookie jar, nothing else. Production is `ICloudHTTPClient`;
/// tests substitute a scripted transport.
protocol ICloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ICloudHTTPResponse
    /// Current public iCloud service identifiers. Production reads them from
    /// Apple's shell; scripted transports can supply deterministic values.
    func iCloudWebClientVersion(forceRefresh: Bool) async -> ICloudWebClientVersion
    /// Every cookie in the isolated iCloud jar, including host-only service
    /// cookies a per-URL lookup omits for other hosts.
    func allCookies() -> [HTTPCookie]
    func setCookies(_ cookies: [HTTPCookie], for url: URL)
    /// Clears the isolated iCloud cookie jar, including host-only service cookies.
    func clearCookies()
}

extension ICloudHTTPTransport {
    /// Puts each cookie in the jar under its own domain, host-only cookies
    /// included, which a single `setCookies(_:for:)` URL would not cover.
    func install(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let url = URL(string: "https://\(host)\(cookie.path)") else { continue }
            setCookies([cookie], for: url)
        }
    }
}

/// Apple hands back the session token, `scnt`, and the web-auth cookies on 302
/// responses. `URLSession` follows redirects by default, and the intermediate
/// response is gone by the time the caller sees anything, headers included.
/// Returning `nil` here stops the redirect and hands back the 302 itself.
///
/// This is the pitfall that costs people days, so it is a named type rather
/// than a closure buried in the client.
final class ICloudRedirectSuppressor: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// A `URLSession` scoped to iCloud and nothing else.
///
/// The cookie jar is the session's own. Apple's auth cookies must not land in
/// `HTTPCookieStorage.shared`, where every other `URLSession` in the process
/// would send them.
final class ICloudHTTPClient: NSObject, ICloudHTTPTransport, @unchecked Sendable {
    private static let log = Logger.service("location.icloud-http")
    /// Apple's auth endpoints are picky about the client, so this is what the
    /// iCloud web app sends.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"

    private let session: URLSession
    private let redirects = ICloudRedirectSuppressor()
    private let versionLock = NSLock()
    private var cachedWebClientVersion: ICloudWebClientVersion?

    /// `protocolClasses` is the test seam. A `URLProtocol` stub stands in for
    /// the network and leaves the redirect delegate and the cookie jar exactly
    /// as production has them, which is the part worth testing.
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(
            configuration: configuration,
            delegate: redirects,
            delegateQueue: nil
        )
        super.init()
    }

    func send(_ request: URLRequest) async throws -> ICloudHTTPResponse {
        let (body, response) = try await session.data(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse else {
            throw ICloudHTTPError.notHTTP
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return ICloudHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
    }

    func iCloudWebClientVersion(forceRefresh: Bool) async -> ICloudWebClientVersion {
        if !forceRefresh, let cached = readCachedWebClientVersion() {
            return cached
        }

        var request = URLRequest(url: ICloudEndpoint.home.appending(path: ""))
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if let response = try? await send(request), response.isSuccess,
            let published = ICloudWebClientVersion(homepage: response.body)
        {
            cacheWebClientVersion(published)
            Self.log.notice("Using iCloud web build \(published.buildNumber, privacy: .public)")
            return published
        }
        let fallback = readCachedWebClientVersion() ?? .fallback
        Self.log.error("Could not refresh iCloud web build; using \(fallback.buildNumber, privacy: .public)")
        return fallback
    }

    private func readCachedWebClientVersion() -> ICloudWebClientVersion? {
        versionLock.withLock { cachedWebClientVersion }
    }

    private func cacheWebClientVersion(_ version: ICloudWebClientVersion) {
        versionLock.withLock { cachedWebClientVersion = version }
    }

    func allCookies() -> [HTTPCookie] {
        session.configuration.httpCookieStorage?.cookies ?? []
    }

    func setCookies(_ cookies: [HTTPCookie], for url: URL) {
        session.configuration.httpCookieStorage?
            .setCookies(cookies, for: url, mainDocumentURL: nil)
    }

    func clearCookies() {
        guard let store = session.configuration.httpCookieStorage else { return }
        // A per-URL lookup omits host-only cookies for Find My partitions.
        // Keeping one beside a new SRP session mixes two browser sessions and
        // can make Apple reject the replacement session again.
        for cookie in allCookies() {
            store.deleteCookie(cookie)
        }
    }
}

enum ICloudHTTPError: Swift.Error, ClientFacingError, Equatable {
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .notHTTP:
            return "iCloud returned a response that was not HTTP."
        }
    }
}
