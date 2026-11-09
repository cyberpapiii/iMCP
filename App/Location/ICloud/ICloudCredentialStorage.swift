import Foundation
import Security

/// One session cookie, flattened so it survives in JSON.
///
/// Apple's service endpoints authenticate on the cookie jar an account login
/// leaves behind, not on a header, and there are more of them than the two the
/// sign-in flow itself reads. Keeping only those two means the jar has to be
/// refilled by another account login, which is exactly the call this avoids.
struct ICloudStoredCookie: Codable, Equatable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Date?
}

/// What iMCP keeps after an iCloud sign-in: the tokens Apple hands back, which
/// a later launch replays to get a session without asking the user again, and
/// the Apple ID password (see `password`), which lets the app sign in again by
/// itself when Apple rejects those tokens.
struct ICloudCredentials: Codable, Equatable, Sendable {
    var accountName: String
    var accountCountry: String
    var sessionToken: String
    var trustToken: String?
    /// The `X-APPLE-WEBAUTH-TOKEN` and `X-APPLE-WEBAUTH-USER` cookie values.
    /// Apple's service endpoints authenticate on these, not on a header.
    var webAuthToken: String?
    var webAuthUser: String?
    var trustedAt: Date
    /// The account id and service endpoints Apple returned from the last
    /// account login. Stored because rebuilding a web session can notify the
    /// user, so a launch that already knows where Find My lives must not ask
    /// again. Optional so credentials written
    /// before this existed still decode.
    var dsid: String?
    var webservices: [String: URL]?
    /// The whole cookie jar from the last account login.
    var cookies: [ICloudStoredCookie]?
    /// When this snapshot was last written, by any writer. `trustedAt` is the
    /// sign-in; this moves every time the jar is refreshed, and is what the
    /// status report shows as the snapshot's age. Optional so credentials
    /// written before it existed still decode.
    var updatedAt: Date?
    /// The Apple ID password, kept so the app can sign in again by itself
    /// when Apple rejects the stored session. It never leaves the
    /// data-protection Keychain item on this Mac, is never logged or shown,
    /// and goes with everything else on sign-out. Optional so credentials
    /// written before it existed still decode, and absent for a user who
    /// signed in before it was kept.
    var password: String?
    /// The client id the sign-in ran under. Apple binds the trust token and
    /// the web session to it: an account login or Find My call made under a
    /// different id comes back untrusted (Find My answers 450 even after
    /// `accountLogin` says 200). Stored so every launch presents the same id.
    /// Optional so credentials written before it existed still decode.
    var clientID: String?

    /// Set by `PasswordAttemptGuard` just before an unattended password goes
    /// out; cleared once Find My accepts the session. Optional so
    /// credentials written before this existed still decode.
    var lastAutomaticReauthenticationAt: Date? = nil

    /// When an unattended password last went out. Unlike the guard above, a
    /// Find My acceptance does not clear it: it is what spaces renewals at
    /// least `PasswordAttemptGuard.retryInterval` apart, across relaunches
    /// too, since Apple can email the account owner for each one. Optional
    /// so credentials written before this existed still decode; older builds
    /// ignore it.
    var lastUnattendedPasswordAt: Date? = nil

    /// Apple accepted authentication but still requires updated terms or an
    /// account repair. While set, cached endpoints must be validated before use
    /// and no unattended password sign-in may run.
    /// Optional so credentials written before this existed still decode.
    var accountRepairPending: Bool? = nil
}

/// Only `errSecItemNotFound` counts as empty. A transient Keychain error read
/// as absence would present a signed-in user with a sign-in sheet and then
/// overwrite their live tokens.
struct ICloudCredentialStorage: Sendable {
    static let keychainService = "co.dododo.iMCP.icloud-credentials"
    /// Debug builds keep their own item, so a Debug install never reads or
    /// deletes a Release install's session. The Release item could also carry
    /// a file-keychain ACL from an earlier signature, which prompts after
    /// every rebuild.
    static let debugKeychainService = "co.dododo.iMCP.icloud-credentials.debug-v2"

    /// `unavailable` is not the same as having no credentials, and callers
    /// must not treat it as such.
    typealias LoadResult = KeychainReadResult<ICloudCredentials>

    /// Every Keychain call for the record, one at a time.
    private let item: KeychainItemQueue<ICloudCredentials>

    /// Tests pass in-memory calls so they never touch the real Keychain.
    init(calls: KeychainItemCalls) {
        self.item = KeychainItemQueue(label: Self.keychainService, json: calls)
    }

    /// The one storage over this build's Keychain item, so every caller
    /// shares its queue.
    static let production: ICloudCredentialStorage = {
        #if DEBUG
            let item = KeychainItem(service: debugKeychainService)
        #else
            let item = KeychainItem(service: keychainService)
        #endif
        return ICloudCredentialStorage(calls: KeychainItemCalls(item))
    }()

    /// Reads without a deadline, blocking this thread for as long as a
    /// Keychain prompt stays unanswered. Only for the one-shot
    /// `--icloud-status` report, which has nothing else to run.
    func loadBlocking() -> LoadResult {
        item.loadBlocking()
    }

    /// Reads with a deadline, sharing a read that is still blocked rather
    /// than starting another. Everything on an activation path reads this way.
    func load(within deadline: Duration = KeychainItemQueue.promptDeadline) async -> LoadResult {
        await item.load(within: deadline)
    }

    /// Reads the definitive record and saves what `change` makes of it, in
    /// one call on the item's queue, so no other write lands in between.
    /// The only way the record is written: every writer applies its change
    /// to the record as it stands.
    /// `change` returns nil to save nothing, or throws to stop; nil when
    /// nothing was saved.
    func update(
        _ change: @escaping @Sendable (LoadResult) throws(ICloudAuthError) -> ICloudCredentials?
    ) async throws(ICloudAuthError) -> ICloudCredentials? {
        let outcome = await item.perform { item -> Result<ICloudCredentials?, ICloudAuthError> in
            do throws(ICloudAuthError) {
                guard let record = try change(item.read()) else { return .success(nil) }
                return item.save(record) ? .success(record) : .failure(.couldNotStoreSession)
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }

    /// Signing out. A failed delete is reported rather than swallowed, because
    /// a user who asked to sign out and is still signed in needs to know.
    @discardableResult
    func clear() async -> Bool {
        await item.perform { $0.delete() }
    }
}
