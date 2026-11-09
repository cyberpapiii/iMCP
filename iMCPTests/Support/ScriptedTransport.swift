import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

/// A transport that answers from a script instead of the network, so the flow's
/// ordering, header echoing, and token handling can be tested without an Apple
/// ID or a live sign-in attempt. Repeated failed sign-ins lock a real account,
/// which is exactly why the flow is exercised here rather than against Apple.
final class ScriptedTransport: ICloudHTTPTransport, @unchecked Sendable {
    struct Recorded {
        let request: URLRequest
        var path: String { request.url?.path ?? "" }
        var header: (String) -> String? { { request.value(forHTTPHeaderField: $0) } }
        var json: [String: Any] {
            guard
                let body = request.httpBody,
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return [:] }
            return object
        }
    }

    private let lock = NSLock()
    private var replies: [(match: String, reply: ICloudHTTPResponse)] = []
    private var failures: [(match: String, error: Error)] = []
    private var jar: [HTTPCookie] = []
    private var blockGates: [String: AsyncGate] = [:]
    private var webClientVersions: [ICloudWebClientVersion] = []
    private(set) var webClientVersionRefreshes: [Bool] = []
    private(set) var recorded: [Recorded] = []

    func stub(
        _ pathFragment: String,
        status: Int = 200,
        headers: [String: String] = [:],
        json: Any = [String: Any]()
    ) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        lock.withLock {
            replies.append(
                (
                    pathFragment,
                    ICloudHTTPResponse(statusCode: status, headers: headers, body: body)
                )
            )
        }
    }

    /// Apple answers the two-factor options endpoint with an HTML shell, not
    /// JSON, so some replies cannot be expressed as a JSON object.
    func stubRaw(
        _ pathFragment: String,
        status: Int = 200,
        headers: [String: String] = [:],
        body: String
    ) {
        lock.withLock {
            replies.append(
                (
                    pathFragment,
                    ICloudHTTPResponse(
                        statusCode: status,
                        headers: headers,
                        body: Data(body.utf8)
                    )
                )
            )
        }
    }

    /// The network itself failing, as distinct from Apple answering.
    func fail(_ pathFragment: String, with error: Error) {
        lock.withLock { failures.append((pathFragment, error)) }
    }

    /// Holds every matching request until `resume(_:)`.
    func block(_ pathFragment: String) {
        lock.withLock { blockGates[pathFragment] = AsyncGate() }
    }

    /// Returns once a request matching a blocked fragment is being held.
    func waitUntilBlocked(_ pathFragment: String, file: StaticString = #filePath, line: UInt = #line) async {
        guard let gate = lock.withLock({ blockGates[pathFragment] }) else { return }
        await gate.waitUntilWaiting(file: file, line: line)
    }

    func resume(_ pathFragment: String) {
        guard let gate = lock.withLock({ blockGates.removeValue(forKey: pathFragment) }) else { return }
        Task { await gate.open() }
    }

    func send(_ request: URLRequest) async throws -> ICloudHTTPResponse {
        let path = request.url?.absoluteString ?? ""
        let gate = lock.withLock {
            recorded.append(Recorded(request: request))
            return blockGates.first { path.contains($0.key) }?.value
        }
        if let gate {
            await gate.wait()
        }
        return try lock.withLock {
            if let index = failures.firstIndex(where: { path.contains($0.match) }) {
                throw failures.remove(at: index).error
            }
            guard let index = replies.firstIndex(where: { path.contains($0.match) }) else {
                return ICloudHTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return replies.remove(at: index).reply
        }
    }

    func allCookies() -> [HTTPCookie] {
        lock.withLock { jar }
    }

    func setCookies(_ cookies: [HTTPCookie], for url: URL) {
        lock.withLock { jar.append(contentsOf: cookies) }
    }

    func clearCookies() {
        lock.withLock { jar.removeAll() }
    }

    func stubWebClientVersions(_ versions: [ICloudWebClientVersion]) {
        lock.withLock { webClientVersions = versions }
    }

    func iCloudWebClientVersion(forceRefresh: Bool) async -> ICloudWebClientVersion {
        lock.withLock {
            webClientVersionRefreshes.append(forceRefresh)
            guard !webClientVersions.isEmpty else { return .fallback }
            if webClientVersions.count == 1 { return webClientVersions[0] }
            return webClientVersions.removeFirst()
        }
    }

    func requests(matching fragment: String) -> [Recorded] {
        lock.withLock { recorded.filter { $0.path.contains(fragment) } }
    }
}

/// Stands in for Apple's Find My password page. It records each attempt and
/// either fails as scripted or succeeds without changing the jar, which is
/// what the session then has to validate.
final class ScriptedWebAuthorizer: FindMyWebAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Error] = []
    private var produced: [HTTPCookie] = []
    private var producedClientID: String?
    private(set) var attempts: [(accountName: String, password: String, cookies: [HTTPCookie])] = []

    func fail(with error: Error) {
        lock.withLock { failures.append(error) }
    }

    /// The cookies the page leaves behind on success.
    func produce(_ cookies: [HTTPCookie], clientID: String? = nil) {
        lock.withLock {
            produced = cookies
            producedClientID = clientID
        }
    }

    /// Runs inside each authorization, before it answers.
    func whileAuthorizing(_ body: @escaping @Sendable () async -> Void) {
        lock.withLock { during = body }
    }

    private var during: (@Sendable () async -> Void)?

    func authorize(accountName: String, password: String, cookies: [HTTPCookie]) async throws
        -> FindMyWebAuthorization
    {
        if let during = lock.withLock({ during }) { await during() }
        return try lock.withLock {
            attempts.append((accountName, password, cookies))
            if !failures.isEmpty { throw failures.removeFirst() }
            return FindMyWebAuthorization(cookies: produced, clientID: producedClientID)
        }
    }
}

extension ICloudHTTPTransport {
    /// The jar's cookies that a request to `url` would carry, by domain.
    func cookies(for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") {
                return host == domain.dropFirst() || host.hasSuffix(domain)
            }
            return host == domain
        }
    }
}

extension ICloudAuthClient {
    /// Tests that never reach Find My's password page need no authorizer.
    init(
        transport: ICloudHTTPTransport,
        storage: ICloudCredentialStorage,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(transport: transport, storage: storage, webAuthorizer: ScriptedWebAuthorizer(), now: now)
    }
}

extension ICloudSession {
    /// Tests that never reach Find My's password page need no authorizer.
    convenience init(
        transport: ICloudHTTPTransport,
        storage: ICloudCredentialStorage,
        webAuthorizer: FindMyWebAuthorizing = ScriptedWebAuthorizer(),
        cookieWriteInterval: TimeInterval = 60,
        recoveryRetryInterval: TimeInterval = 5 * 60,
        clock: TestClock = TestClock()
    ) {
        self.init(
            transport: transport,
            storage: storage,
            webAuthorizer: webAuthorizer,
            cookieWriteInterval: cookieWriteInterval,
            recoveryRetryInterval: recoveryRetryInterval,
            clock: clock.wallClock,
            waitForNetwork: { clock.waitForNetwork() }
        )
    }
}

extension ICloudRecoveryOutcome {
    /// The case alone, for asserting where a recovery ended.
    var label: String {
        switch self {
        case .live: return "live"
        case .renewedRecently: return "renewedRecently"
        case .nothingStored: return "nothingStored"
        case .keychainUnreadable: return "keychainUnreadable"
        case .accountRepairRequired: return "accountRepairRequired"
        case .verificationPending: return "verificationPending"
        case .passwordAttemptSpent: return "passwordAttemptSpent"
        case .needsCode: return "needsCode"
        case .needsSignIn: return "needsSignIn"
        case .unreachable: return "unreachable"
        case .renewalInterrupted: return "renewalInterrupted"
        case .superseded: return "superseded"
        }
    }

    var account: ICloudAccount? {
        if case .live(let live) = self { return live.findMy.account }
        return nil
    }

    var error: Error? {
        switch self {
        case .verificationPending(let error), .needsSignIn(_, let error), .unreachable(let error),
            .renewalInterrupted(let error):
            return error
        default:
            return nil
        }
    }
}

@MainActor
extension ICloudSession {
    /// What a tool call does when Find My rejects the live client.
    func renewRejectedClient() async -> FindMyClient? {
        guard let findMy else { return nil }
        return await renewAfterRejection(of: findMy)
    }

    /// Moves time on by `seconds` and lets whatever fell due run.
    func advance(_ clock: TestClock, by seconds: TimeInterval) async {
        clock.advance(by: seconds)
        await settle()
    }
}
