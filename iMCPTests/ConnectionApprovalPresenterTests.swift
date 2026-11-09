import Combine
import XCTest

@testable import iMCP

/// The presenter answers every request it is handed exactly once: by the
/// person, or with a denial when the asking task is cancelled, whether the
/// request is on the window, waiting behind it, or not yet asked.
@MainActor
final class ConnectionApprovalPresenterTests: XCTestCase {
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let idC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private let fingerprint = "abcdef0123456789abcdef"

    private var window: ConnectionApprovalWindowController!
    private var outcomes: PassthroughSubject<PairingOutcome, Never>!
    private var clock: TestClock!
    private var presenter: ConnectionApprovalPresenter!

    override func setUp() async throws {
        window = ConnectionApprovalWindowController(activation: .inert)
        outcomes = PassthroughSubject()
        clock = TestClock()
        presenter = ConnectionApprovalPresenter(
            window: window,
            timeout: PhaseDeadline.approvalPrompt,
            clock: clock.wallClock,
            pairingOutcomes: outcomes.eraseToAnyPublisher()
        )
    }

    override func tearDown() async throws {
        window.dismissActiveApproval()
        presenter = nil
        outcomes = nil
        window = nil
    }

    private func ask(_ id: UUID, fingerprint: String? = nil) -> Task<ApprovalAnswer, Never> {
        let request = ConnectionApprovalRequest(
            connectionID: id,
            clientName: "Client",
            verifiedFingerprint: fingerprint
        )
        let presenter = presenter!
        return Task { await presenter.present(request) }
    }

    /// Returns once the window shows a prompt `matching`.
    private func waitForPrompt(_ matching: @escaping (ConnectionApprovalPrompt?) -> Bool) async {
        let shown = expectation(description: "prompt")
        shown.assertForOverFulfill = false
        let subscription = window.model.$prompt.sink { if matching($0) { shown.fulfill() } }
        await fulfillment(of: [shown], timeout: 5)
        subscription.cancel()
    }

    private func waitUntilAsking(_ id: UUID, count: String? = nil) async {
        await waitForPrompt { $0?.request.connectionID == id && $0?.phase == .asking && $0?.countText == count }
    }

    func testThePersonsAnswerReachesTheAsker() async {
        let a = ask(idA)
        await waitUntilAsking(idA)

        window.approve(pair: false)

        let answer = await a.value
        XCTAssertEqual(answer, .approved(pair: false))
        XCTAssertFalse(window.isOpen)
    }

    func testCancellingTheRequestOnShowDeniesItAndClosesThePrompt() async {
        let a = ask(idA)
        await waitUntilAsking(idA)

        a.cancel()

        let answer = await a.value
        XCTAssertEqual(answer, .denied)
        XCTAssertFalse(window.isOpen)
    }

    func testCancellingAQueuedRequestLeavesTheOneOnShow() async {
        let a = ask(idA)
        await waitUntilAsking(idA)
        let b = ask(idB)
        await waitUntilAsking(idA, count: "1 of 2")

        b.cancel()
        let answerB = await b.value
        XCTAssertEqual(answerB, .denied)
        await waitUntilAsking(idA, count: nil)
        XCTAssertTrue(window.isOpen)

        window.approve(pair: false)
        let answerA = await a.value
        XCTAssertEqual(answerA, .approved(pair: false))
    }

    /// Answering the request on show brings up the next one, which is then
    /// the person's to answer, never declined on their behalf.
    func testAnsweringTheRequestOnShowAsksAboutTheNext() async {
        let a = ask(idA)
        await waitUntilAsking(idA)
        let b = ask(idB)
        await waitUntilAsking(idA, count: "1 of 2")

        window.approve(pair: false)
        let answerA = await a.value
        XCTAssertEqual(answerA, .approved(pair: false))
        await waitUntilAsking(idB, count: "2 of 2")
        XCTAssertTrue(window.isOpen)

        window.approve(pair: false)
        let answerB = await b.value
        XCTAssertEqual(answerB, .approved(pair: false))
        XCTAssertFalse(window.isOpen)
    }

    func testCancellingTheRequestOnShowBringsUpTheNext() async {
        let a = ask(idA)
        await waitUntilAsking(idA)
        let b = ask(idB)
        await waitUntilAsking(idA, count: "1 of 2")

        a.cancel()
        let answerA = await a.value
        XCTAssertEqual(answerA, .denied)
        await waitUntilAsking(idB, count: "2 of 2")

        window.deny()
        let answerB = await b.value
        XCTAssertEqual(answerB, .denied)
        XCTAssertFalse(window.isOpen)
    }

    /// What a listener restart does: every request still waiting is
    /// withdrawn at once, each is answered once, and the next client is
    /// asked about as usual.
    func testWithdrawingEveryRequestAnswersEachOnceAndLeavesThePresenterWorking() async {
        let tasks = [ask(idA)]
        await waitUntilAsking(idA)
        let all = tasks + [ask(idB), ask(idC)]
        await waitUntilAsking(idA, count: "1 of 3")

        all.forEach { $0.cancel() }
        for task in all {
            let answer = await task.value
            XCTAssertEqual(answer, .denied)
        }
        XCTAssertFalse(window.isOpen)

        let next = ask(UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!)
        await waitForPrompt { $0?.phase == .asking && $0?.countText == nil }
        window.approve(pair: false)
        let answer = await next.value
        XCTAssertEqual(answer, .approved(pair: false))
    }

    func testARequestWithdrawnBeforeItIsAskedIsDeniedAndNeverShown() async {
        let a = ask(idA)
        a.cancel()

        let answer = await a.value
        XCTAssertEqual(answer, .denied)
        XCTAssertNil(window.model.prompt)
    }

    func testApprovingWithPairSaysPairedOnceTheStoreHasTheClient() async {
        let a = ask(idA, fingerprint: fingerprint)
        await waitUntilAsking(idA)

        window.approve(pair: true)
        let answer = await a.value
        XCTAssertEqual(answer, .approved(pair: true))
        XCTAssertTrue(window.isOpen, "The window waits to hear whether the client is paired")
        XCTAssertEqual(window.model.prompt?.phase, .answered)

        outcomes.send(PairingOutcome(fingerprint: "someone else", client: nil, route: .approval))
        XCTAssertEqual(window.model.prompt?.phase, .answered)

        let client = PairedClient(fingerprint: fingerprint, label: "Client", addedAt: Date())
        outcomes.send(PairingOutcome(fingerprint: fingerprint, client: client, route: .approval))
        XCTAssertEqual(window.model.prompt?.phase, .paired)
    }

    func testApprovingWithPairClosesWhenTheClientCouldNotBePaired() async {
        let a = ask(idA, fingerprint: fingerprint)
        await waitUntilAsking(idA)

        window.approve(pair: true)
        _ = await a.value
        outcomes.send(PairingOutcome(fingerprint: fingerprint, client: nil, route: .approval))

        XCTAssertFalse(window.isOpen)
    }

    func testAClientWithNoVerifiedKeyIsNotPaired() async {
        let a = ask(idA, fingerprint: nil)
        await waitUntilAsking(idA)

        window.approve(pair: true)

        let answer = await a.value
        XCTAssertEqual(answer, .approved(pair: false))
        XCTAssertFalse(window.isOpen)
    }

    func testThePromptShowsTheRequestsKeyAndDeadline() async {
        let a = ask(idA, fingerprint: fingerprint)
        await waitUntilAsking(idA)
        defer { a.cancel() }

        let prompt = window.model.prompt
        XCTAssertEqual(prompt?.request.verifiedFingerprint, fingerprint)
        XCTAssertEqual(prompt?.deadline, clock.wallClock.date(after: PhaseDeadline.approvalPrompt))
    }

    /// Nobody answering in time declines the request, and the window stays
    /// to say so; the request waiting behind it is untouched until then.
    func testARequestNobodyAnswersIsDeclinedAtItsDeadline() async {
        let a = ask(idA)
        await waitUntilAsking(idA)
        clock.advance(by: PhaseDeadline.approvalPrompt - .seconds(1))
        XCTAssertEqual(window.model.prompt?.phase, .asking)

        clock.advance(by: 1)
        let answer = await a.value
        XCTAssertEqual(answer, .denied)
        await waitForPrompt { $0?.request.connectionID == self.idA && $0?.phase == .timedOut }
    }
}
