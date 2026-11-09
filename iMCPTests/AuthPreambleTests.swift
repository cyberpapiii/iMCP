import CryptoKit
import XCTest

@testable import iMCP

final class AuthPreambleTests: XCTestCase {
    private let connectionID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    func testChallengeFrameRoundTrip() {
        let nonce = Data(repeating: 0xAB, count: AuthPreamble.nonceLength)
        let challenge = AuthChallengeFrame(connectionID: connectionID, nonce: nonce)
        XCTAssertEqual(
            AuthChallengeFrame.parse(challenge.encode()),
            .complete(challenge, length: AuthPreamble.challengeFrameLength)
        )
    }

    func testResponseFrameRoundTrip() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)
        XCTAssertEqual(
            AuthResponseFrame.parse(response.encode()),
            .complete(response, length: AuthPreamble.responseFrameLength)
        )
    }

    /// A pairing code makes the response frame variable length. If the parsed
    /// length disagreed with the encoded size by even a byte, the
    /// frame scanner would leave that byte in front of the next MCP message.
    func testResponseFrameWithPairingCodeRoundTrip() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let response = try AuthResponseFrame.sign(
            challenge: challenge,
            privateKey: privateKey,
            pairingCode: "PAIR42"
        )
        let parsed = AuthResponseFrame.parse(response.encode())

        XCTAssertEqual(parsed, .complete(response, length: response.encode().count))
        XCTAssertEqual(parsed.frame?.pairingCode, "PAIR42")
    }

    func testValidSignatureVerifies() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)

        let fingerprint = AuthResponseFrame.verifiedFingerprint(response: response, challenge: challenge)
        XCTAssertEqual(fingerprint, AuthPreamble.clientPublicKeyFingerprint(from: privateKey.publicKey))
    }

    /// The nonce is what makes the handshake unreplayable. If a signature over
    /// yesterday's nonce still verified, a captured response would let anyone
    /// impersonate a paired client.
    func testWrongNonceFailsVerification() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let otherChallenge = AuthChallengeFrame(
            connectionID: connectionID,
            nonce: Data(repeating: 0x01, count: AuthPreamble.nonceLength)
        )
        let response = try AuthResponseFrame.sign(challenge: otherChallenge, privateKey: privateKey)

        XCTAssertNil(AuthResponseFrame.verifiedFingerprint(response: response, challenge: challenge))
    }

    /// The connection ID is signed too, so a response captured on one connection
    /// cannot be spliced into another that happens to share a nonce.
    func testWrongConnectionContextFailsVerification() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let otherConnection = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let otherChallenge = AuthChallengeFrame(connectionID: otherConnection)
        let response = try AuthResponseFrame.sign(challenge: otherChallenge, privateKey: privateKey)

        XCTAssertNil(AuthResponseFrame.verifiedFingerprint(response: response, challenge: challenge))
    }

    /// Swaps the public key inside an otherwise valid frame. Verification reads
    /// the key from the frame the attacker controls, so it must check the
    /// signature against that key rather than take the claimed identity on trust.
    func testWrongKeyFailsVerification() throws {
        let signingKey = P256.Signing.PrivateKey()
        let otherKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: signingKey)

        var encoded = response.encode()
        let publicKeyStart = AuthPreamble.responseMagic.count + 1
        encoded.replaceSubrange(
            publicKeyStart ..< (publicKeyStart + AuthPreamble.publicKeyLength),
            with: otherKey.publicKey.rawRepresentation
        )
        let tampered = try XCTUnwrap(AuthResponseFrame.parse(encoded).frame)

        XCTAssertNil(AuthResponseFrame.verifiedFingerprint(response: tampered, challenge: challenge))
    }

    /// Fingerprints are persisted in the paired-client list and printed by
    /// `imcp-server --fingerprint`. Changing the hash input or the hex casing
    /// unpairs every client on the machine.
    /// A fixed key and the SHA-256 of its raw public key, computed outside
    /// this code.
    func testFingerprintIsAKnownAnswerForAFixedKey() throws {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: Data(1 ... 32))
        XCTAssertEqual(
            AuthPreamble.clientPublicKeyFingerprint(from: privateKey.publicKey),
            "ca5f30154a8f7c61be95000c3842be20363b9ac6a7708c3a1e8239b42ba64335"
        )
    }

    func testPairingCodeLengthsSixThroughEightRoundTrip() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        for pairingCode in ["PAIR42", "PAIR427", "PAIR4278"] {
            let response = try AuthResponseFrame.sign(
                challenge: challenge,
                privateKey: privateKey,
                pairingCode: pairingCode
            )
            let parsed = AuthResponseFrame.parse(response.encode())

            XCTAssertEqual(parsed, .complete(response, length: response.encode().count), pairingCode)
            XCTAssertEqual(parsed.frame?.pairingCode, pairingCode, pairingCode)
        }
    }

    /// Length 0 / 1 / 20 is a complete pairing-code extension, not an unpaired
    /// frame. Returning a success here would make the scanner drop only the
    /// fixed prefix and leave the claimed tail for the MCP scanner.
    func testOutOfRangePairingCodeLengthReturnsNil() {
        for length in [0, 1, 20] {
            var frame = responseFramePrefix()
            frame.append(UInt8(length))
            frame.append(Data(repeating: 0x41, count: length))

            XCTAssertEqual(
                AuthResponseFrame.parse(frame),
                .rejected,
                "length \(length) must be rejected, not wait for a claimed tail"
            )
        }
    }

    /// The length byte is enough to reject. Waiting for an attacker-chosen
    /// tail would both delay teardown and treat that length as authoritative.
    func testOutOfRangeLengthByteAloneIsRejectedCompleteFrame() {
        for length in [0, 1, 20] {
            var frame = responseFramePrefix()
            frame.append(UInt8(length))

            XCTAssertEqual(AuthResponseFrame.parse(frame), .rejected, "length \(length)")
        }
    }

    func testInvalidUTF8PairingCodeIsRejectedCompleteFrame() {
        var frame = responseFramePrefix()
        frame.append(UInt8(6))
        frame.append(Data(repeating: 0xFF, count: 6))

        XCTAssertEqual(AuthResponseFrame.parse(frame), .rejected)
    }

    /// Unpaired AUTH-RESPONSE has no length byte. The next byte is the start
    /// of MCP (`{`), not a pairing-code length, so the frame still parses as
    /// unpaired and its length stays the fixed prefix.
    func testUnpairedResponseFollowedByMCPStillParses() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: connectionID)
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)
        let encoded = response.encode() + Data("{\"auth\":\"ok\"}\n".utf8)
        let parsed = AuthResponseFrame.parse(encoded)
        let decoded = try XCTUnwrap(parsed.frame)

        XCTAssertNil(decoded.pairingCode)
        XCTAssertEqual(decoded.publicKeyRaw, response.publicKeyRaw)
        XCTAssertEqual(parsed, .complete(decoded, length: AuthPreamble.responseFrameLength))
    }

    func testInRangePairingCodeLengthWaitsForCodeBytes() {
        var frame = responseFramePrefix()
        frame.append(6)

        XCTAssertEqual(AuthResponseFrame.parse(frame), .partial)
    }

    private func responseFramePrefix() -> Data {
        var frame = AuthPreamble.responseMagic
        frame.append(AuthPreamble.protocolVersion)
        frame.append(Data(repeating: 0x11, count: AuthPreamble.publicKeyLength))
        frame.append(Data(repeating: 0x22, count: AuthPreamble.signatureLength))
        return frame
    }
}
