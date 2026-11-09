import CryptoKit
import Foundation

/// Wire-format authentication frames exchanged before MCP JSON-RPC traffic.
///
/// Every frame opens with a fixed magic prefix, the same trick the SDK uses
/// for heartbeats, so a receive buffer can never confuse one with
/// newline-delimited JSON or with heartbeat bytes.
enum AuthPreamble {
    static let protocolVersion: UInt8 = 1

    static let challengeMagic = Data([0xFC, 0x9F, 0x41, 0x43])
    static let responseMagic = Data([0xFC, 0x9F, 0x41, 0x52])

    static let nonceLength = 32
    /// Byte length of `P256.Signing.PublicKey.rawRepresentation` on Apple platforms.
    static let publicKeyLength = 64
    static let signatureLength = 64
    static let maxPairingCodeLength = 8
    static let minPairingCodeLength = 6

    static let challengeFrameLength =
        challengeMagic.count + 1 + MemoryLayout<uuid_t>.size + nonceLength
    static let responseFrameLength =
        responseMagic.count + 1 + publicKeyLength + signatureLength
    static let responsePairingCodeLengthFieldSize = 1

    /// Lowercase hex SHA-256 of `P256.Signing.PublicKey.rawRepresentation`.
    /// **Not** DER SubjectPublicKeyInfo. Fingerprints computed any other way
    /// will not match the trust store, so every caller must come through here.
    static func clientPublicKeyFingerprint(from publicKey: P256.Signing.PublicKey) -> String {
        fingerprintHex(for: publicKey.rawRepresentation)
    }

    private static func fingerprintHex(for rawPublicKey: Data) -> String {
        SHA256.hash(data: rawPublicKey).map { String(format: "%02x", $0) }.joined()
    }

    static func signingPayload(nonce: Data, connectionID: UUID) -> Data {
        var payload = Data()
        payload.append(nonce)
        payload.append(connectionIDBytes(connectionID))
        return payload
    }

    static func connectionIDBytes(_ connectionID: UUID) -> Data {
        var uuid = connectionID.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}

/// What the head of a receive buffer holds, for one kind of auth frame.
enum AuthFrameParse<Frame: Equatable & Sendable>: Equatable, Sendable {
    case complete(Frame, length: Int)
    /// The start of a frame. Wait for more bytes before reading anything else.
    case partial
    /// A whole frame that breaks the format. Drop the connection, and do not
    /// read the bytes as MCP.
    case rejected
    case notThisFrame

    var frame: Frame? {
        if case .complete(let frame, _) = self { return frame }
        return nil
    }
}

struct AuthChallengeFrame: Equatable, Sendable {
    let protocolVersion: UInt8
    let connectionID: UUID
    let nonce: Data

    init(connectionID: UUID, nonce: Data = AuthPreamble.randomNonce()) {
        self.protocolVersion = AuthPreamble.protocolVersion
        self.connectionID = connectionID
        self.nonce = nonce
    }

    func encode() -> Data {
        var frame = AuthPreamble.challengeMagic
        frame.append(protocolVersion)
        frame.append(AuthPreamble.connectionIDBytes(connectionID))
        frame.append(nonce)
        return frame
    }

    static func parse(_ buffer: Data) -> AuthFrameParse<AuthChallengeFrame> {
        guard !buffer.isEmpty else { return .notThisFrame }
        guard buffer.starts(with: AuthPreamble.challengeMagic) else {
            return AuthPreamble.challengeMagic.starts(with: buffer) ? .partial : .notThisFrame
        }
        guard buffer.count >= AuthPreamble.challengeFrameLength else { return .partial }

        let base = buffer.startIndex
        let versionIndex = base + AuthPreamble.challengeMagic.count
        let connectionIDStart = versionIndex + 1
        let nonceStart = connectionIDStart + MemoryLayout<uuid_t>.size
        let nonceEnd = nonceStart + AuthPreamble.nonceLength

        let version = buffer[versionIndex]
        guard version == AuthPreamble.protocolVersion,
            let connectionID = uuidFromConnectionIDBytes(Data(buffer[connectionIDStart ..< nonceStart]))
        else { return .notThisFrame }

        let frame = AuthChallengeFrame(
            protocolVersion: version,
            connectionID: connectionID,
            nonce: Data(buffer[nonceStart ..< nonceEnd])
        )
        return .complete(frame, length: AuthPreamble.challengeFrameLength)
    }

    private init(protocolVersion: UInt8, connectionID: UUID, nonce: Data) {
        self.protocolVersion = protocolVersion
        self.connectionID = connectionID
        self.nonce = nonce
    }
}

struct AuthResponseFrame: Equatable, Sendable {
    let protocolVersion: UInt8
    let publicKeyRaw: Data
    let signatureRaw: Data
    let pairingCode: String?

    func encode() -> Data {
        var frame = AuthPreamble.responseMagic
        frame.append(protocolVersion)
        frame.append(publicKeyRaw)
        frame.append(signatureRaw)
        if let pairingCode {
            let codeBytes = Data(pairingCode.utf8)
            frame.append(UInt8(codeBytes.count))
            frame.append(codeBytes)
        }
        return frame
    }

    /// The pairing-code extension has no flag of its own. An unpaired frame
    /// ends at the signature, so the byte after it is either a code length in
    /// `PairingCode.lengths` or the first byte of the next MCP message, `{` or
    /// `[`. Anything else is a malformed extension, not an unpaired frame, and
    /// a claimed length out of range is rejected without waiting for its tail.
    ///
    /// The version byte decides only whether a well-formed frame is ours; a
    /// malformed extension is rejected whatever the version.
    static func parse(_ buffer: Data) -> AuthFrameParse<AuthResponseFrame> {
        guard !buffer.isEmpty else { return .notThisFrame }
        guard buffer.starts(with: AuthPreamble.responseMagic) else {
            return AuthPreamble.responseMagic.starts(with: buffer) ? .partial : .notThisFrame
        }
        guard buffer.count >= AuthPreamble.responseFrameLength else { return .partial }

        let base = buffer.startIndex
        let versionIndex = base + AuthPreamble.responseMagic.count
        let publicKeyStart = versionIndex + 1
        let signatureStart = publicKeyStart + AuthPreamble.publicKeyLength
        let signatureEnd = signatureStart + AuthPreamble.signatureLength

        let version = buffer[versionIndex]
        let isCurrentVersion = version == AuthPreamble.protocolVersion
        func frame(pairingCode: String?) -> AuthResponseFrame {
            AuthResponseFrame(
                protocolVersion: version,
                publicKeyRaw: Data(buffer[publicKeyStart ..< signatureStart]),
                signatureRaw: Data(buffer[signatureStart ..< signatureEnd]),
                pairingCode: pairingCode
            )
        }
        let unpaired: AuthFrameParse<AuthResponseFrame> =
            isCurrentVersion
            ? .complete(frame(pairingCode: nil), length: AuthPreamble.responseFrameLength) : .notThisFrame

        guard buffer.count > AuthPreamble.responseFrameLength else { return unpaired }

        let lengthByte = buffer[signatureEnd]
        let codeLength = Int(lengthByte)
        guard PairingCode.lengths.contains(codeLength) else {
            let startsNextMessage = lengthByte == UInt8(ascii: "{") || lengthByte == UInt8(ascii: "[")
            return startsNextMessage ? unpaired : .rejected
        }

        let codeStart = signatureEnd + AuthPreamble.responsePairingCodeLengthFieldSize
        let codeEnd = codeStart + codeLength
        guard buffer.endIndex >= codeEnd else { return .partial }
        guard let pairingCode = String(data: buffer[codeStart ..< codeEnd], encoding: .utf8), !pairingCode.isEmpty
        else { return .rejected }
        guard isCurrentVersion else { return .notThisFrame }
        return .complete(frame(pairingCode: pairingCode), length: codeEnd - base)
    }

    static func sign(
        challenge: AuthChallengeFrame,
        privateKey: P256.Signing.PrivateKey,
        pairingCode: String? = nil
    ) throws -> AuthResponseFrame {
        // The CLI validates a code before it gets here; the frame carries only
        // these lengths.
        assert(pairingCode.map(PairingCode.hasValidLength) ?? true, "unvalidated pairing code")
        let payload = AuthPreamble.signingPayload(nonce: challenge.nonce, connectionID: challenge.connectionID)
        let signature = try privateKey.signature(for: payload)
        return AuthResponseFrame(
            protocolVersion: AuthPreamble.protocolVersion,
            publicKeyRaw: privateKey.publicKey.rawRepresentation,
            signatureRaw: signature.rawRepresentation,
            pairingCode: pairingCode
        )
    }

    static func verifiedFingerprint(
        response: AuthResponseFrame,
        challenge: AuthChallengeFrame
    ) -> String? {
        guard response.protocolVersion == challenge.protocolVersion else { return nil }
        guard challenge.nonce.count == AuthPreamble.nonceLength else { return nil }
        guard response.publicKeyRaw.count == AuthPreamble.publicKeyLength else { return nil }
        guard response.signatureRaw.count == AuthPreamble.signatureLength else { return nil }

        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: response.publicKeyRaw) else {
            return nil
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: response.signatureRaw)
        else {
            return nil
        }

        let payload = AuthPreamble.signingPayload(nonce: challenge.nonce, connectionID: challenge.connectionID)
        guard publicKey.isValidSignature(signature, for: payload) else { return nil }
        return AuthPreamble.clientPublicKeyFingerprint(from: publicKey)
    }

    private init(
        protocolVersion: UInt8,
        publicKeyRaw: Data,
        signatureRaw: Data,
        pairingCode: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.publicKeyRaw = publicKeyRaw
        self.signatureRaw = signatureRaw
        self.pairingCode = pairingCode
    }
}

private extension AuthPreamble {
    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // A zeroed or half-filled nonce would make the challenge
            // replayable. Never send the buffer SecRandomCopyBytes just
            // failed on; fill it from Swift's system CSPRNG instead.
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
            }
        }
        return Data(bytes)
    }
}

private func uuidFromConnectionIDBytes(_ bytes: Data) -> UUID? {
    guard bytes.count == MemoryLayout<uuid_t>.size else { return nil }
    return bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return nil }
        let uuid = baseAddress.assumingMemoryBound(to: uuid_t.self).pointee
        return UUID(uuid: uuid)
    }
}
