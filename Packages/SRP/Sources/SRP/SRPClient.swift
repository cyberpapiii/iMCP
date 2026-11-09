import CommonCrypto
import CryptoKit
import Foundation

/// How Apple wants the password stretched before it enters the SRP exchange.
/// The server names the variant in its `signin/init` response.
public enum SRPPasswordProtocol: String, Sendable {
    case s2k
    case s2kFO = "s2k_fo"

    /// Sent on `signin/init` so the server can pick one.
    public static var offered: [String] { [s2k.rawValue, s2kFO.rawValue] }
}

public enum SRPError: Swift.Error, Equatable {
    /// The server's public value is a multiple of N, which zeroes the shared
    /// secret. RFC 5054 requires aborting rather than continuing.
    case degenerateServerKey
    /// The scrambling parameter came out zero, which also collapses the secret.
    case degenerateScrambler
    case malformedGroup
    /// The system random generator failed. A secret it did not fill would be
    /// a known constant, so the exchange must not start.
    case randomUnavailable
    /// CommonCrypto refused to stretch the password.
    case derivationFailed
}

/// SRP-6a as Apple's identity service speaks it: the RFC 5054 2048-bit group,
/// SHA-256, RFC 5054 operand padding, and no username mixed into `x`.
///
/// Stock SRP-6a differs on that last point — it derives `x` from
/// `H(salt ‖ H(username ‖ ":" ‖ password))`. Apple omits the username, which is
/// why this is implemented here rather than taken off the shelf.
public struct SRPClient {
    /// RFC 5054, appendix A, 2048-bit group.
    static let groupModulusHex = """
        AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050\
        A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50\
        E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8\
        55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B\
        CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748\
        544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6\
        AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6\
        94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73
        """

    /// The proof pair the client sends to `signin/complete`.
    public struct Proof: Equatable {
        public let m1: Data
        public let m2: Data
    }

    public let accountName: String

    private let field: SRPModulus
    private let generator = BigUInt(2)
    private let secretA: BigUInt
    private let publicA: BigUInt

    /// The client's public ephemeral value, base64 of which is the `a` field on
    /// `signin/init`.
    public var publicKey: Data { publicA.bigEndianBytes }

    /// `privateKey` exists so tests can replay a published vector. Production
    /// passes nil and gets 2048 fresh random bits with the top one set, which
    /// is what the reference clients do.
    public init(accountName: String, privateKey: Data? = nil) throws {
        let modulus = BigUInt(hexadecimal: Self.groupModulusHex)
        guard let field = SRPModulus(modulus: modulus) else { throw SRPError.malformedGroup }
        self.field = field
        self.accountName = accountName

        if let privateKey {
            self.secretA = BigUInt(bigEndianBytes: privateKey)
        } else {
            var bytes = [UInt8](repeating: 0, count: field.byteCount)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw SRPError.randomUnavailable
            }
            bytes[0] |= 0x80
            self.secretA = BigUInt(bigEndianBytes: bytes)
        }
        self.publicA = field.power(generator, secretA)
    }

    /// Stretches the password exactly as Apple's web client does. The result,
    /// not the password, is what enters the SRP exchange.
    public static func derivedPassword(
        password: String,
        salt: Data,
        iterations: Int,
        protocol passwordProtocol: SRPPasswordProtocol
    ) throws -> Data {
        let digest = Data(SHA256.hash(data: Data(password.utf8)))
        let material: Data
        switch passwordProtocol {
        case .s2k:
            material = digest
        case .s2kFO:
            material = Data(digest.map { String(format: "%02x", $0) }.joined().utf8)
        }

        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = material.withUnsafeBytes { materialBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                materialBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                materialBuffer.count,
                saltBytes,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else { throw SRPError.derivationFailed }
        return Data(derived)
    }

    /// `derivedPassword` comes from `derivedPassword(password:…)`.
    public func proof(salt: Data, serverPublicKey: Data, derivedPassword: Data) throws -> Proof {
        let width = field.byteCount
        let n = field.modulus
        let b = BigUInt(bigEndianBytes: serverPublicKey)
        // RFC 5054 aborts when B is a multiple of N. Rejecting anything not
        // already reduced covers that and is stricter: a well-formed server
        // never sends B outside [1, N).
        guard !b.isZero, BigUInt.compare(b, n) < 0 else {
            throw SRPError.degenerateServerKey
        }

        let k = BigUInt(
            bigEndianBytes: Data(
                SHA256.hash(
                    data: n.bigEndianBytes(paddedTo: width)
                        + generator.bigEndianBytes(paddedTo: width)
                )
            )
        )
        let u = BigUInt(
            bigEndianBytes: Data(
                SHA256.hash(
                    data: publicA.bigEndianBytes(paddedTo: width)
                        + b.bigEndianBytes(paddedTo: width)
                )
            )
        )
        guard !u.isZero else { throw SRPError.degenerateScrambler }

        // No username in the inner hash. That is the Apple-specific deviation.
        let inner = Data(SHA256.hash(data: Data(":".utf8) + derivedPassword))
        let x = BigUInt(bigEndianBytes: Data(SHA256.hash(data: salt + inner)))

        let v = field.power(generator, x)
        let base = field.subtract(b, field.multiply(k, v))
        let exponent = secretA + u * x
        let sharedSecret = field.power(base, exponent)

        let sessionKey = Data(SHA256.hash(data: sharedSecret.bigEndianBytes))

        var m1 = SHA256()
        m1.update(data: hashOfModulusXorGenerator(width: width))
        m1.update(data: Data(SHA256.hash(data: Data(accountName.utf8))))
        m1.update(data: salt)
        m1.update(data: publicA.bigEndianBytes)
        m1.update(data: b.bigEndianBytes)
        m1.update(data: sessionKey)
        let clientProof = Data(m1.finalize())

        var m2 = SHA256()
        m2.update(data: publicA.bigEndianBytes)
        m2.update(data: clientProof)
        m2.update(data: sessionKey)

        return Proof(m1: clientProof, m2: Data(m2.finalize()))
    }

    private func hashOfModulusXorGenerator(width: Int) -> Data {
        let hashedModulus = Data(SHA256.hash(data: field.modulus.bigEndianBytes))
        let hashedGenerator = Data(SHA256.hash(data: generator.bigEndianBytes(paddedTo: width)))
        return Data(zip(hashedModulus, hashedGenerator).map { $0 ^ $1 })
    }
}
