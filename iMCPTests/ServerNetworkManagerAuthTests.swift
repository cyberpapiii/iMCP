import CryptoKit
import MCP
import XCTest

@testable import iMCP

/// Every connection here goes through `accept` on a real loopback socket and
/// speaks the CLI's side of the wire protocol.
final class ServerNetworkManagerAuthTests: XCTestCase {
    private var keychain: InMemoryKeychainItem!
    private var clients: [LoopbackClient] = []

    override func setUp() {
        super.setUp()
        keychain = InMemoryKeychainItem()
    }

    override func tearDown() {
        clients.forEach { $0.close() }
        clients = []
        keychain = nil
        super.tearDown()
    }

    private func storage() -> PairedClientStorage {
        keychain.pairedClientStorage
    }

    private func pair(_ key: P256.Signing.PrivateKey) throws {
        let client = PairedClient(
            fingerprint: AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey),
            label: "CLI",
            addedAt: Date()
        )
        keychain.data = try JSONEncoder().encode([client])
    }

    private func storedClients() throws -> [PairedClient] {
        guard let data = keychain.data, !data.isEmpty else { return [] }
        return try JSONDecoder().decode([PairedClient].self, from: data)
    }

    private func connect(to manager: ServerNetworkManager) async throws -> LoopbackClient {
        let client = try await LoopbackClient.connect(to: manager)
        clients.append(client)
        return client
    }

    private func assertDenied(_ client: LoopbackClient, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await client.initialize()
            XCTFail("initialize should be denied", file: file, line: line)
        } catch let error as LoopbackClient.ReplyError {
            XCTAssertEqual(
                error.message,
                "Invalid Request: iMCP connection denied. Approve the client in iMCP.",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testPairedFingerprintIsAdmittedWithoutAsking() async throws {
        let key = P256.Signing.PrivateKey()
        try pair(key)
        let prompt = ApprovalPromptRecorder(answer: .denied)
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: key)
        try await client.initialize()

        let requests = await prompt.requests
        XCTAssertEqual(requests, [])
    }

    /// A valid signature proves key ownership, nothing more. Any unpaired client
    /// can produce one, so verification alone must never skip the approval
    /// dialog. The dialog is told which key verified and the client's name,
    /// reduced to one clean line.
    func testUnknownVerifiedFingerprintIsAskedAboutWithItsKey() async throws {
        let key = P256.Signing.PrivateKey()
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: false))
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: key)
        try await client.initialize(clientName: "Claude\u{202E}\nCode")

        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.clientName, "ClaudeCode")
        XCTAssertEqual(
            requests.first?.verifiedFingerprint,
            AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey)
        )
        XCTAssertEqual(try storedClients(), [], "Approving without pairing saves nothing")
    }

    /// A client with no AUTH-RESPONSE at all is asked about, with no key to pair.
    func testClientWithoutAuthResponseIsAskedAboutWithNoKey() async throws {
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: true))
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        _ = try await client.readChallenge()
        try await client.initialize()

        let requests = await prompt.requests
        XCTAssertEqual(requests.map(\.verifiedFingerprint), [nil])
        XCTAssertEqual(try storedClients(), [], "Nothing verified, so nothing can be paired")
    }

    func testApprovingWithPairSavesTheVerifiedKey() async throws {
        let key = P256.Signing.PrivateKey()
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: true))
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: key)
        try await client.initialize(clientName: "Claude Code")

        let stored = try storedClients()
        XCTAssertEqual(stored.map(\.fingerprint), [AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey)])
        XCTAssertEqual(stored.map(\.label), ["Claude Code"])
    }

    func testDeniedClientIsRefused() async throws {
        let prompt = ApprovalPromptRecorder(answer: .denied)
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: P256.Signing.PrivateKey())
        await assertDenied(client)
        try await client.waitForClose()
    }

    func testValidPairingCodeAutoPairsClient() async throws {
        let key = P256.Signing.PrivateKey()
        let fingerprint = AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey)
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue()
        let prompt = ApprovalPromptRecorder(answer: .denied)
        let manager = await makeServerNetworkManager(storage: storage(), pairingCodes: issuer, prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: key, pairingCode: issued.code)
        // The transport settles the AUTH-RESPONSE before passing on what
        // follows it, so the reply to this ping means the code was taken.
        try await client.request("ping")

        // Pairing-code trust stays pending until the connection is admitted.
        XCTAssertEqual(try storedClients(), [])

        try await client.initialize(clientName: "Claude\u{202E}\nCode")
        let stored = try storedClients()
        XCTAssertEqual(stored.map(\.fingerprint), [fingerprint])
        // The label is the client's own name, reduced to one clean line.
        XCTAssertEqual(stored.map(\.label), ["ClaudeCode"])
        let requests = await prompt.requests
        XCTAssertEqual(requests, [], "A redeemed code skips the dialog")
    }

    /// Decision 38: a paired list that does not answer in time counts as
    /// unreadable, so the client is asked about. The lookup gives up before
    /// the setup deadline, which would otherwise close the session first.
    func testAPairedListThatDoesNotAnswerLeadsToThePrompt() async throws {
        XCTAssertLessThan(HandshakeDeadline.pairedLookup, HandshakeDeadline.setup)
        let gate = DispatchSemaphore(value: 0)
        keychain.loadGate = gate
        defer {
            keychain.loadGate = nil
            gate.signal()
        }
        let key = P256.Signing.PrivateKey()
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: false))
        let manager = await makeServerNetworkManager(
            storage: storage(),
            pairedLookup: .milliseconds(100),
            prompt: prompt.prompt
        )

        let client = try await connect(to: manager)
        try await client.authenticate(with: key)
        try await client.initialize()

        let requests = await prompt.requests
        XCTAssertEqual(
            requests.map(\.verifiedFingerprint),
            [AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey)]
        )
    }

    /// A code's pairing is saved once the connection is admitted, and the
    /// setup deadline no longer runs while it saves: a slow save cannot have
    /// the session closed after its key was written.
    func testASlowCodePairingSaveOutlastsTheSetupDeadline() async throws {
        let clock = TestClock()
        let key = P256.Signing.PrivateKey()
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue()
        let manager = await makeServerNetworkManager(
            storage: storage(),
            pairingCodes: issuer,
            clock: clock.wallClock,
            prompt: ApprovalPromptRecorder(answer: .denied).prompt
        )
        let gate = DispatchSemaphore(value: 0)
        keychain.saveGate = gate

        let client = try await connect(to: manager)
        try await client.authenticate(with: key, pairingCode: issued.code)
        let admitted = Task { try await client.initialize() }
        await keychain.waitForSaves()
        XCTAssertEqual(keychain.saves, 1, "the pairing is saving")
        clock.advance(by: HandshakeDeadline.setup)
        keychain.saveGate = nil
        gate.signal()

        _ = try await admitted.value
        try await client.request("ping")
        XCTAssertEqual(
            try storedClients().map(\.fingerprint),
            [AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey)]
        )
    }

    /// The same holds for a pairing the person approved: once answered, the
    /// session is back to setting up, and the setup deadline that passes
    /// while its key is saved does not close it.
    func testASlowApprovedPairingSaveOutlastsTheSetupDeadline() async throws {
        let clock = TestClock()
        let key = P256.Signing.PrivateKey()
        let gate = AsyncGate()
        let manager = await makeServerNetworkManager(
            storage: storage(),
            clock: clock.wallClock,
            prompt: ApprovalPromptRecorder(answer: .approved(pair: true), gate: gate).prompt
        )
        let saveGate = DispatchSemaphore(value: 0)
        keychain.saveGate = saveGate

        let client = try await connect(to: manager)
        try await client.authenticate(with: key)
        let admitted = Task { try await client.initialize() }
        await gate.waitUntilWaiting(count: 1)
        await gate.open()
        await keychain.waitForSaves()
        XCTAssertEqual(keychain.saves, 1, "the pairing is saving")
        clock.advance(by: HandshakeDeadline.setup)
        keychain.saveGate = nil
        saveGate.signal()

        _ = try await admitted.value
        try await client.request("ping")
        XCTAssertEqual(
            try storedClients().map(\.fingerprint),
            [AuthPreamble.clientPublicKeyFingerprint(from: key.publicKey)]
        )
    }

    /// A connection that redeemed a code and then went away before it was
    /// admitted leaves no paired key: the next connection with that key is
    /// asked about.
    func testDroppedConnectionLeavesNoPairingCodeTrust() async throws {
        let key = P256.Signing.PrivateKey()
        let issuer = PairingCodeIssuer()
        let issued = await issuer.issue()
        let prompt = ApprovalPromptRecorder(answer: .denied)
        let manager = await makeServerNetworkManager(storage: storage(), pairingCodes: issuer, prompt: prompt.prompt)

        let first = try await connect(to: manager)
        try await first.authenticate(with: key, pairingCode: issued.code)
        try await first.request("ping")
        first.close()

        let second = try await connect(to: manager)
        try await second.authenticate(with: key)
        await assertDenied(second)

        XCTAssertEqual(try storedClients(), [])
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1)
    }

    /// A wrong code must leave the paired list empty. Auto-pairing on a bad code
    /// would hand a permanent grant to whoever guessed at it.
    func testWrongPairingCodeDoesNotAutoPair() async throws {
        let issuer = PairingCodeIssuer()
        _ = await issuer.issue()
        let prompt = ApprovalPromptRecorder(answer: .denied)
        let manager = await makeServerNetworkManager(storage: storage(), pairingCodes: issuer, prompt: prompt.prompt)

        let client = try await connect(to: manager)
        try await client.authenticate(with: P256.Signing.PrivateKey(), pairingCode: "NOTVALID")
        await assertDenied(client)

        XCTAssertEqual(try storedClients(), [])
        let requests = await prompt.requests
        XCTAssertEqual(requests.count, 1, "A wrong code is an unpaired client, and is asked about")
    }

    /// A response that fails verification is not an unknown client; it is a
    /// broken or forged handshake, and the user must not be asked about it.
    func testInvalidSignatureIsDeniedWithoutPrompting() async throws {
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: false))
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        let client = try await connect(to: manager)
        // Another challenge carries a fresh nonce, so the signature fails.
        try await client.authenticate(
            with: P256.Signing.PrivateKey(),
            signing: AuthChallengeFrame(connectionID: UUID())
        )
        await assertDenied(client)

        let requests = await prompt.requests
        XCTAssertEqual(requests, [])
    }

    /// With every approval slot taken, one more unpaired client is denied
    /// without a prompt, and a paired client still gets straight in.
    func testFullApprovalQueueDeniesUnpairedAndAdmitsPaired() async throws {
        let pairedKey = P256.Signing.PrivateKey()
        try pair(pairedKey)
        let gate = AsyncGate()
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: false), gate: gate)
        let manager = await makeServerNetworkManager(storage: storage(), prompt: prompt.prompt)

        var waiting: [Task<Void, Error>] = []
        for _ in 0 ..< ServerNetworkManager.maxSessionsAwaitingApproval {
            let client = try await connect(to: manager)
            try await client.authenticate(with: P256.Signing.PrivateKey())
            waiting.append(Task { try await client.initialize() })
        }
        await gate.waitUntilWaiting(count: ServerNetworkManager.maxSessionsAwaitingApproval)

        let unpaired = try await connect(to: manager)
        try await unpaired.authenticate(with: P256.Signing.PrivateKey())
        await assertDenied(unpaired)
        var requests = await prompt.requests
        XCTAssertEqual(requests.count, ServerNetworkManager.maxSessionsAwaitingApproval)

        let paired = try await connect(to: manager)
        try await paired.authenticate(with: pairedKey)
        try await paired.initialize()

        await gate.open()
        for task in waiting {
            try await task.value
        }

        let retry = try await connect(to: manager)
        try await retry.authenticate(with: P256.Signing.PrivateKey())
        try await retry.initialize()
        requests = await prompt.requests
        XCTAssertEqual(requests.count, ServerNetworkManager.maxSessionsAwaitingApproval + 1)
    }

    /// Decision 49: a session the person approved stops holding an approval
    /// slot while its pairing saves, so with every other slot taken one more
    /// unpaired client is still asked about rather than denied.
    func testAnApprovedSessionSavingItsPairingFreesItsApprovalSlot() async throws {
        let gate = AsyncGate()
        let recorder = ApprovalPromptRecorder(answer: .approved(pair: false), gate: gate)
        let saverName = "Saver"
        // Later lookups queue behind the held save, so they give up quickly
        // and count as unpaired (decision 38).
        let manager = await makeServerNetworkManager(storage: storage(), pairedLookup: .milliseconds(100)) {
            request in
            request.clientName == saverName ? .approved(pair: true) : await recorder.ask(request)
        }
        let saveGate = DispatchSemaphore(value: 0)
        keychain.saveGate = saveGate
        defer {
            keychain.saveGate = nil
            saveGate.signal()
        }

        let held = ServerNetworkManager.maxSessionsAwaitingApproval - 1
        var waiting: [Task<Void, Error>] = []
        for _ in 0 ..< held {
            let client = try await connect(to: manager)
            try await client.authenticate(with: P256.Signing.PrivateKey())
            waiting.append(Task { try await client.initialize() })
        }
        await gate.waitUntilWaiting(count: held)

        let saver = try await connect(to: manager)
        try await saver.authenticate(with: P256.Signing.PrivateKey())
        let saved = Task { try await saver.initialize(clientName: saverName) }
        await keychain.waitForSaves()

        let another = try await connect(to: manager)
        try await another.authenticate(with: P256.Signing.PrivateKey())
        waiting.append(Task { try await another.initialize() })
        await gate.waitUntilWaiting(count: held + 1)

        keychain.saveGate = nil
        saveGate.signal()
        await gate.open()
        _ = try await saved.value
        for task in waiting {
            try await task.value
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, held + 1)
    }

    /// The name comes from the client and lands in a security dialog and the
    /// Clients list, so it must not be able to add lines or reorder text.
    func testSanitizedClientName() {
        let sanitized = ServerNetworkManager.sanitizedClientName
        XCTAssertEqual(sanitized("Claude Code"), "Claude Code")
        XCTAssertEqual(sanitized("a\nb\tc\u{0}d\u{202E}e\u{200B}f"), "abcdef")
        XCTAssertEqual(sanitized(String(repeating: "x", count: 200)), String(repeating: "x", count: 64))
        XCTAssertEqual(sanitized("e" + String(repeating: "\u{301}", count: 10_000)).unicodeScalars.count, 256)
        XCTAssertEqual(sanitized(""), "Unknown client")
        XCTAssertEqual(sanitized("  \n "), "Unknown client")
    }

    /// A valid signature costs a peer nothing, so a session still setting up
    /// when the setup deadline passes is closed, whatever key it showed. One
    /// on the approval prompt is spared: a person can take longer than that.
    func testTheSetupDeadlineClosesAStalledSessionButNotOneOnThePrompt() async throws {
        let clock = TestClock()
        let gate = AsyncGate()
        let prompt = ApprovalPromptRecorder(answer: .approved(pair: false), gate: gate)
        let manager = await makeServerNetworkManager(storage: storage(), clock: clock.wallClock, prompt: prompt.prompt)
        let setup = HandshakeDeadline.setup

        let asking = try await connect(to: manager)
        try await asking.authenticate(with: P256.Signing.PrivateKey())
        let admitted = Task { _ = try await asking.initialize() }
        await gate.waitUntilWaiting(count: 1)

        clock.advance(by: setup / 2)
        let stalled = try await connect(to: manager)
        try await stalled.authenticate(with: P256.Signing.PrivateKey())
        try await stalled.request("ping")

        clock.advance(by: setup / 2)
        try await stalled.request("ping")
        clock.advance(by: setup / 2)
        try await stalled.waitForClose()

        await gate.open()
        try await admitted.value
        let cancelled = await prompt.cancelledCount
        XCTAssertEqual(cancelled, 0, "The request on the prompt was never withdrawn")
    }

    /// The Connect window says "Paired with" only for a pairing a code made,
    /// so each pairing says which way it came.
    @MainActor
    func testEachPairingSaysWhetherACodeOrThePromptMadeIt() async throws {
        let store = PairedClientStore(storage: storage())
        var routes: [PairingOutcome.Route] = []
        let subscription = store.pairingOutcomes.sink { routes.append($0.route) }
        defer { subscription.cancel() }
        let issuer = PairingCodeIssuer()
        let issued = issuer.issue()
        let manager = makeServerNetworkManager(
            pairedClients: store,
            pairingCodes: issuer,
            prompt: ApprovalPromptRecorder(answer: .approved(pair: true)).prompt
        )

        let byCode = try await connect(to: manager)
        try await byCode.authenticate(with: P256.Signing.PrivateKey(), pairingCode: issued.code)
        try await byCode.initialize()
        let byPrompt = try await connect(to: manager)
        try await byPrompt.authenticate(with: P256.Signing.PrivateKey())
        try await byPrompt.initialize()
        await store.settle()

        XCTAssertEqual(routes, [.pairingCode, .approval])
    }
}
