import Foundation

/// Codex advertises an experimental `codex/auth-change` capability whose value
/// is an object. The SDK decodes experimental capabilities as strings, so the
/// app rejects the whole `initialize` request. iMCP never reads the
/// capability; dropping it lets the handshake through.
enum MCPInitializeCompatibility {
    static func normalize(_ data: Data) -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            request["method"] as? String == "initialize",
            var params = request["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            var experimental = capabilities["experimental"] as? [String: Any],
            experimental["codex/auth-change"] is [String: Any]
        else { return data }

        experimental.removeValue(forKey: "codex/auth-change")
        if experimental.isEmpty {
            capabilities.removeValue(forKey: "experimental")
        } else {
            capabilities["experimental"] = experimental
        }
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? data
    }
}

/// Splits stdin into whole JSON-RPC messages. A read may end mid-message or
/// carry several; only a whole message can be inspected and rewritten.
struct StdinFrameScanner {
    /// The app's own limit, so a message it would refuse fails here, before it
    /// is sent. Without a bound, a client that never sends a newline grows the
    /// buffer until the process is killed.
    static let maximumFrameBytes = WireContract.maxClientMessageBytes

    private var pending = Data()

    /// Returns every message the chunk completed, each ending in a newline.
    /// Blank lines are dropped.
    mutating func consume(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var frames: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let frame = Data(pending[pending.startIndex ..< newline])
            guard frame.count <= Self.maximumFrameBytes else {
                throw StdioProxyError.stdinFrameTooLarge
            }
            pending = Data(pending[pending.index(after: newline)...])
            guard !Self.isIgnorable(frame) else { continue }
            let normalized = MCPInitializeCompatibility.normalize(frame)
            guard normalized.count <= Self.maximumFrameBytes else {
                throw StdioProxyError.stdinFrameTooLarge
            }
            frames.append(MessageFrameScanner.frame(normalized))
        }
        guard pending.count <= Self.maximumFrameBytes else {
            throw StdioProxyError.stdinFrameTooLarge
        }
        return frames
    }

    static func isIgnorable(_ data: Data) -> Bool {
        data.allSatisfy { byte in
            switch byte {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20:
                return true
            default:
                return false
            }
        }
    }
}
