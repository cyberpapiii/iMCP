import CryptoKit
import Foundation
import MCP
import XCTest

extension MessageFrameScanner {
    /// The messages a chunk unlocked, ignoring auth frames.
    fileprivate mutating func messages(in chunk: Data) -> [Data] {
        consume(chunk).compactMap { frame in
            if case .message(let data) = frame { return data }
            return nil
        }
    }
}

/// The scanner replaced per-chunk heartbeat prefix checks that corrupted the
/// stdout stream whenever a heartbeat arrived coalesced after a message in
/// the same TCP read, or split across reads.
final class MessageFrameScannerTests: XCTestCase {
    private let newline = Data([UInt8(ascii: "\n")])

    private func message(_ text: String) -> Data {
        Data(text.utf8)
    }

    private var heartbeat: Data {
        Data(NetworkTransport.Heartbeat().rawValue)
    }

    func testEmitsEachNewlineDelimitedMessage() {
        var scanner = MessageFrameScanner()
        let chunk = message("{\"id\":1}") + newline + message("{\"id\":2}") + newline
        XCTAssertEqual(scanner.messages(in: chunk), [message("{\"id\":1}"), message("{\"id\":2}")])
    }

    func testBuffersMessageSplitAcrossChunks() {
        var scanner = MessageFrameScanner()
        XCTAssertEqual(scanner.messages(in: message("{\"id\"")), [])
        XCTAssertEqual(scanner.messages(in: message(":1}") + newline), [message("{\"id\":1}")])
    }

    func testDropsHeartbeatAtBufferHead() {
        var scanner = MessageFrameScanner()
        XCTAssertEqual(scanner.messages(in: heartbeat), [])
        XCTAssertEqual(scanner.messages(in: message("{\"id\":1}") + newline), [message("{\"id\":1}")])
    }

    func testDropsHeartbeatCoalescedAfterMessage() {
        var scanner = MessageFrameScanner()
        let chunk = message("{\"id\":1}") + newline + heartbeat + message("{\"id\":2}") + newline
        XCTAssertEqual(scanner.messages(in: chunk), [message("{\"id\":1}"), message("{\"id\":2}")])
    }

    func testBuffersHeartbeatSplitAcrossChunks() {
        var scanner = MessageFrameScanner()
        let firstHalf = heartbeat.prefix(6)
        let secondHalf = heartbeat.dropFirst(6)

        XCTAssertEqual(scanner.messages(in: Data(firstHalf)), [])
        XCTAssertEqual(
            scanner.messages(in: Data(secondHalf) + message("{\"id\":1}") + newline),
            [message("{\"id\":1}")]
        )
    }

    func testPartialHeartbeatDoesNotDiscardPendingBytes() {
        var scanner = MessageFrameScanner()
        // Heartbeat prefix arrives; the scanner must wait for the rest, not
        // discard it, so the following message survives intact.
        XCTAssertEqual(scanner.messages(in: Data(heartbeat.prefix(4))), [])
        XCTAssertEqual(scanner.messages(in: Data(heartbeat.dropFirst(4))), [])
        XCTAssertEqual(scanner.messages(in: message("{\"id\":1}") + newline), [message("{\"id\":1}")])
    }

    func testConsecutiveHeartbeatsAllDropped() {
        var scanner = MessageFrameScanner()
        let chunk = heartbeat + heartbeat + message("{\"id\":1}") + newline
        XCTAssertEqual(scanner.messages(in: chunk), [message("{\"id\":1}")])
    }

    func testSkipsEmptyMessages() {
        var scanner = MessageFrameScanner()
        XCTAssertEqual(
            scanner.messages(in: newline + newline + message("{\"id\":1}") + newline),
            [message("{\"id\":1}")]
        )
    }

    /// Exercises the `scannedByteCount` bookkeeping that keeps the rescan from
    /// going quadratic. A wrong resume offset slices the message at the wrong byte.
    func testLargeMessageAcrossManyChunks() {
        var scanner = MessageFrameScanner()
        let payload = String(repeating: "x", count: 100_000)
        let full = message("{\"data\":\"\(payload)\"}")

        var emitted: [Data] = []
        for start in stride(from: 0, to: full.count, by: 4096) {
            let end = min(start + 4096, full.count)
            emitted += scanner.messages(in: full.subdata(in: start ..< end))
        }
        XCTAssertEqual(emitted, [])
        XCTAssertEqual(scanner.messages(in: newline), [full])
    }

    func testReturnsAuthChallengeAsAFrameNotAMessage() {
        var scanner = MessageFrameScanner()
        let challenge = AuthChallengeFrame(connectionID: UUID())
        XCTAssertEqual(scanner.consume(challenge.encode()), [.authChallenge(challenge)])
        XCTAssertEqual(
            scanner.messages(in: message("{\"id\":1}") + newline),
            [message("{\"id\":1}")]
        )
    }

    func testReturnsAuthResponseAheadOfTheMessageBehindIt() throws {
        var scanner = MessageFrameScanner()
        let challenge = AuthChallengeFrame(connectionID: UUID())
        let response = try AuthResponseFrame.sign(
            challenge: challenge,
            privateKey: P256.Signing.PrivateKey()
        )
        let frames = scanner.consume(response.encode() + message("{\"id\":1}") + newline)
        XCTAssertEqual(frames.count, 2)
        guard case .authResponse = frames.first else {
            return XCTFail("expected the auth response first")
        }
        XCTAssertEqual(frames.last, .message(message("{\"id\":1}")))
    }

    func testBuffersAuthChallengeSplitAcrossChunks() {
        var scanner = MessageFrameScanner()
        let challenge = AuthChallengeFrame(connectionID: UUID())
        let frame = challenge.encode()
        XCTAssertEqual(scanner.consume(Data(frame.prefix(6))), [])
        XCTAssertEqual(
            scanner.consume(Data(frame.dropFirst(6)) + message("{\"id\":1}") + newline),
            [.authChallenge(challenge), .message(message("{\"id\":1}"))]
        )
    }

    /// The app verifies a response before it yields any later message, so
    /// frames must come back in wire order.
    func testFramesKeepWireOrderAroundAnAuthResponse() throws {
        var scanner = MessageFrameScanner()
        let response = try AuthResponseFrame.sign(
            challenge: AuthChallengeFrame(connectionID: UUID()),
            privateKey: P256.Signing.PrivateKey()
        )
        let chunk =
            message("{\"id\":1}") + newline + response.encode() + message("{\"id\":2}") + newline
        let frames = scanner.consume(chunk)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.first, .message(message("{\"id\":1}")))
        guard case .authResponse = frames[1] else {
            return XCTFail("expected the auth response second")
        }
        XCTAssertEqual(frames.last, .message(message("{\"id\":2}")))
    }

    func testDisconnectsOnOutOfRangePairingCodeLengthWithoutEmittingLeftoverMCP() throws {
        var scanner = MessageFrameScanner()
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: UUID())
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)

        var frame = response.encode()
        frame.append(20)
        frame.append(Data(repeating: 0x41, count: 20))

        XCTAssertEqual(
            scanner.messages(in: frame + message("{\"id\":1}") + newline),
            []
        )
        XCTAssertTrue(scanner.isDisconnected)
        XCTAssertEqual(scanner.messages(in: message("{\"id\":2}") + newline), [])
    }

    func testDisconnectsOnZeroAndOneBytePairingCodeLengthWithoutEmittingLeftoverMCP() throws {
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: UUID())
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)

        for length in [0, 1] {
            var scanner = MessageFrameScanner()
            var frame = response.encode()
            frame.append(UInt8(length))
            frame.append(Data(repeating: 0x41, count: length))

            XCTAssertEqual(
                scanner.messages(in: frame + message("{\"id\":1}") + newline),
                [],
                "length \(length)"
            )
            XCTAssertTrue(scanner.isDisconnected, "length \(length)")
        }
    }

    func testDisconnectsOnInvalidUTF8PairingCodeWithoutEmittingLeftoverMCP() throws {
        var scanner = MessageFrameScanner()
        let privateKey = P256.Signing.PrivateKey()
        let challenge = AuthChallengeFrame(connectionID: UUID())
        let response = try AuthResponseFrame.sign(challenge: challenge, privateKey: privateKey)

        var frame = response.encode()
        frame.append(6)
        frame.append(Data(repeating: 0xFF, count: 6))

        XCTAssertEqual(
            scanner.messages(in: frame + message("{\"id\":1}") + newline),
            []
        )
        XCTAssertTrue(scanner.isDisconnected)
    }
}

/// Stdin used to be forwarded chunk by chunk, so nothing could be done about
/// a message the app would reject.
final class StdinFrameScannerTests: XCTestCase {
    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private let codexInitialize = """
        {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18",\
        "capabilities":{"experimental":{"codex/auth-change":{"version":1}},"roots":{}},\
        "clientInfo":{"name":"codex","version":"1"}}}
        """

    func testCodexAuthChangeCapabilityIsDroppedFromInitialize() throws {
        let normalized = try object(MCPInitializeCompatibility.normalize(Data(codexInitialize.utf8)))
        let params = try XCTUnwrap(normalized["params"] as? NSDictionary)
        let capabilities = try XCTUnwrap(params["capabilities"] as? NSDictionary)
        XCTAssertNil(capabilities["experimental"])
        XCTAssertNotNil(capabilities["roots"])
        XCTAssertEqual(normalized["id"] as? Int, 0)
        XCTAssertEqual((params["clientInfo"] as? NSDictionary)?["name"] as? String, "codex")
    }

    func testOtherExperimentalCapabilitiesSurvive() throws {
        let request = codexInitialize.replacingOccurrences(
            of: #""codex/auth-change":{"version":1}"#,
            with: #""codex/auth-change":{"version":1},"other":"yes""#
        )
        let normalized = try object(MCPInitializeCompatibility.normalize(Data(request.utf8)))
        let capabilities = (normalized["params"] as? NSDictionary)?["capabilities"] as? NSDictionary
        XCTAssertEqual(capabilities?["experimental"] as? NSDictionary, ["other": "yes"])
    }

    func testMessagesThatNeedNoChangeAreForwardedByteForByte() {
        for text in [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"capabilities":{"experimental":{"codex/auth-change":{}}}}}"#,
            "not json",
        ] {
            XCTAssertEqual(MCPInitializeCompatibility.normalize(Data(text.utf8)), Data(text.utf8))
        }
    }

    func testOnlyWholeMessagesAreForwarded() throws {
        var scanner = StdinFrameScanner()
        XCTAssertEqual(try scanner.consume(Data(#"{"id""#.utf8)), [])
        XCTAssertEqual(
            try scanner.consume(Data(":1}\n\r\n{\"id\":2}\n{\"id\"".utf8)),
            [Data("{\"id\":1}\n".utf8), Data("{\"id\":2}\n".utf8)]
        )
        XCTAssertEqual(try scanner.consume(Data(":3}\n".utf8)), [Data("{\"id\":3}\n".utf8)])
    }

    func testWhitespaceOnlyLinesAreDroppedAndAnyOtherLineIsForwarded() throws {
        var scanner = StdinFrameScanner()
        let blank = Data([0x09, 0x0B, 0x0C, 0x0D, 0x20, 0x0A, 0x0A])
        XCTAssertEqual(try scanner.consume(blank), [])
        XCTAssertEqual(try scanner.consume(Data(" x \n".utf8)), [Data(" x \n".utf8)])
    }

    func testInitializeSplitAcrossReadsIsStillNormalized() throws {
        var scanner = StdinFrameScanner()
        let bytes = Data((codexInitialize + "\n").utf8)
        XCTAssertEqual(try scanner.consume(bytes.prefix(40)), [])
        let frames = try scanner.consume(bytes.dropFirst(40))
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(String(decoding: frames[0], as: UTF8.self).contains("codex/auth-change"))
        XCTAssertEqual(frames[0].last, UInt8(ascii: "\n"))
    }

    /// The app closes a connection that sends more than 1 MiB in one message,
    /// so the CLI refuses it before sending and says why.
    func testAMessageOverTheAppsLimitIsRefusedWithAReason() throws {
        XCTAssertEqual(StdinFrameScanner.maximumFrameBytes, 1_048_576)

        var scanner = StdinFrameScanner()
        let largest = Data(repeating: UInt8(ascii: "a"), count: WireContract.maxClientMessageBytes)
        XCTAssertEqual(try scanner.consume(largest + Data("\n".utf8)), [largest + Data("\n".utf8)])

        var oversized = StdinFrameScanner()
        let tooLarge = Data(repeating: UInt8(ascii: "a"), count: WireContract.maxClientMessageBytes + 1)
        XCTAssertThrowsError(try oversized.consume(tooLarge + Data("\n".utf8))) { error in
            XCTAssertEqual(error as? StdioProxyError, .stdinFrameTooLarge)
        }
        XCTAssertEqual(
            CLIBootstrap.recovery(after: StdioProxyError.stdinFrameTooLarge, hasConsumedStdin: true),
            .terminate
        )
        XCTAssertTrue(CLIBootstrap.stdinFrameTooLargeNotice.contains("1 MiB"))
    }

    /// The app applies the same limit to what it receives.
    func testTheAppSideScannerDropsAMessageOverTheLimit() {
        var scanner = MessageFrameScanner(maxMessageBytes: 8)
        XCTAssertEqual(scanner.consume(Data("12345678\n".utf8)), [.message(Data("12345678".utf8))])
        XCTAssertEqual(scanner.consume(Data("123456789\n{}\n".utf8)), [])
        XCTAssertEqual(scanner.disconnectReason, .messageTooLarge)

        var unterminated = MessageFrameScanner(maxMessageBytes: 8)
        XCTAssertEqual(unterminated.consume(Data("123456789".utf8)), [])
        XCTAssertEqual(unterminated.disconnectReason, .messageTooLarge)
    }

    func testAMessageOverTheLimitStopsTheProxy() {
        var scanner = StdinFrameScanner()
        let oversized = Data(repeating: UInt8(ascii: "a"), count: StdinFrameScanner.maximumFrameBytes + 1)
        XCTAssertThrowsError(try scanner.consume(oversized)) { error in
            XCTAssertEqual(error as? StdioProxyError, .stdinFrameTooLarge)
        }
    }
}
