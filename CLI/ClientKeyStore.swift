import CryptoKit
import Foundation
import Security

struct ClientKeyRotationResult {
    let oldFingerprint: String
    let newFingerprint: String
}

enum ClientKeyStore {
    static let keychainService = "me.mattt.iMCP.client-key"
    static let keyFileEnvironmentVariable = "IMCP_KEY_FILE"

    /// The Keychain item the key lives in; tests pass their own. The file
    /// keychain only. An `imcp-server` signed for development carries an
    /// application identifier, which reaches the data-protection keychain, so
    /// the default would move the key there; a build without one would then
    /// not find it, make a new key, and arrive as an unpaired client.
    static let live = KeychainItemCalls(KeychainItem(service: keychainService, keychains: .fileOnly))

    enum KeyLocation: Equatable {
        case keychain
        /// `carriesOverKeychainKey` adopts a key already in the Keychain when
        /// the file does not exist yet.
        case file(URL, carriesOverKeychainKey: Bool)

        static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyLocation {
            #if DEBUG
                if let keyFilePath = environment[keyFileEnvironmentVariable], !keyFilePath.isEmpty {
                    return .file(URL(fileURLWithPath: keyFilePath), carriesOverKeychainKey: false)
                }
                return .file(debugKeyFileURL(), carriesOverKeychainKey: true)
            #else
                return .keychain
            #endif
        }
    }

    /// The app pairs by public-key fingerprint, so a rotated key arrives as a
    /// new client and has to be paired again.
    static func rotateSigningKey(
        at location: KeyLocation = .resolve(),
        keychain: KeychainItemCalls = live
    ) -> ClientKeyRotationResult? {
        guard let oldKey = loadSigningKey(from: location, keychain: keychain) else { return nil }
        let oldFingerprint = publicKeyFingerprint(for: oldKey)
        let newKey = P256.Signing.PrivateKey()
        guard persistSigningKey(newKey, to: location, keychain: keychain) else { return nil }
        return ClientKeyRotationResult(
            oldFingerprint: oldFingerprint,
            newFingerprint: publicKeyFingerprint(for: newKey)
        )
    }

    static func publicKeyFingerprint(for privateKey: P256.Signing.PrivateKey) -> String {
        AuthPreamble.clientPublicKeyFingerprint(from: privateKey.publicKey)
    }

    /// A new key is made only where none exists. A Keychain that could not
    /// be read is not one without a key: replacing the key there would turn
    /// a paired client into an unknown one.
    static func loadSigningKey(
        from location: KeyLocation = .resolve(),
        keychain: KeychainItemCalls = live
    ) -> P256.Signing.PrivateKey? {
        switch location {
        case .keychain:
            return loadSigningKeyFromKeychain(keychain)
        case .file(let url, let carriesOverKeychainKey):
            if FileManager.default.fileExists(atPath: url.path) {
                return loadSigningKeyFromFile(at: url)
            }
            // Carry the existing key over rather than generating a new one: the
            // app pairs by public-key fingerprint, and a new key arrives as an
            // unknown client that has to be paired again.
            if carriesOverKeychainKey {
                switch readKeychainData(keychain) {
                case .unreadable:
                    return nil
                case .found(let existing):
                    if let key = try? P256.Signing.PrivateKey(rawRepresentation: existing),
                        writeSigningKeyFile(key, at: url)
                    {
                        return key
                    }
                case .missing:
                    break
                }
            }
            let privateKey = P256.Signing.PrivateKey()
            guard writeSigningKeyFile(privateKey, at: url) else { return nil }
            return privateKey
        }
    }

    private static func persistSigningKey(
        _ privateKey: P256.Signing.PrivateKey,
        to location: KeyLocation,
        keychain: KeychainItemCalls
    ) -> Bool {
        switch location {
        case .keychain:
            return storeKeychainData(privateKey.rawRepresentation, in: keychain)
        case .file(let url, _):
            return writeSigningKeyFile(privateKey, at: url)
        }
    }

    private static func loadSigningKeyFromFile(at url: URL) -> P256.Signing.PrivateKey? {
        let path = url.path
        guard let rawKey = try? Data(contentsOf: url), rawKey.count == 32 else {
            fputs(
                "error: could not read signing key at \(path) (unreadable or wrong length); "
                    + "refusing to overwrite it. The client will not authenticate until this is resolved.\n",
                stderr
            )
            return nil
        }
        do {
            return try P256.Signing.PrivateKey(rawRepresentation: rawKey)
        } catch {
            fputs(
                "error: could not parse signing key at \(path): \(error); "
                    + "refusing to overwrite it. The client will not authenticate until this is resolved.\n",
                stderr
            )
            return nil
        }
    }

    #if DEBUG
        /// The Keychain pins an item's access control to the exact code
        /// signature that created it, so every rebuild of this binary produces
        /// another authorization prompt. A `0600` file in the user's own
        /// Application Support directory does not, and a Debug build is the only
        /// place that trade is worth making.
        static func debugKeyFileURL() -> URL {
            WireContract.appSupportDirectory().appendingPathComponent("client-key")
        }
    #endif

    private static func loadSigningKeyFromKeychain(_ keychain: KeychainItemCalls) -> P256.Signing.PrivateKey? {
        switch readKeychainData(keychain) {
        case .unreadable:
            return nil
        case .found(let existing):
            do {
                return try P256.Signing.PrivateKey(rawRepresentation: existing)
            } catch {
                fputs(
                    "error: corrupt signing key in keychain; recreating: \(error)\n",
                    stderr
                )
                _ = keychain.delete()
            }
        case .missing:
            break
        }

        let privateKey = P256.Signing.PrivateKey()
        guard storeKeychainData(privateKey.rawRepresentation, in: keychain) else { return nil }
        return privateKey
    }

    private static func writeSigningKeyFile(
        _ privateKey: P256.Signing.PrivateKey,
        at url: URL
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try privateKey.rawRepresentation.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            fputs(
                "error: could not write signing key to \(url.path): \(error)\n",
                stderr
            )
            return false
        }
    }

    private enum KeychainRead {
        case found(Data)
        case missing
        case unreadable
    }

    private static func readKeychainData(_ keychain: KeychainItemCalls) -> KeychainRead {
        switch keychain.load() {
        case .data(let data):
            return .found(data)
        case .missing:
            return .missing
        case .failed(let status):
            fputs(
                "error: could not read signing key from keychain (OSStatus \(status)); "
                    + "refusing to replace it. The client will not authenticate until the "
                    + "Keychain can be read: unlock it, or answer its prompt with Always Allow.\n",
                stderr
            )
            return .unreadable
        }
    }

    private static func storeKeychainData(_ data: Data, in keychain: KeychainItemCalls) -> Bool {
        guard keychain.save(data) else {
            fputs("error: could not store signing key in keychain\n", stderr)
            return false
        }
        return true
    }
}
