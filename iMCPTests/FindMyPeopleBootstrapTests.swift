import CryptoKit
import Foundation
import Security
import XCTest

@testable import iMCP

final class FindMyPeopleBootstrapTests: XCTestCase {
    private let nonce = UUID(uuidString: "A1B2C3D4-1111-2222-3333-444455556666")!
    private let baselineDigest = Data(repeating: 0xA5, count: 32)
    private let installationBinding = Data(repeating: 0x5A, count: 32)
    private let databaseKey = Data(0 ..< 32)

    private func bootstrap(preparedState: InMemoryKeychainItem) -> FindMyPeopleBootstrap {
        FindMyPeopleBootstrap(
            readiness: FindMyPeopleReadiness(
                storage: peopleKeyStorage(),
                peopleEnabled: false,
                loadPeople: { _ in [] }
            ),
            keychain: FindMyPeopleBootstrap.Keychain(
                preparedState: preparedState.calls,
                installation: InMemoryKeychainItem().calls
            )
        )
    }

    /// A Keychain that refuses the read says nothing about whether setup was
    /// prepared, so it is not reported as not set up.
    func testAnUnreadablePreparedStateIsUnavailableNotNotConfigured() async {
        let missing = await bootstrap(preparedState: InMemoryKeychainItem()).state()
        XCTAssertEqual(missing, .notConfigured)

        let locked = bootstrap(preparedState: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed))
        let state = await locked.state()
        XCTAssertEqual(state, .keychainUnavailable)
        do {
            try await locked.importPreparedEnvelope()
            XCTFail("expected the import to stop")
        } catch {
            XCTAssertEqual(error as? FindMyPeopleBootstrapError, .keychainUnavailable)
        }
    }

    /// The same rule for the imported key: a Keychain that refuses it says
    /// nothing about whether setup finished, even with no handoff prepared.
    func testAnUnreadableDatabaseKeyIsUnavailableNotNotConfigured() async {
        let bootstrap = FindMyPeopleBootstrap(
            readiness: FindMyPeopleReadiness(
                storage: peopleKeyStorage(database: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)),
                peopleEnabled: false,
                loadPeople: { _ in [] }
            ),
            keychain: FindMyPeopleBootstrap.Keychain(
                preparedState: InMemoryKeychainItem().calls,
                installation: InMemoryKeychainItem().calls
            )
        )

        let state = await bootstrap.state()

        XCTAssertEqual(state, .keychainUnavailable)
    }

    /// And for the identity secret: with the key readable and the prepared
    /// handoff already cleared after an import, an identity secret the
    /// Keychain refuses is not "not set up". One that is missing is, since
    /// an import creates it.
    func testAnUnreadableIdentitySecretIsUnavailableNotNotConfigured() async {
        func state(identity: InMemoryKeychainItem) async -> FindMyPeopleBootstrapState {
            let database = InMemoryKeychainItem()
            database.data = databaseKey
            return await FindMyPeopleBootstrap(
                readiness: FindMyPeopleReadiness(
                    storage: peopleKeyStorage(database: database, identity: identity),
                    peopleEnabled: false,
                    loadPeople: { _ in [] }
                ),
                keychain: FindMyPeopleBootstrap.Keychain(
                    preparedState: InMemoryKeychainItem().calls,
                    installation: InMemoryKeychainItem().calls
                )
            ).state()
        }

        let locked = await state(identity: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed))
        XCTAssertEqual(locked, .keychainUnavailable)
        let missing = await state(identity: InMemoryKeychainItem())
        XCTAssertEqual(missing, .notConfigured)
    }

    /// A missing identity secret with the key in place is unfinished setup,
    /// which another import completes; only an unreadable one is a Keychain
    /// problem.
    func testAMissingIdentitySecretIsUnfinishedSetup() async {
        let database = InMemoryKeychainItem()
        database.data = databaseKey
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: InMemoryKeychainItem()),
            peopleEnabled: true,
            loadPeople: { _ in [] }
        )
        let missing = await readiness.state()
        XCTAssertEqual(missing, .missingKey)

        let locked = FindMyPeopleReadiness(
            storage: peopleKeyStorage(
                database: database,
                identity: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)
            ),
            peopleEnabled: true,
            loadPeople: { _ in [] }
        )
        let unavailable = await locked.state()
        XCTAssertEqual(unavailable, .identityUnavailable)
    }

    func testPayloadRoundTripBindsKeyNonceBaselineAndInstallation() throws {
        let payload = try FindMyPeopleBootstrap.encodePayload(
            databaseKey: databaseKey,
            nonce: nonce,
            baselineDigest: baselineDigest,
            installationBinding: installationBinding
        )

        XCTAssertEqual(payload.count, 120)
        let decoded = try FindMyPeopleBootstrap.decodePayload(payload)
        XCTAssertEqual(decoded.databaseKey, databaseKey)
        XCTAssertEqual(decoded.nonce, nonce)
        XCTAssertEqual(decoded.baselineDigest, baselineDigest)
        XCTAssertEqual(decoded.installationBinding, installationBinding)
    }

    func testPayloadRejectsWrongLengthMagicAndInstallation() throws {
        XCTAssertThrowsError(
            try FindMyPeopleBootstrap.encodePayload(
                databaseKey: Data(count: 31),
                nonce: nonce,
                baselineDigest: baselineDigest,
                installationBinding: installationBinding
            )
        )

        var payload = try FindMyPeopleBootstrap.encodePayload(
            databaseKey: databaseKey,
            nonce: nonce,
            baselineDigest: baselineDigest,
            installationBinding: installationBinding
        )
        payload[0] ^= 0xFF
        XCTAssertThrowsError(try FindMyPeopleBootstrap.decodePayload(payload))

        let decoded = try FindMyPeopleBootstrap.decodePayload(
            try FindMyPeopleBootstrap.encodePayload(
                databaseKey: databaseKey,
                nonce: nonce,
                baselineDigest: baselineDigest,
                installationBinding: Data(repeating: 0x77, count: 32)
            )
        )
        XCTAssertThrowsError(
            try FindMyPeopleBootstrap.validate(
                payload: decoded,
                expectedNonce: nonce,
                expectedBaselineDigest: baselineDigest,
                expectedInstallationBinding: installationBinding
            )
        )
    }

    func testRestorationRequiresNewBootAndEverySafePostureFact() throws {
        let baseline = FindMyPeopleSecurityPosture(
            fullSecurityEnabled: true,
            sipEnabled: true,
            authenticatedRootEnabled: true,
            unsafeBootArguments: [],
            developerToolsSecurityEnabled: false,
            bootSessionUUID: "boot-before"
        )
        let restored = FindMyPeopleSecurityPosture(
            fullSecurityEnabled: true,
            sipEnabled: true,
            authenticatedRootEnabled: true,
            unsafeBootArguments: [],
            developerToolsSecurityEnabled: false,
            bootSessionUUID: "boot-after"
        )
        XCTAssertNoThrow(try FindMyPeopleBootstrap.validateRestoration(baseline: baseline, current: restored))

        XCTAssertThrowsError(try FindMyPeopleBootstrap.validateRestoration(baseline: baseline, current: baseline))

        var unsafe = restored
        unsafe.unsafeBootArguments = ["amfi_get_out_of_my_way=1"]
        XCTAssertThrowsError(try FindMyPeopleBootstrap.validateRestoration(baseline: baseline, current: unsafe))

        var changedDeveloperSecurity = restored
        changedDeveloperSecurity.developerToolsSecurityEnabled = true
        XCTAssertThrowsError(
            try FindMyPeopleBootstrap.validateRestoration(
                baseline: baseline,
                current: changedDeveloperSecurity
            )
        )
    }

    func testUnsignedVerifierReportRequiresAuthenticatedManualGate() throws {
        let report = FindMyPeopleRestorationReport(
            format: FindMyPeopleBootstrap.restorationReportFormat,
            authoritative: false,
            baselineDigest: baselineDigest.hexString,
            envelopeDigest: Data(SHA256.hash(data: Data("envelope".utf8))).hexString,
            posture: FindMyPeopleSecurityPosture(
                fullSecurityEnabled: true,
                sipEnabled: true,
                authenticatedRootEnabled: true,
                unsafeBootArguments: [],
                developerToolsSecurityEnabled: false,
                bootSessionUUID: "boot-after"
            )
        )

        XCTAssertThrowsError(
            try FindMyPeopleBootstrap.validateManualImportGate(
                report: report,
                authenticatedByDeviceOwner: false
            )
        )
        XCTAssertNoThrow(
            try FindMyPeopleBootstrap.validateManualImportGate(
                report: report,
                authenticatedByDeviceOwner: true
            )
        )

        let unverifiedAuthorityClaim = FindMyPeopleRestorationReport(
            format: report.format,
            authoritative: true,
            baselineDigest: report.baselineDigest,
            envelopeDigest: report.envelopeDigest,
            posture: report.posture
        )
        XCTAssertThrowsError(
            try FindMyPeopleBootstrap.validateManualImportGate(
                report: unverifiedAuthorityClaim,
                authenticatedByDeviceOwner: false
            )
        )
    }
}

/// The bootstrap scripts keep their own copy of the artifact contract in
/// `Scripts/find_my_people_artifacts.py`, because they run under sudo and LLDB
/// where the app's code is not available. These fail when the copies drift.
final class FindMyPeopleArtifactScriptContractTests: XCTestCase {
    private static let scriptsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Scripts", isDirectory: true)

    /// The string literals of each top-level `NAME = ...` assignment.
    private func pythonConstants() throws -> [String: [String]] {
        let source = try String(
            contentsOf: Self.scriptsDirectory.appendingPathComponent("find_my_people_artifacts.py"),
            encoding: .utf8
        )
        var constants: [String: [String]] = [:]
        for line in source.split(separator: "\n") {
            guard let separator = line.range(of: " = ") else { continue }
            let name = line[..<separator.lowerBound]
            guard !name.isEmpty, name.allSatisfy({ $0.isUppercase || $0 == "_" }) else { continue }
            // Every other piece between double quotes is a literal's contents.
            let pieces = line[separator.upperBound...].split(separator: "\"", omittingEmptySubsequences: false)
            constants[String(name)] = stride(from: 1, to: pieces.count, by: 2).map { String(pieces[$0]) }
        }
        return constants
    }

    private func keys(of value: some Encodable) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    func testFormatsMagicAndFileNamesMatchTheApp() throws {
        let constants = try pythonConstants()
        XCTAssertEqual(constants["HANDOFF_FORMAT"], [FindMyPeopleBootstrap.handoffFormat])
        XCTAssertEqual(constants["ENVELOPE_FORMAT"], [FindMyPeopleBootstrap.envelopeFormat])
        XCTAssertEqual(constants["REPORT_FORMAT"], [FindMyPeopleBootstrap.restorationReportFormat])
        XCTAssertEqual(
            constants["PAYLOAD_MAGIC"],
            [String(decoding: FindMyPeopleBootstrap.payloadMagic, as: UTF8.self)]
        )

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = try XCTUnwrap(constants["ARTIFACT_DIRECTORY"]?.first)
        XCTAssertEqual(
            applicationSupport.appendingPathComponent(directory, isDirectory: true).path,
            FindMyPeopleBootstrap.artifactDirectory.path
        )
        XCTAssertEqual(constants["HANDOFF_NAME"], [FindMyPeopleBootstrap.handoffURL.lastPathComponent])
        XCTAssertEqual(constants["ENVELOPE_NAME"], [FindMyPeopleBootstrap.envelopeURL.lastPathComponent])
        XCTAssertEqual(constants["BASELINE_NAME"], [FindMyPeopleBootstrap.baselineReportURL.lastPathComponent])
        XCTAssertEqual(
            constants["RESTORATION_NAME"],
            [FindMyPeopleBootstrap.restorationReportURL.lastPathComponent]
        )
    }

    func testJSONKeysMatchTheAppsCodingKeys() throws {
        let constants = try pythonConstants()
        let handoff = FindMyPeopleBootstrap.Handoff(
            format: FindMyPeopleBootstrap.handoffFormat,
            nonce: UUID(),
            baselineDigest: "",
            installationBinding: "",
            preparedAt: Date(),
            publicKeyPEM: ""
        )
        XCTAssertEqual(
            try keys(of: handoff),
            Set(try XCTUnwrap(constants["HANDOFF_KEYS"]) + XCTUnwrap(constants["HANDOFF_OPTIONAL_KEYS"]))
        )

        let envelope = FindMyPeopleBootstrap.Envelope(
            format: FindMyPeopleBootstrap.envelopeFormat,
            nonce: UUID(),
            baselineDigest: "",
            installationBinding: "",
            ciphertext: ""
        )
        XCTAssertEqual(try keys(of: envelope), Set(try XCTUnwrap(constants["ENVELOPE_KEYS"])))

        let posture = FindMyPeopleSecurityPosture(
            fullSecurityEnabled: true,
            sipEnabled: true,
            authenticatedRootEnabled: true,
            unsafeBootArguments: [],
            developerToolsSecurityEnabled: false,
            bootSessionUUID: ""
        )
        let report = FindMyPeopleRestorationReport(
            format: FindMyPeopleBootstrap.restorationReportFormat,
            authoritative: false,
            baselineDigest: "",
            envelopeDigest: "",
            posture: posture
        )
        XCTAssertEqual(try keys(of: report), Set(try XCTUnwrap(constants["REPORT_KEYS"])))
        XCTAssertEqual(try keys(of: posture), Set(try XCTUnwrap(constants["POSTURE_KEYS"])))
    }

    func testObserverWatchesTheDatabasesTheProviderReads() throws {
        let observer = try String(
            contentsOf: Self.scriptsDirectory.appendingPathComponent("observe-find-my-people.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(observer.contains("${DARWIN_DIR}\(LocalStoragePeopleProvider.confinementSubPath)\""))
        XCTAssertTrue(observer.contains("${HOME}/\(LocalStoragePeopleProvider.groupContainerRelativePath)\""))
    }

    /// The capture joins the payload's fields in `payload_for`; the app reads
    /// them at `FindMyPeopleBootstrapPayload.Layout`. Same order, no gaps.
    func testThePayloadLayoutMatchesTheCapturesFieldOrder() throws {
        let source = try String(
            contentsOf: Self.scriptsDirectory.appendingPathComponent("find_my_people_artifacts.py"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "def payload_for(handoff, key):"))
        let body = source[start.upperBound...]
        let end = body.range(of: "\ndef ")?.lowerBound ?? body.endIndex
        let function = String(body[..<end])
        let fields = [
            "PAYLOAD_MAGIC", "handoff[\"nonce\"]", "handoff[\"baseline_digest\"]",
            "handoff[\"installation_binding\"]", "key,",
        ]
        let positions = try fields.map { try XCTUnwrap(function.range(of: $0)?.lowerBound, $0) }
        XCTAssertEqual(positions, positions.sorted(), "the capture writes the fields in this order")

        typealias Layout = FindMyPeopleBootstrapPayload.Layout
        let ranges = [
            Layout.magic, Layout.nonce, Layout.baselineDigest, Layout.installationBinding, Layout.databaseKey,
        ]
        XCTAssertEqual(ranges.map(\.count), [FindMyPeopleBootstrap.payloadMagic.count, 16, 32, 32, 32])
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(left.upperBound, right.lowerBound)
        }
        XCTAssertEqual(Layout.length, 120)
    }
}
