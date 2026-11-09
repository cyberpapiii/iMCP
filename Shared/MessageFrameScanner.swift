import Foundation
import MCP

/// Incremental scanner for the wire format shared by the iMCP app and its
/// CLI. JSON-RPC messages are delimited by newlines. SDK `NetworkTransport`
/// heartbeat frames (magic bytes plus a binary timestamp, no delimiter) are
/// interleaved between messages, and auth preamble frames may precede any MCP
/// traffic.
///
/// Buffering across reads is the whole point. A heartbeat or a message can
/// arrive split across TCP chunks, or coalesced into the same chunk as its
/// neighbors. Scanning only the buffer head is safe because peers send
/// heartbeats between messages, never inside one.
struct MessageFrameScanner {
    enum Frame: Equatable {
        case message(Data)
        case authChallenge(AuthChallengeFrame)
        case authResponse(AuthResponseFrame)
    }

    /// Why the scanner stopped reading for good.
    enum Disconnect: Equatable {
        /// An AUTH-RESPONSE broke the format.
        case invalidAuthFrame
        case messageTooLarge
    }

    static func frame(_ message: Data) -> Data {
        var framed = message
        framed.append(UInt8(ascii: "\n"))
        return framed
    }

    /// Largest message accepted, newline excluded. `nil` accepts any size.
    let maxMessageBytes: Int?

    private var buffer = Data()
    private var scannedByteCount = 0
    private(set) var disconnectReason: Disconnect?

    var isDisconnected: Bool { disconnectReason != nil }

    init(maxMessageBytes: Int? = nil) {
        self.maxMessageBytes = maxMessageBytes
    }

    mutating func disconnect(_ reason: Disconnect = .invalidAuthFrame) {
        guard !isDisconnected else { return }
        disconnectReason = reason
        buffer = Data()
        scannedByteCount = 0
    }

    /// Appends a received chunk and returns every complete frame it
    /// unlocked, in order. Messages come without their trailing newline;
    /// empty messages and heartbeats are dropped.
    mutating func consume(_ chunk: Data) -> [Frame] {
        guard !isDisconnected else { return [] }
        buffer.append(chunk)

        var frames: [Frame] = []
        while true {
            switch headAuthFrame() {
            case .frame(let frame, let length):
                frames.append(frame)
                drop(length)
                continue
            case .wait:
                return frames
            case .reject:
                disconnect(.invalidAuthFrame)
                return frames
            case .none:
                break
            }

            while let heartbeat = NetworkTransport.Heartbeat.from(data: buffer) {
                drop(heartbeat.rawValue.count)
            }

            // Only part of a heartbeat frame has arrived; wait for the rest
            // instead of scanning its binary timestamp, which may contain
            // newline bytes.
            if NetworkTransport.Heartbeat.isHeartbeat(buffer) { break }

            // Scan only bytes appended since the last pass; rescanning the
            // whole buffer is quadratic when one large message arrives
            // across many chunks.
            let searchStart = buffer.index(buffer.startIndex, offsetBy: scannedByteCount)
            guard let newlineIndex = buffer[searchStart...].firstIndex(of: UInt8(ascii: "\n"))
            else {
                scannedByteCount = buffer.count
                if let maxMessageBytes, buffer.count > maxMessageBytes {
                    disconnect(.messageTooLarge)
                }
                break
            }

            let messageData = buffer[buffer.startIndex ..< newlineIndex]
            if let maxMessageBytes, messageData.count > maxMessageBytes {
                disconnect(.messageTooLarge)
                return frames
            }
            if !messageData.isEmpty {
                frames.append(.message(Data(messageData)))
            }
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])
            scannedByteCount = 0
        }

        return frames
    }

    private enum HeadAuthFrame {
        case frame(Frame, length: Int)
        /// The start of an auth frame: read nothing else until it is whole.
        case wait
        case reject
        /// Not an auth frame: a heartbeat or MCP bytes.
        case none
    }

    /// What auth frame, if any, the buffer starts with. Each kind is tried
    /// once; the two magics share their first three bytes, so either
    /// may claim a short head as `.partial`.
    private func headAuthFrame() -> HeadAuthFrame {
        switch AuthChallengeFrame.parse(buffer) {
        case .complete(let challenge, let length): return .frame(.authChallenge(challenge), length: length)
        case .partial: return .wait
        case .rejected, .notThisFrame: break
        }
        switch AuthResponseFrame.parse(buffer) {
        case .complete(let response, let length): return .frame(.authResponse(response), length: length)
        case .partial: return .wait
        case .rejected: return .reject
        case .notThisFrame: return .none
        }
    }

    private mutating func drop(_ count: Int) {
        buffer = Data(buffer.dropFirst(count))
        scannedByteCount = 0
    }
}
