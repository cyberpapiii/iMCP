import SwiftUI
@testable import iMCP
import XCTest

@MainActor
final class ConnectionApprovalPromptTests: XCTestCase {
    private let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func prompt(_ id: UUID, fingerprint: String? = "abcdef0123456789abcdef") -> ConnectionApprovalPrompt {
        ConnectionApprovalPrompt(
            request: ConnectionApprovalRequest(
                connectionID: id,
                clientName: "Client",
                verifiedFingerprint: fingerprint
            ),
            deadline: start.addingTimeInterval(120)
        )
    }

    func testNoticeCountsDownInRoundWords() {
        let asking = prompt(idA)
        XCTAssertEqual(asking.notice(at: start), "Declines automatically in about 2 minutes.")
        XCTAssertEqual(asking.notice(at: start.addingTimeInterval(30)), "Declines automatically in about a minute.")
        XCTAssertEqual(asking.notice(at: start.addingTimeInterval(70)), "Declines automatically in about 50 seconds.")
        XCTAssertEqual(asking.notice(at: start.addingTimeInterval(79)), "Declines automatically in about 50 seconds.")
        XCTAssertEqual(asking.notice(at: start.addingTimeInterval(115)), "Declines automatically in about 10 seconds.")
    }

    func testNoticeIsRewordedNoMoreOftenThanEveryTenSeconds() {
        XCTAssertEqual(ConnectionApprovalPrompt.nextNoticeChange(after: 120), 10)
        XCTAssertEqual(ConnectionApprovalPrompt.nextNoticeChange(after: 95.5), 5.5)
        XCTAssertEqual(ConnectionApprovalPrompt.nextNoticeChange(after: 90.25), 10.25)
        for remaining in stride(from: 0.5, through: 120, by: 0.5) {
            XCTAssertGreaterThanOrEqual(ConnectionApprovalPrompt.nextNoticeChange(after: remaining), 1)
        }
    }

    func testATimedOutRequestSaysItWasDeclined() {
        var timedOut = prompt(idA)
        timedOut.phase = .timedOut
        XCTAssertEqual(timedOut.notice(at: start.addingTimeInterval(120)), "Declined, no answer.")
    }

    func testCountShowsOnlyWhenSeveralClientsAsk() {
        var one = prompt(idA)
        XCTAssertNil(one.countText)
        one.total = 3
        XCTAssertEqual(one.countText, "1 of 3")
    }

    func testASecondRequestTakesOverTheSameWindow() {
        let controller = ConnectionApprovalWindowController(activation: .inert)
        defer { controller.dismissActiveApproval() }
        var answers: [String] = []

        controller.showApprovalWindow(
            prompt(idA),
            waiting: 1,
            onApprove: { answers.append("approve A pair=\($0)") },
            onDeny: { answers.append("deny A") }
        )
        let window = controller.window
        XCTAssertEqual(window?.isVisible, true)
        XCTAssertEqual(window?.title, "Connection Request")
        XCTAssertEqual(controller.model.prompt?.countText, "1 of 2")

        controller.model.pairOnApprove = true
        controller.retireActiveRequest()
        XCTAssertEqual(controller.model.prompt?.phase, .answered)
        XCTAssertEqual(window?.isVisible, true)

        controller.showApprovalWindow(
            prompt(idB),
            waiting: 0,
            onApprove: { answers.append("approve B pair=\($0)") },
            onDeny: { answers.append("deny B") }
        )
        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.model.prompt?.request.connectionID, idB)
        XCTAssertEqual(controller.model.prompt?.countText, "2 of 2")
        XCTAssertFalse(controller.model.pairOnApprove)
        XCTAssertEqual(answers, [])

        window?.close()
        XCTAssertEqual(answers, ["deny B"])
        XCTAssertNil(controller.model.prompt)
        XCTAssertEqual(
            NSApp.windows.filter { $0.title == "Connection Request" && $0.isVisible }.count,
            0
        )
    }

    func testATimedOutPromptStaysToSaySoAndCannotBeAnswered() {
        let controller = ConnectionApprovalWindowController(activation: .inert)
        defer { controller.dismissActiveApproval() }
        var answers: [String] = []
        controller.showApprovalWindow(
            prompt(idA),
            waiting: 0,
            onApprove: { _ in answers.append("approve") },
            onDeny: { answers.append("deny") }
        )

        controller.showTimedOut()
        XCTAssertEqual(controller.model.prompt?.phase, .timedOut)
        XCTAssertTrue(controller.isOpen)

        controller.window?.close()
        XCTAssertEqual(answers, [])
    }

    func testAPairedPromptStaysToSaySoAndCannotBeAnswered() {
        let controller = ConnectionApprovalWindowController(activation: .inert)
        defer { controller.dismissActiveApproval() }
        var answers: [String] = []
        controller.showApprovalWindow(
            prompt(idA),
            waiting: 0,
            onApprove: { _ in answers.append("approve") },
            onDeny: { answers.append("deny") }
        )

        controller.showPaired()
        XCTAssertEqual(controller.model.prompt?.phase, .paired)
        XCTAssertEqual(controller.model.prompt?.notice(at: Date()), "Paired.")
        XCTAssertTrue(controller.isOpen)

        controller.window?.close()
        XCTAssertEqual(answers, [], "Closing a paired prompt must not decline its client")
        XCTAssertFalse(controller.isOpen)
    }

    func testANewRequestTakesOverAPairedPrompt() {
        let controller = ConnectionApprovalWindowController(activation: .inert)
        defer { controller.dismissActiveApproval() }
        controller.showApprovalWindow(prompt(idA), waiting: 0, onApprove: { _ in }, onDeny: {})
        controller.showPaired()

        controller.showApprovalWindow(prompt(idB), waiting: 0, onApprove: { _ in }, onDeny: {})
        XCTAssertEqual(controller.model.prompt?.request.connectionID, idB)
        XCTAssertEqual(controller.model.prompt?.phase, .asking)
    }

    func testAQueuedRequestRaisesTheCountOnTheOpenPrompt() {
        let controller = ConnectionApprovalWindowController(activation: .inert)
        defer { controller.dismissActiveApproval() }
        controller.showApprovalWindow(prompt(idA), waiting: 0, onApprove: { _ in }, onDeny: {})
        XCTAssertNil(controller.model.prompt?.countText)
        controller.updateWaiting(2)
        XCTAssertEqual(controller.model.prompt?.countText, "1 of 3")
    }
}

@MainActor
final class PromptWindowLayoutTests: XCTestCase {
    func testALabelKeepsItsSizeWhateverItSays() {
        let faces: [SteadyLabel.Face] = [
            .init(text: "Sign In"), .init(text: "Signing In…", working: true), .init(text: "Done"),
        ]
        let sizes = faces.map { NSHostingView(rootView: SteadyLabel(faces: faces, current: $0)).fittingSize }
        XCTAssertEqual(Set(sizes.map(\.width)).count, 1)
        XCTAssertEqual(Set(sizes.map(\.height)).count, 1)
        let alone = NSHostingView(rootView: SteadyLabel(faces: [faces[0]], current: faces[0])).fittingSize
        XCTAssertGreaterThan(sizes[0].width, alone.width)
    }

    func testAPairingCodeThatStopsWorkingLeavesWordInItsPlace() {
        let expiresAt = Date(timeIntervalSince1970: 1_000_300)
        let live = PairingCodeDisplay.live(code: "ABCDEFGH", expiresAt: expiresAt)
        XCTAssertEqual(live.expiring(at: expiresAt.addingTimeInterval(-1)), live)
        XCTAssertEqual(live.expiring(at: expiresAt), .ended(.expired))
        XCTAssertEqual(live.ending(.exhausted(code: "ABCDEFGH")), .ended(.discarded))
        XCTAssertEqual(PairingCodeDisplay.ended(.expired).ending(.exhausted(code: "ABCDEFGH")), .ended(.expired))
        XCTAssertEqual(PairingCodeDisplay.Ending.expired.text, "Expired")
        XCTAssertEqual(PairingCodeDisplay.Ending.discarded.text, "No longer valid")
    }

    /// The tick is there in full when it starts out drawn, leaves nothing
    /// when it is not, and a button that shows it keeps its size.
    func testTheTickShowsOnlyWhenDrawnAndItsButtonKeepsItsSize() throws {
        func ink(drawn: Bool) throws -> Int {
            let view = NSHostingView(
                rootView: SuccessTick(isDrawn: drawn, announcement: "Done", size: 28).foregroundStyle(.black)
            )
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var count = 0
            for x in 0 ..< bitmap.pixelsWide {
                for y in 0 ..< bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                    count += 1
                }
            }
            return count
        }
        XCTAssertEqual(try ink(drawn: false), 0)
        XCTAssertGreaterThan(try ink(drawn: true), 40)

        let sizes = [false, true].map {
            NSHostingView(rootView: DoneLabel(title: "Add Place", isDone: $0, announcement: "Place saved")).fittingSize
        }
        XCTAssertEqual(sizes[0], sizes[1])
    }

    func testAUsedCodeSaysWhoPairedOnceAndOnlyForANewClient() {
        let client = PairedClient(fingerprint: "ab", label: "Claude", addedAt: Date(timeIntervalSince1970: 1))
        let byCode = PairingOutcome(fingerprint: "ab", client: client, route: .pairingCode)
        let used = PairingCodeDisplay.ended(.redeemed)
        let paired = PairingCodeDisplay.ended(.paired(clientName: "Claude"))
        let live = PairingCodeDisplay.live(code: "ABCDEFGH", expiresAt: Date(timeIntervalSince1970: 1_000_300))

        XCTAssertEqual(used.pairing(byCode), paired)
        XCTAssertEqual(
            used.pairing(PairingOutcome(fingerprint: "ab", client: nil, route: .pairingCode)),
            used,
            "Nobody new paired"
        )
        XCTAssertEqual(live.pairing(byCode), live, "A code still on offer is not the one that was used")
        XCTAssertEqual(PairingCodeDisplay.none.pairing(byCode), PairingCodeDisplay.none)
        XCTAssertEqual(PairingCodeDisplay.ended(.expired).pairing(byCode), .ended(.expired))
        XCTAssertEqual(PairingCodeDisplay.Ending.paired(clientName: "Claude").text, "Paired with Claude")
        XCTAssertEqual(PairingCodeDisplay.Ending.redeemed.text, "No longer valid")

        XCTAssertEqual(paired.closing(), PairingCodeDisplay.none, "Reopening the window does not say it again")
        XCTAssertEqual(used.closing(), used)
        XCTAssertEqual(live.closing(), live)
    }

    /// The code on show ends the way the issuer says it did, and only that code.
    func testTheCodeOnShowEndsAsTheIssuerSays() {
        let live = PairingCodeDisplay.live(code: "ABCDEFGH", expiresAt: Date(timeIntervalSince1970: 1_000_300))

        XCTAssertEqual(live.ending(.redeemed(code: "ABCDEFGH")), .ended(.redeemed))
        XCTAssertEqual(live.ending(.exhausted(code: "ABCDEFGH")), .ended(.discarded))
        XCTAssertEqual(live.ending(.redeemed(code: "OTHERONE")), live, "Another code is not this one")
        XCTAssertEqual(PairingCodeDisplay.none.ending(.redeemed(code: "ABCDEFGH")), PairingCodeDisplay.none)
    }

    /// A code guessed away is not the one a client used: a client approved
    /// on the prompt with "Always allow" afterwards is no code's doing, and
    /// neither is any pairing the prompt makes after a code was used.
    func testOnlyAPairingMadeWithTheCodeSaysPaired() {
        let client = PairedClient(fingerprint: "bb", label: "B", addedAt: Date(timeIntervalSince1970: 1))
        let byPrompt = PairingOutcome(fingerprint: "bb", client: client, route: .approval)
        let guessedAway = PairingCodeDisplay.ended(.discarded)

        XCTAssertEqual(guessedAway.pairing(byPrompt), guessedAway)
        XCTAssertEqual(
            guessedAway.pairing(PairingOutcome(fingerprint: "bb", client: client, route: .pairingCode)),
            guessedAway
        )
        XCTAssertEqual(PairingCodeDisplay.ended(.redeemed).pairing(byPrompt), .ended(.redeemed))
    }

    /// A window whose content grows keeps its title bar where it is and takes
    /// the new height.
    func testAWindowFollowsItsContentToANewHeight() async throws {
        final class Content: ObservableObject {
            @Published var rows = 1
        }
        struct Rows: View {
            @ObservedObject var content: Content
            var body: some View {
                FittedHeight {
                    VStack(spacing: 0) {
                        ForEach(0 ..< content.rows, id: \.self) { _ in
                            Color.clear.frame(width: 200, height: 40)
                        }
                    }
                }
            }
        }
        let content = Content()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 200, height: 0),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Rows(content: content))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        defer { window.close() }
        try await waitUntil { window.contentLayoutRect.height == 40 }
        let top = window.frame.maxY

        content.rows = 4
        try await waitUntil { window.contentLayoutRect.height == 160 }
        XCTAssertEqual(window.frame.maxY, top)
    }
}
