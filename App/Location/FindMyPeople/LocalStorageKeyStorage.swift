import Foundation
import Security

typealias LocalStorageSecretLoadResult = KeychainReadResult<Data>

enum LocalStorageKeyStorageError: Error, ClientFacingError, Equatable {
    case invalidDatabaseKey
    case databaseKeyUnavailable
    case identitySecretUnavailable
    case couldNotPersistDatabaseKey
    case couldNotPersistIdentitySecret

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseKey:
            return "The Find My People key must be exactly 32 bytes."
        case .databaseKeyUnavailable:
            return "The Find My People key could not be read from the Keychain."
        case .identitySecretUnavailable:
            return "The Find My People identity secret could not be read from the Keychain."
        case .couldNotPersistDatabaseKey:
            return "The Find My People key could not be saved. The previous key was preserved."
        case .couldNotPersistIdentitySecret:
            return "The Find My People identity secret could not be saved."
        }
    }
}

/// Separate Keychain items for the encrypted LocalStorage database key and the
/// unrelated secret used to derive opaque friend identifiers.
///
/// Only an explicit `missing` is absence. An unreadable item is never replaced,
/// which prevents a transient Keychain failure from destroying a valid secret.
struct LocalStorageKeyStorage: Sendable {
    static let databaseKeyService = "co.dododo.iMCP.find-my-people-database-key"
    static let identitySecretService = "co.dododo.iMCP.find-my-people-identity-secret"
    static let secretLength = 32

    /// Every Keychain call for each item, one at a time. A key once found
    /// is kept until it is replaced or deleted. One that is not there yet (a
    /// Keychain still locked at login, or not set up) is read again on the
    /// next call.
    private let databaseKeyItem: KeychainItemQueue<Data>
    private let identitySecretItem: KeychainItemQueue<Data>
    private let randomSecret: @Sendable () -> Data?

    init(
        databaseKey: KeychainItemCalls,
        identitySecret: KeychainItemCalls,
        randomSecret: @escaping @Sendable () -> Data? = {
            LocalStorageKeyStorage.makeRandomSecret()
        }
    ) {
        self.databaseKeyItem = KeychainItemQueue(label: Self.databaseKeyService, keepsFound: true, calls: databaseKey)
        self.identitySecretItem = KeychainItemQueue(
            label: Self.identitySecretService,
            keepsFound: true,
            calls: identitySecret
        )
        self.randomSecret = randomSecret
    }

    /// The one storage over the real items, so every caller shares their
    /// queues.
    static let production = LocalStorageKeyStorage(
        databaseKey: KeychainItemCalls(KeychainItem(service: databaseKeyService, account: "secret")),
        identitySecret: KeychainItemCalls(KeychainItem(service: identitySecretService, account: "secret"))
    )

    func databaseKey(within deadline: Duration = KeychainItemQueue.promptDeadline) async -> LocalStorageSecretLoadResult
    {
        await databaseKeyItem.load(within: deadline)
    }

    func identitySecret(within deadline: Duration = KeychainItemQueue.promptDeadline) async
        -> LocalStorageSecretLoadResult
    {
        await identitySecretItem.load(within: deadline)
    }

    /// Validation finishes before the Keychain item is touched. Keychain update
    /// and add are atomic operations, so a failed write leaves the old key live.
    func replaceDatabaseKey(
        _ candidate: Data,
        validate: @Sendable (Data) async throws -> Void
    ) async throws {
        guard candidate.count == Self.secretLength else {
            throw LocalStorageKeyStorageError.invalidDatabaseKey
        }
        try await validate(candidate)
        let outcome = await databaseKeyItem.perform { item -> LocalStorageKeyStorageError? in
            guard item.read() != .unavailable else { return .databaseKeyUnavailable }
            return item.save(candidate) ? nil : .couldNotPersistDatabaseKey
        }
        if let outcome { throw outcome }
    }

    func loadOrCreateIdentitySecret() async throws -> Data {
        let randomSecret = randomSecret
        let outcome = await identitySecretItem.perform { item -> Result<Data, LocalStorageKeyStorageError> in
            switch item.read() {
            case .found(let data):
                return data.count == Self.secretLength ? .success(data) : .failure(.identitySecretUnavailable)
            case .unavailable:
                return .failure(.identitySecretUnavailable)
            case .missing:
                guard let secret = randomSecret(), secret.count == Self.secretLength else {
                    return .failure(.identitySecretUnavailable)
                }
                return item.save(secret) ? .success(secret) : .failure(.couldNotPersistIdentitySecret)
            }
        }
        return try outcome.get()
    }

    @discardableResult
    func clearDatabaseKey() async -> Bool {
        await databaseKeyItem.perform { $0.delete() }
    }

    @discardableResult
    func clearIdentitySecret() async -> Bool {
        await identitySecretItem.perform { $0.delete() }
    }

    private static func makeRandomSecret() -> Data? {
        var data = Data(count: secretLength)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        return status == errSecSuccess ? data : nil
    }
}
