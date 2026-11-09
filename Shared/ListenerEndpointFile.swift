import Foundation

/// On-disk handoff of the app's listener port to the bundled CLI.
///
/// The CLI normally discovers the app by resolving its Bonjour service
/// endpoint, but macOS gates that resolution behind the Local Network
/// privacy permission: when the permission is denied for the client
/// process (background daemons never get the prompt, and grants can be
/// dropped across reboots), `NWConnection` to a `.service` endpoint hangs
/// in `.preparing` forever. Loopback TCP is exempt from that gate, so the
/// app writes its port here once the listener is ready. The CLI tries a
/// direct `127.0.0.1` connection first and falls back to Bonjour.
enum ListenerEndpointFile {
    struct Contents: Codable, Equatable {
        let port: UInt16
        let pid: Int32
        /// Display names of services currently on. Absent on files from older apps.
        let enabledServices: [String]?

        init(port: UInt16, pid: Int32, enabledServices: [String]? = nil) {
            self.port = port
            self.pid = pid
            self.enabledServices = enabledServices
        }
    }

    enum Inspection: Equatable {
        case usable(Contents)
        case missing
        case notRegularFile
        case untrustedOwner
        case loosePermissions
        case malformed
        case invalidPort
        case processDead(pid: Int32)
        case processUntrusted(pid: Int32)
    }

    static let fileName = "listener-endpoint.json"

    static func fileURL(in directory: URL = WireContract.appSupportDirectory()) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func write(
        port: UInt16,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        enabledServices: [String]? = nil,
        in directory: URL = WireContract.appSupportDirectory()
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` leaves the mode of an existing directory alone, so
        // tighten it explicitly. An earlier version of this file may have left
        // it world-readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(
            Contents(port: port, pid: pid, enabledServices: enabledServices)
        )
        let url = fileURL(in: directory)
        try data.write(to: url, options: .atomic)
        // `.atomic` writes a temporary file and renames it into place, so the
        // mode has to be set on the final path after the write completes.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(in directory: URL = WireContract.appSupportDirectory()) {
        try? FileManager.default.removeItem(at: fileURL(in: directory))
    }

    /// Returns the handoff contents only if they decode, name a plausible
    /// port, and the writing process is still alive. A crashed app must not
    /// leave the CLI connecting to a port some other process now owns.
    ///
    /// This also verifies the file is a regular file owned by the current
    /// user and not group- or world-writable, which establishes that it was
    /// written by this user's app and not swapped for a symlink or edited by
    /// another local account.
    ///
    /// It does **not** authenticate the process actually listening on the
    /// named port. The CLI signs an auth challenge from whatever peer answers
    /// there, so a same-user process that wins the race to bind the port
    /// ahead of the real app can still intercept the connection.
    static func inspect(
        in directory: URL = WireContract.appSupportDirectory(),
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive,
        isTrustedProcess: (Int32) -> Bool,
        currentUserID: uid_t = getuid()
    ) -> Inspection {
        let url = fileURL(in: directory)
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .missing
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .malformed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .notRegularFile
        }
        guard let ownerAccountID = attributes[.ownerAccountID] as? NSNumber,
            ownerAccountID.uint32Value == currentUserID
        else {
            return .untrustedOwner
        }
        guard let posixPermissions = attributes[.posixPermissions] as? NSNumber,
            (posixPermissions.uint16Value & 0o022) == 0
        else {
            return .loosePermissions
        }

        guard let data = try? Data(contentsOf: url),
            let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else {
            return .malformed
        }
        guard contents.port > 0 else {
            return .invalidPort
        }
        guard isProcessAlive(contents.pid) else {
            return .processDead(pid: contents.pid)
        }
        guard isTrustedProcess(contents.pid) else {
            return .processUntrusted(pid: contents.pid)
        }
        return .usable(contents)
    }

    static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
