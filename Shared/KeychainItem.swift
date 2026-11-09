import Foundation
import os
import Security

/// One generic-password item, read and written through the data-protection
/// keychain when this build is entitled to reach it and through the file
/// keychain when it is not.
///
/// The distinction is the whole point. The file keychain guards an item with an
/// access-control list naming the binary that created it, so a rebuilt or
/// re-signed app is a stranger to its own secrets and macOS asks the user to
/// approve the access. The data-protection keychain grants access by keychain
/// access group instead, which is carried in the code signature and does not
/// change when the binary does — so a reinstall reads its own tokens back
/// silently, and the user is not asked to sign in to iCloud or re-approve a
/// paired client again.
///
/// Reaching the data-protection keychain requires the `keychain-access-groups`
/// entitlement, which requires a provisioning profile. CI has neither, and a
/// contributor building without a certificate has neither, so every operation
/// falls back to the file keychain rather than failing. An item found in the
/// file keychain is migrated on read once the entitled path is available.
struct KeychainItem {
    enum LoadResult: Equatable {
        case data(Data)
        case missing
        case failed(OSStatus)
    }

    enum Keychains {
        /// The data-protection keychain when this build is entitled to it,
        /// migrating a file-keychain item across on read; the file keychain
        /// otherwise.
        case preferDataProtection
        /// The file keychain only, for an item that has to stay where earlier
        /// builds of the same binary look for it.
        case fileOnly
    }

    let service: String
    let account: String?
    let keychains: Keychains

    private static let log = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? WireContract.appBundleIdentifier,
        category: "services.keychain"
    )

    init(service: String, account: String? = nil, keychains: Keychains = .preferDataProtection) {
        self.service = service
        self.account = account
        self.keychains = keychains
    }

    /// `kSecAttrAccessGroup` is deliberately absent: with a single group in the
    /// entitlement the system uses that one, so the team identifier does not
    /// have to be written into the source.
    private func query(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        } else {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        }
        return query
    }

    private func read(dataProtection: Bool) -> LoadResult {
        var query = query(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(errSecDecode) }
            return .data(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
    }

    private func write(_ data: Data, dataProtection: Bool) -> OSStatus {
        let query = query(dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var add = query
        for (key, value) in attributes { add[key] = value }
        return SecItemAdd(add as CFDictionary, nil)
    }

    private func remove(dataProtection: Bool) -> OSStatus {
        SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
    }

    func load() -> LoadResult {
        if keychains == .fileOnly {
            return read(dataProtection: false)
        }
        switch read(dataProtection: true) {
        case .data(let data):
            return .data(data)
        case .missing:
            break
        case .failed(errSecMissingEntitlement):
            // Unentitled build: the file keychain is the only keychain.
            return read(dataProtection: false)
        case .failed(let status):
            Self.log.error("Keychain load failed with OSStatus \(status, privacy: .public)")
            return .failed(status)
        }

        // Nothing in the entitled keychain, so this may be an item written by a
        // build that predates the entitlement. Move it across on the way out;
        // a failed move still returns the data, because a readable secret in
        // the wrong keychain beats no secret at all.
        guard case .data(let legacy) = read(dataProtection: false) else {
            return .missing
        }
        if write(legacy, dataProtection: true) == errSecSuccess {
            _ = remove(dataProtection: false)
            Self.log.notice("Migrated \(service, privacy: .public) to the data-protection keychain")
        }
        return .data(legacy)
    }

    @discardableResult
    func save(_ data: Data) -> Bool {
        if keychains == .fileOnly {
            let status = write(data, dataProtection: false)
            if status != errSecSuccess {
                Self.log.error("Keychain save failed with OSStatus \(status, privacy: .public)")
            }
            return status == errSecSuccess
        }
        let status = write(data, dataProtection: true)
        if status == errSecSuccess { return true }
        if status == errSecMissingEntitlement {
            return write(data, dataProtection: false) == errSecSuccess
        }
        Self.log.error("Keychain save failed with OSStatus \(status, privacy: .public)")
        return false
    }

    /// Deletes from both keychains. A secret the caller asked to forget must
    /// not survive in the one this build happens not to be using.
    @discardableResult
    func delete() -> Bool {
        var succeeded = true
        for dataProtection in keychains == .fileOnly ? [false] : [true, false] {
            let status = remove(dataProtection: dataProtection)
            switch status {
            case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                Self.log.error("Keychain delete failed with OSStatus \(status, privacy: .public)")
                succeeded = false
            }
        }
        return succeeded
    }
}

/// The raw calls on one Keychain item: a `KeychainItem` in the app and the
/// CLI, an in-memory item in tests.
struct KeychainItemCalls: Sendable {
    var load: @Sendable () -> KeychainItem.LoadResult
    var save: @Sendable (Data) -> Bool
    var delete: @Sendable () -> Bool

    init(
        load: @escaping @Sendable () -> KeychainItem.LoadResult,
        save: @escaping @Sendable (Data) -> Bool,
        delete: @escaping @Sendable () -> Bool
    ) {
        self.load = load
        self.save = save
        self.delete = delete
    }

    init(_ item: KeychainItem) {
        self.init(load: { item.load() }, save: { item.save($0) }, delete: { item.delete() })
    }
}
