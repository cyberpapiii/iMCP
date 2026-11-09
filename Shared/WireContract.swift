import Foundation
import Network

/// What the app and the bundled CLI must agree on to find and talk to each
/// other. Both targets compile this one file, so a change here reaches both.
enum WireContract {
    static let serviceType = "_mcp._tcp"
    static let serviceDomain = "local."
    /// The Bonjour instance name the app registers its listener under. The
    /// Bonjour default, the device hostname, would never be recognized.
    static let bonjourInstanceName = "iMCP"
    static let appBundleIdentifier = "co.dododo.iMCP"

    /// The largest client-to-app JSON-RPC message, newline excluded. The app
    /// closes a connection that sends more; the CLI refuses such a message
    /// before sending it, so the session ends with a reason instead of the app
    /// dropping it mid-use.
    static let maxClientMessageBytes = 1_048_576

    static var maxClientMessageDescription: String {
        "\(maxClientMessageBytes / 1_048_576) MiB"
    }

    /// `~/Library/Application Support/iMCP`, where the endpoint file, the
    /// Debug CLI key, and the app's on-disk state live.
    static func appSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iMCP", isDirectory: true)
    }

    /// Loopback-only IPv4 TCP: the app listens with these and the CLI dials
    /// `127.0.0.1` with them. `acceptLocalOnly` is the local link (LAN), not
    /// this Mac, so it is not enough. Peer-to-peer is off so AWDL cannot widen
    /// it.
    static func loopbackParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return parameters
    }
}

/// The waits between a CLI starting a connection and the app deciding its
/// client's initialize, in the order they run. Two are the CLI's and two the
/// app's, and they work only in this order, so they live together.
///
/// 1. `signingKeyRead` (CLI): reading the client key, done before the socket
///    opens. An unanswered Keychain prompt holds the read; the app has
///    accepted nothing yet, so none of its deadlines is running.
/// 2. `authResponseWait` (CLI): once connected, how long the client's first
///    frame waits for the app's challenge to be answered. The key is already
///    in hand, so the answer goes out as the challenge arrives; the ceiling
///    matters only for an app that sends no challenge.
/// 3. `pairedLookup` (app): looking the answered key up in the paired list.
/// 4. `setup` (app): from accept until the initialize is decided.
///
/// 2 and 3 run inside 4 and together stay under it: a paired list that does
/// not answer in time leaves room to ask about the client rather than close
/// it as stalled.
enum HandshakeDeadline {
    static let signingKeyRead: Duration = .seconds(10)
    static let authResponseWait: Duration = .milliseconds(500)
    static let pairedLookup: Duration = .seconds(5)
    /// A valid signature costs a peer nothing, so whatever key it showed, a
    /// session still setting up by then is closed. A CLI whose client has not
    /// spoken yet sees a close before initialize and reconnects.
    static let setup: Duration = .seconds(10)
}

/// One-time pairing codes: issued by the app, typed into a client, and carried
/// in the CLI's AUTH-RESPONSE.
enum PairingCode {
    /// No I, O, 0, or 1, so a code read aloud or retyped cannot be misread.
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    static let lengths = AuthPreamble.minPairingCodeLength ... AuthPreamble.maxPairingCodeLength
    /// How `imcp-server` is handed a code. The Connect window shows both.
    static let flag = "--pair"
    static let environmentVariable = "IMCP_PAIR_CODE"

    /// The rule for an error that rejects a code, built from `lengths` and
    /// `alphabet`: "6-8 chars from A-Z/0-9 (no I/O/0/1)".
    static var formatDescription: String {
        let excluded = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".filter { !alphabet.contains($0) }
        let rule = "\(lengths.lowerBound)-\(lengths.upperBound) chars from A-Z/0-9"
        guard !excluded.isEmpty else { return rule }
        return rule + " (no \(excluded.map(String.init).joined(separator: "/")))"
    }

    static func normalize(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func hasValidLength(_ normalized: String) -> Bool {
        lengths.contains(normalized.count)
    }

    /// Length and alphabet, for a code already passed through `normalize`.
    static func isValid(_ normalized: String) -> Bool {
        let allowed = CharacterSet(charactersIn: alphabet)
        return hasValidLength(normalized) && normalized.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
