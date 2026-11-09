import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

private let log = Logger.service("location.people.bootstrap")

struct FindMyPeopleSecurityPosture: Codable, Equatable, Sendable {
    var fullSecurityEnabled: Bool
    var sipEnabled: Bool
    var authenticatedRootEnabled: Bool
    var unsafeBootArguments: [String]
    var developerToolsSecurityEnabled: Bool
    var bootSessionUUID: String

    var isSafe: Bool {
        fullSecurityEnabled && sipEnabled && authenticatedRootEnabled && unsafeBootArguments.isEmpty
    }

    /// Throws rather than hashing nothing: an empty digest would make every
    /// posture look alike.
    func stableDigest() throws -> Data {
        var copy = self
        copy.bootSessionUUID = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(copy) else { throw FindMyPeopleBootstrapError.invalidArtifact }
        return Data(SHA256.hash(data: encoded))
    }
}

struct FindMyPeopleRestorationReport: Codable, Equatable, Sendable {
    let format: String
    /// This is intentionally false for the bundled shell verifier. macOS does
    /// not expose an unprivileged, independently signing boot-policy API.
    let authoritative: Bool
    let baselineDigest: String
    let envelopeDigest: String
    let posture: FindMyPeopleSecurityPosture
}

struct FindMyPeopleBootstrapPayload: Equatable, Sendable {
    let databaseKey: Data
    let nonce: UUID
    let baselineDigest: Data
    let installationBinding: Data

    /// Where each field sits in the decrypted payload, in order. The LLDB
    /// capture writes the same layout (`payload_for` in
    /// `Scripts/find_my_people_artifacts.py`).
    enum Layout {
        static let magic = 0 ..< 8
        static let nonce = magic.upperBound ..< magic.upperBound + 16
        static let baselineDigest = nonce.upperBound ..< nonce.upperBound + 32
        static let installationBinding = baselineDigest.upperBound ..< baselineDigest.upperBound + 32
        static let databaseKey =
            installationBinding.upperBound ..< installationBinding.upperBound + LocalStorageKeyStorage.secretLength
        static let length = databaseKey.upperBound
    }
}

enum FindMyPeopleBootstrapState: Equatable, Sendable {
    case notConfigured
    /// The Keychain did not answer whether setup was prepared.
    case keychainUnavailable
    case handoffReady
    case restorationRequired
    case envelopeReady
    case configured
}

enum FindMyPeopleBootstrapError: Error, ClientFacingError, Equatable {
    case unsafeBaseline
    case missingBaselineReport
    case invalidArtifact
    case noPreparedHandoff
    case replayOrDifferentInstallation
    case rebootRequired
    case securityNotRestored
    case authenticationRequired
    case keyGenerationFailed
    case keychainUnavailable
    case writeFailed
    case importFailed

    var errorDescription: String? {
        switch self {
        case .unsafeBaseline:
            return
                "Setup requires Full Security, fully enabled SIP, authenticated root, and no weakening boot arguments."
        case .missingBaselineReport:
            return "Run the security verifier in baseline mode before preparing setup."
        case .invalidArtifact:
            return "A Find My People setup artifact is invalid or was modified."
        case .noPreparedHandoff:
            return "Prepare a new Find My People setup handoff first."
        case .replayOrDifferentInstallation:
            return "This envelope was already consumed or belongs to a different iMCP installation."
        case .rebootRequired:
            return "Restore macOS security and reboot before importing the envelope."
        case .securityNotRestored:
            return "The complete recorded macOS security posture has not been restored."
        case .authenticationRequired:
            return "Device-owner authentication is required to import the Find My People key."
        case .keyGenerationFailed:
            return "iMCP could not create the one-time device-bound handoff key."
        case .keychainUnavailable:
            return "The Find My People bootstrap state could not be read from the Keychain."
        case .writeFailed:
            return "iMCP could not create the private setup handoff."
        case .importFailed:
            return "The encrypted Find My People handoff could not be imported."
        }
    }
}

/// Human-gated, one-time bridge between the debugger-only capture and normal
/// read-only runtime. The private RSA key is non-extractable Keychain state;
/// files contain only public metadata, ciphertext, and coarse posture facts.
actor FindMyPeopleBootstrap {
    static let handoffFormat = "imcp-find-my-people-handoff-v1"
    static let envelopeFormat = "imcp-find-my-people-envelope-v1"
    static let restorationReportFormat = "imcp-find-my-people-restoration-v1"

    static let stateItem = KeychainItem(
        service: "co.dododo.iMCP.find-my-people-bootstrap-state",
        account: "state"
    )
    static let installationItem = KeychainItem(
        service: "co.dododo.iMCP.find-my-people-bootstrap-installation",
        account: "state"
    )
    private static let privateKeyTag = Data("co.dododo.iMCP.find-my-people-bootstrap-rsa".utf8)
    static let payloadMagic = Data("iMCPFMP1".utf8)

    /// The bootstrap's Keychain items, one queue each. The prepared state and
    /// its one-time RSA key are made and cleared together, so the key's calls
    /// run on the state's queue.
    struct Keychain: Sendable {
        fileprivate let preparedState: KeychainItemQueue<PreparedState>
        fileprivate let installation: KeychainItemQueue<Data>

        init(preparedState: KeychainItemCalls, installation: KeychainItemCalls) {
            self.preparedState = KeychainItemQueue(label: stateItem.service, json: preparedState)
            self.installation = KeychainItemQueue(label: installationItem.service, calls: installation)
        }

        /// The one set of queues over the real items.
        static let production = Keychain(
            preparedState: KeychainItemCalls(stateItem),
            installation: KeychainItemCalls(installationItem)
        )
    }

    fileprivate struct PreparedState: Codable, Equatable {
        let nonce: UUID
        let baseline: FindMyPeopleSecurityPosture
        let baselineDigest: String
        let installationBinding: String
        let preparedAt: Date
    }

    struct Handoff: Codable {
        let format: String
        let nonce: UUID
        let baselineDigest: String
        let installationBinding: String
        let preparedAt: Date
        let publicKeyPEM: String

        enum CodingKeys: String, CodingKey {
            case format, nonce
            case baselineDigest = "baseline_digest"
            case installationBinding = "installation_binding"
            case preparedAt = "prepared_at"
            case publicKeyPEM = "public_key_pem"
        }
    }

    struct Envelope: Codable {
        let format: String
        let nonce: UUID
        let baselineDigest: String
        let installationBinding: String
        let ciphertext: String

        enum CodingKeys: String, CodingKey {
            case format, nonce, ciphertext
            case baselineDigest = "baseline_digest"
            case installationBinding = "installation_binding"
        }
    }

    private let readiness: FindMyPeopleReadiness
    private let keychain: Keychain

    init(readiness: FindMyPeopleReadiness, keychain: Keychain = .production) {
        self.readiness = readiness
        self.keychain = keychain
    }

    static var artifactDirectory: URL {
        WireContract.appSupportDirectory().appendingPathComponent("FindMyPeopleBootstrap", isDirectory: true)
    }

    static var baselineReportURL: URL { artifactDirectory.appendingPathComponent("baseline.json") }
    static var handoffURL: URL { artifactDirectory.appendingPathComponent("handoff.json") }
    static var envelopeURL: URL { artifactDirectory.appendingPathComponent("envelope.json") }
    static var restorationReportURL: URL { artifactDirectory.appendingPathComponent("restoration.json") }

    func state() async -> FindMyPeopleBootstrapState {
        switch await readiness.secretsState() {
        case .ready: return .configured
        // An unreadable secret says nothing about whether setup finished.
        case .keyUnavailable, .identityUnavailable: return .keychainUnavailable
        case .disabled, .missingKey: break
        }
        switch await keychain.preparedState.load() {
        case .missing: return .notConfigured
        case .unavailable: return .keychainUnavailable
        case .found: break
        }
        guard FileManager.default.fileExists(atPath: Self.envelopeURL.path) else { return .handoffReady }
        guard FileManager.default.fileExists(atPath: Self.restorationReportURL.path) else {
            return .restorationRequired
        }
        return .envelopeReady
    }

    @discardableResult
    func prepare() async throws -> URL {
        guard let baselineData = try? Data(contentsOf: Self.baselineReportURL),
            let report = try? JSONDecoder().decode(FindMyPeopleRestorationReport.self, from: baselineData)
        else { throw FindMyPeopleBootstrapError.missingBaselineReport }
        guard report.format == Self.restorationReportFormat, report.posture.isSafe else {
            throw FindMyPeopleBootstrapError.unsafeBaseline
        }
        let baselineDigest = try report.posture.stableDigest()
        guard report.baselineDigest == baselineDigest.hexString else {
            throw FindMyPeopleBootstrapError.invalidArtifact
        }

        try Self.ensurePrivateDirectory()
        let installationBinding = try await installationBinding()
        let nonce = UUID()
        guard let publicKey = await keychain.preparedState.perform({ _ in try? Self.createOneTimeKey() }) else {
            throw FindMyPeopleBootstrapError.keyGenerationFailed
        }
        let state = PreparedState(
            nonce: nonce,
            baseline: report.posture,
            baselineDigest: baselineDigest.hexString,
            installationBinding: installationBinding.hexString,
            preparedAt: Date()
        )
        guard await keychain.preparedState.perform({ $0.save(state) }) else {
            await clearPreparedStateAndKey()
            throw FindMyPeopleBootstrapError.keychainUnavailable
        }
        let handoff = Handoff(
            format: Self.handoffFormat,
            nonce: nonce,
            baselineDigest: state.baselineDigest,
            installationBinding: state.installationBinding,
            preparedAt: state.preparedAt,
            publicKeyPEM: Self.pem(publicKey)
        )
        do {
            try Self.writePrivateJSON(handoff, to: Self.handoffURL)
        } catch {
            await clearPreparedStateAndKey()
            throw FindMyPeopleBootstrapError.writeFailed
        }
        return Self.handoffURL
    }

    func importPreparedEnvelope() async throws {
        let state: PreparedState
        switch await keychain.preparedState.perform({ $0.read() }) {
        case .found(let found): state = found
        case .missing: throw FindMyPeopleBootstrapError.noPreparedHandoff
        case .unavailable: throw FindMyPeopleBootstrapError.keychainUnavailable
        }
        let envelopeData = try Self.readArtifact(Self.envelopeURL)
        let restorationData = try Self.readArtifact(Self.restorationReportURL)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
            let report = try? JSONDecoder().decode(FindMyPeopleRestorationReport.self, from: restorationData),
            envelope.format == Self.envelopeFormat,
            envelope.nonce == state.nonce,
            envelope.baselineDigest == state.baselineDigest,
            envelope.installationBinding == state.installationBinding,
            report.baselineDigest == state.baselineDigest,
            report.envelopeDigest == Data(SHA256.hash(data: envelopeData)).hexString
        else { throw FindMyPeopleBootstrapError.invalidArtifact }

        let authenticated = await Self.authenticateDeviceOwner()
        try Self.validateManualImportGate(report: report, authenticatedByDeviceOwner: authenticated)
        try Self.validateRestoration(baseline: state.baseline, current: report.posture)

        guard let encrypted = Data(base64Encoded: envelope.ciphertext),
            let plaintext = await keychain.preparedState.perform({ _ in Self.decrypt(encrypted) })
        else { throw FindMyPeopleBootstrapError.importFailed }
        let payload = try Self.decodePayload(plaintext)
        try Self.validate(
            payload: payload,
            expectedNonce: state.nonce,
            expectedBaselineDigest: try Self.bytes(hex: state.baselineDigest),
            expectedInstallationBinding: try Self.bytes(hex: state.installationBinding)
        )
        try await readiness.importDatabaseKey(payload.databaseKey)

        // The key is in. What is left is plaintext-free, but it should not
        // linger: a leftover is logged, not reported as a failed import.
        await clearPreparedStateAndKey()
        if !Self.removeArtifacts() {
            log.error("A used Find My People setup artifact could not be deleted")
        }
    }

    func clearPreparedHandoff() async throws {
        let artifactsRemoved = Self.removeArtifacts()
        guard await clearPreparedStateAndKey() else { throw FindMyPeopleBootstrapError.keychainUnavailable }
        guard artifactsRemoved else { throw FindMyPeopleBootstrapError.writeFailed }
    }

    private static func removeArtifacts() -> Bool {
        var removed = true
        for url in [handoffURL, envelopeURL, restorationReportURL] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                removed = false
            }
        }
        return removed
    }

    private static func bytes(hex: String) throws -> Data {
        guard let data = Data(hexString: hex) else { throw FindMyPeopleBootstrapError.invalidArtifact }
        return data
    }

    static func encodePayload(
        databaseKey: Data,
        nonce: UUID,
        baselineDigest: Data,
        installationBinding: Data
    ) throws -> Data {
        guard databaseKey.count == FindMyPeopleBootstrapPayload.Layout.databaseKey.count,
            baselineDigest.count == FindMyPeopleBootstrapPayload.Layout.baselineDigest.count,
            installationBinding.count == FindMyPeopleBootstrapPayload.Layout.installationBinding.count
        else {
            throw FindMyPeopleBootstrapError.invalidArtifact
        }
        var bytes = payloadMagic
        var uuid = nonce.uuid
        withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
        bytes.append(baselineDigest)
        bytes.append(installationBinding)
        bytes.append(databaseKey)
        return bytes
    }

    static func decodePayload(_ data: Data) throws -> FindMyPeopleBootstrapPayload {
        typealias Layout = FindMyPeopleBootstrapPayload.Layout
        guard data.count == Layout.length, data[Layout.magic] == payloadMagic else {
            throw FindMyPeopleBootstrapError.invalidArtifact
        }
        let uuidBytes = [UInt8](data[Layout.nonce])
        let nonce = UUID(
            uuid: (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            )
        )
        return FindMyPeopleBootstrapPayload(
            databaseKey: Data(data[Layout.databaseKey]),
            nonce: nonce,
            baselineDigest: Data(data[Layout.baselineDigest]),
            installationBinding: Data(data[Layout.installationBinding])
        )
    }

    static func validate(
        payload: FindMyPeopleBootstrapPayload,
        expectedNonce: UUID,
        expectedBaselineDigest: Data,
        expectedInstallationBinding: Data
    ) throws {
        guard payload.nonce == expectedNonce,
            payload.baselineDigest == expectedBaselineDigest,
            payload.installationBinding == expectedInstallationBinding
        else { throw FindMyPeopleBootstrapError.replayOrDifferentInstallation }
    }

    static func validateRestoration(
        baseline: FindMyPeopleSecurityPosture,
        current: FindMyPeopleSecurityPosture
    ) throws {
        guard current.bootSessionUUID != baseline.bootSessionUUID else {
            throw FindMyPeopleBootstrapError.rebootRequired
        }
        guard current.isSafe,
            baseline.isSafe,
            current.developerToolsSecurityEnabled == baseline.developerToolsSecurityEnabled,
            try current.stableDigest() == baseline.stableDigest()
        else { throw FindMyPeopleBootstrapError.securityNotRestored }
    }

    static func validateManualImportGate(
        report: FindMyPeopleRestorationReport,
        authenticatedByDeviceOwner: Bool
    ) throws {
        guard report.format == restorationReportFormat else {
            throw FindMyPeopleBootstrapError.invalidArtifact
        }
        // No receipt producer is independently signed yet. Never let an
        // artifact-controlled field bypass fresh device-owner authentication.
        guard authenticatedByDeviceOwner else {
            throw FindMyPeopleBootstrapError.authenticationRequired
        }
    }

    private static func authenticateDeviceOwner() async -> Bool {
        await withCheckedContinuation { continuation in
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                continuation.resume(returning: false)
                return
            }
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Import the one-time Find My People key"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func createOneTimeKey() throws -> Data {
        guard deletePrivateKey() else { throw FindMyPeopleBootstrapError.keyGenerationFailed }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrIsExtractable as String: false,
                kSecAttrApplicationTag as String: privateKeyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
            let publicKey = SecKeyCopyPublicKey(privateKey),
            let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw FindMyPeopleBootstrapError.keyGenerationFailed }
        return representation
    }

    /// Called on the prepared state's queue: reading the key can wait on a
    /// Keychain prompt.
    private static func decrypt(_ encrypted: Data) -> Data? {
        guard let privateKey = loadPrivateKey() else { return nil }
        return SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA256, encrypted as CFData, nil) as Data?
    }

    private static func loadPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    private static func deletePrivateKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func pem(_ publicKey: Data) -> String {
        let body = publicKey.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN RSA PUBLIC KEY-----\n\(body)-----END RSA PUBLIC KEY-----\n"
    }

    private func installationBinding() async throws -> Data {
        let secret = await keychain.installation.perform { item -> Data? in
            switch item.read() {
            case .found(let data): return data
            case .unavailable: return nil
            case .missing:
                var data = Data(count: 32)
                guard
                    data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) })
                        == errSecSuccess,
                    item.save(data)
                else { return nil }
                return data
            }
        }
        guard let secret else { throw FindMyPeopleBootstrapError.keychainUnavailable }
        return Data(SHA256.hash(data: secret))
    }

    @discardableResult
    private func clearPreparedStateAndKey() async -> Bool {
        await keychain.preparedState.perform { item in
            let stateCleared = item.delete()
            let keyCleared = Self.deletePrivateKey()
            return stateCleared && keyCleared
        }
    }

    private static func ensurePrivateDirectory() throws {
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifactDirectory.path)
    }

    private static func writePrivateJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readArtifact(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FindMyPeopleBootstrapError.invalidArtifact }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_size >= 0,
            metadata.st_size <= 16_384
        else {
            throw FindMyPeopleBootstrapError.invalidArtifact
        }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw FindMyPeopleBootstrapError.invalidArtifact }
        return data
    }
}
