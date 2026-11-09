@testable import SRP
import XCTest

@testable import iMCP

final class ICloudSRPTests: XCTestCase {
    /// A fixed private key, salt, and server public value, run through the
    /// reference SRP-6a client that Apple's own flow is modelled on
    /// (`cocagne/pysrp` with `rfc5054_enable()` and `no_username_in_x()`).
    /// Both proofs must match byte for byte or sign-in fails, and repeated
    /// failures lock the Apple ID — so this vector is the gate on the
    /// arithmetic, not a smoke test.
    private enum Vector {
        static let accountName = "someone@example.com"
        static let salt = Data((0 ..< 16).map { UInt8($0) })
        static let iterations = 20
        static let password = "correct horse battery staple"

        static var privateKey: Data {
            var bytes = (0 ..< 256).map { UInt8((($0 * 7) + 3) % 256) }
            bytes[0] |= 0x80
            return Data(bytes)
        }

        static let derivedPassword =
            "f01b6baac02e28af9a52fca86f8a2a68623edfe477bf527e99f59c19d0cbe76e"
        static let publicKey = """
            89cbe9be8494daa5048d9ea6317a2d19ef7c35803c9acbfaf4edef2277de7e77\
            c5364f5601e7d0dbed7ee45cd2d7862812b1516c0abb2095f26f4e5f4bddff66\
            4d9175a8bf1fbf67e62b88be7fcc8bfd8f1a2559951036d5184365d1b688b52a\
            67d539d68f2773e85ced4d74fd41f9e03b7bd1e54f14919b62b113bbbd0422eb\
            9409aeab68c3ae9a9623a16d482436f11b027746def608efd7b743c98bcbd52e\
            049d428b90cac0d71c112499c2898491e8e5e3e7153012f8cb022d249bfd2af0\
            df955b8bce298417b6b0359ff811becde0035fe39c04acef7a9ab768f6befae0\
            b3851046b2159196f09b93f68e528a50a9fadb4ffdf1f360f09d38805f77477e
            """
        static let serverPublicKey = """
            9601690fb600ab3127fdc53f94c30cc3924bdd4ba2b742bbed7594909df1e39b\
            8aa0164b732b411892b86f3bd45807bd71ee759e70f8149d0765ed4c2085b128\
            7970442cb3df7f2ef48630abdd5eee3b8c2ff6687cfa09baad26485b80a3dd8d\
            bc63cca65de4c8096fdbabb78e4e1beb302fda134bbc7568e8087bbe6f195998\
            6c36843257d66627fab2772d77a1de76f931cc6b2ec54a7f5c389dd6cc169c27\
            0afd5788b7683dc6c0f2243c974699ee8a817999363adce0683aeaf5e049c779\
            01da17942dca16f8008b8a9d0042b65886c62b7c27f15786726b074ce1544de2\
            d6f0da586ca2a297e944c3fc6ffbb9c0cf0eae251eaa4f4e2e53b05504bc2abc
            """
        static let m1 = "54c718c814d39210e3ba174ee37e7e5f9798988c88d3a42b193415fa58b0f335"
        static let m2 = "5ad9e30ac9c8c2aedf9a1349921fe2c09473907d55b6ce205afc8c21bcb94f82"
    }

    func testDerivedPasswordMatchesReferenceVector() throws {
        let derived = try SRPClient.derivedPassword(
            password: Vector.password,
            salt: Vector.salt,
            iterations: Vector.iterations,
            protocol: .s2kFO
        )
        XCTAssertEqual(derived.hexadecimalString, Vector.derivedPassword)
    }

    /// `s2k_fo` hex-encodes the password digest before stretching it; `s2k`
    /// stretches the raw digest. Picking the wrong one still produces 32 bytes,
    /// so nothing but a differing result catches the mistake.
    func testPasswordProtocolsDeriveDifferentKeys() throws {
        let plain = try SRPClient.derivedPassword(
            password: Vector.password,
            salt: Vector.salt,
            iterations: Vector.iterations,
            protocol: .s2k
        )
        XCTAssertNotEqual(plain.hexadecimalString, Vector.derivedPassword)
    }

    func testPublicKeyMatchesReferenceVector() throws {
        let client = try SRPClient(
            accountName: Vector.accountName,
            privateKey: Vector.privateKey
        )
        XCTAssertEqual(client.publicKey.hexadecimalString, Vector.publicKey)
    }

    func testProofMatchesReferenceVector() throws {
        let client = try SRPClient(
            accountName: Vector.accountName,
            privateKey: Vector.privateKey
        )
        let proof = try client.proof(
            salt: Vector.salt,
            serverPublicKey: Data(hexadecimalString: Vector.serverPublicKey),
            derivedPassword: Data(hexadecimalString: Vector.derivedPassword)
        )
        XCTAssertEqual(proof.m1.hexadecimalString, Vector.m1)
        XCTAssertEqual(proof.m2.hexadecimalString, Vector.m2)
    }

    /// A server public value of zero, or of N itself, zeroes the shared secret.
    /// RFC 5054 requires aborting rather than proceeding with a secret an
    /// attacker knows.
    func testDegenerateServerKeysAreRejected() throws {
        let client = try SRPClient(
            accountName: Vector.accountName,
            privateKey: Vector.privateKey
        )
        let derived = Data(hexadecimalString: Vector.derivedPassword)

        for serverKey in [Data(repeating: 0, count: 256), Data(hexadecimalString: SRPClient.groupModulusHex)] {
            XCTAssertThrowsError(
                try client.proof(
                    salt: Vector.salt,
                    serverPublicKey: serverKey,
                    derivedPassword: derived
                )
            ) { error in
                XCTAssertEqual(error as? SRPError, .degenerateServerKey)
            }
        }
    }

    func testEachClientGetsAFreshPrivateKey() throws {
        let first = try SRPClient(accountName: Vector.accountName)
        let second = try SRPClient(accountName: Vector.accountName)
        XCTAssertNotEqual(first.publicKey, second.publicKey)
        // A is a residue mod N, so its big-endian form loses a byte whenever
        // the top one happens to be zero — about one client in 256. Asserting
        // an exact width here made this test fail at that rate. The reference
        // clients Apple's server is built against send the trimmed value too,
        // so the width is a range, not a constant.
        XCTAssertTrue((255 ... 256).contains(first.publicKey.count))
    }

    // MARK: - Arithmetic

    func testBigUIntRoundTripsBigEndianBytes() {
        let bytes = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(BigUInt(bigEndianBytes: bytes).bigEndianBytes, bytes)
    }

    /// Leading zeroes are dropped, matching the reference client whose
    /// transcript hash this feeds. Padding is explicit and separate.
    func testBigUIntDropsLeadingZeroesButPadsOnRequest() {
        let value = BigUInt(bigEndianBytes: Data([0x00, 0x00, 0xAB]))
        XCTAssertEqual(value.bigEndianBytes, Data([0xAB]))
        XCTAssertEqual(value.bigEndianBytes(paddedTo: 4), Data([0, 0, 0, 0xAB]))
        XCTAssertEqual(BigUInt().bigEndianBytes, Data())
    }

    func testModularExponentiationMatchesKnownValues() throws {
        let field = try XCTUnwrap(SRPModulus(modulus: BigUInt(hexadecimal: "F7")))
        // 5^117 mod 247 == 96, small enough to check against a calculator.
        XCTAssertEqual(field.power(BigUInt(5), BigUInt(117)), BigUInt(96))
        XCTAssertEqual(field.power(BigUInt(5), BigUInt(0)), BigUInt(1))
        XCTAssertEqual(field.multiply(BigUInt(200), BigUInt(200)), BigUInt(40000 % 247))
        XCTAssertEqual(field.subtract(BigUInt(3), BigUInt(10)), BigUInt(240))
    }

    func testEvenModulusIsRejected() {
        XCTAssertNil(SRPModulus(modulus: BigUInt(246)))
    }
}

extension Data {
    fileprivate var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    fileprivate init(hexadecimalString: String) {
        var bytes: [UInt8] = []
        var pair = ""
        for character in hexadecimalString where !character.isWhitespace {
            pair.append(character)
            if pair.count == 2 {
                bytes.append(UInt8(pair, radix: 16) ?? 0)
                pair = ""
            }
        }
        self.init(bytes)
    }
}
