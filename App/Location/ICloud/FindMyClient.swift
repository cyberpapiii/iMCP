import Foundation
import OSLog

struct FindMyDevice: Sendable, Equatable, Codable {
    let id: String
    let name: String
    /// Apple's marketing name, e.g. "iPhone 15 Pro". Its `deviceModel` is the
    /// internal code, which no caller can do anything with.
    let model: String?
    let deviceClass: String?
    /// 0 to 1 as Apple reports it. Nil when the device has not checked in.
    let batteryLevel: Double?
    let batteryStatus: String?
    let isThisDevice: Bool
    /// The person this device belongs to. Nil means the signed-in user; a value
    /// is a Family Sharing member's identifier.
    let ownerID: String?
    let canPlaySound: Bool
    let location: FindMyFix?
}

struct FindMyFix: Sendable, Equatable, Codable {
    let latitude: Double
    let longitude: Double
    /// Metres. Apple reports the radius it is confident about, not a guess.
    let horizontalAccuracy: Double?
    let timestamp: Date
    /// Apple's own word for how the fix was obtained, e.g. "Wifi" or "GPS".
    let positionType: String?
    /// Apple's flag that the fix is stale. Reported rather than filtered: a
    /// day-old position is still the answer to "where did they leave it".
    let isOld: Bool
}

struct FindMyPerson: Sendable, Equatable, Codable {
    let id: String?
    let name: String
    let isMe: Bool
    let devices: [FindMyDevice]

    /// The device to believe. Apple returns a fix per device and they disagree:
    /// a phone in a pocket and a Mac left at home are both "where they are".
    /// The most recent fix wins, and accuracy breaks a tie, because a person is
    /// wherever they most recently were seen.
    var bestFix: (device: FindMyDevice, fix: FindMyFix)? {
        devices
            .compactMap { device in device.location.map { (device, $0) } }
            .max { left, right in
                if left.1.timestamp != right.1.timestamp {
                    return left.1.timestamp < right.1.timestamp
                }
                return (left.1.horizontalAccuracy ?? .greatestFiniteMagnitude)
                    > (right.1.horizontalAccuracy ?? .greatestFiniteMagnitude)
            }
    }
}

struct FindMySnapshot: Sendable, Equatable {
    let devices: [FindMyDevice]
    let people: [FindMyPerson]
}

enum FindMyError: Swift.Error, ClientFacingError, Equatable {
    case notSignedIn
    /// There is no live session for a reason the app knows. `status` is what
    /// the menu says and `problem` is `ICloudSession.problem`, so a client
    /// reads the same words as the owner, and can tell an expired session or
    /// a queued retry from a Mac that was never signed in.
    case sessionUnavailable(status: String, problem: String?)
    case noDevices
    case unknownDevice(String)
    case soundUnavailable(String)
    case soundPlayedRecently
    case appleRejectedRequest(status: Int)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to iCloud. Sign in from the iMCP menu."
        case .sessionUnavailable(let status, let problem):
            return "The iCloud session is not usable (\(status))." + (problem.map { " \($0)" } ?? "")
        case .noDevices:
            return
                "Find My returned no devices for this account. Check that Find My is on for at least one device."
        case .unknownDevice(let name):
            return
                "No device named \"\(name)\". Call location_devices for the names this account can see."
        case .soundUnavailable(let name):
            return "\"\(name)\" cannot play a sound. It is offline, or it is this Mac."
        case .soundPlayedRecently:
            return "That device was asked to play a sound less than 30 seconds ago. Wait before asking again."
        case .appleRejectedRequest(let status):
            return "Find My rejected the request (HTTP \(status))."
        }
    }
}

/// Who hears how a client's calls end. The session attaches itself when it
/// adopts a client, after construction, so the hooks are set then.
final class FindMyClientEvents: @unchecked Sendable {
    typealias Hook = @Sendable () async -> Void

    private let lock = NSLock()
    private var didSucceed: Hook?
    private var onRejected: Hook?

    func attach(didSucceed: Hook?, onRejected: Hook?) {
        lock.withLock {
            self.didSucceed = didSucceed
            self.onRejected = onRejected
        }
    }

    func succeeded() async {
        let hook = lock.withLock { didSucceed }
        await hook?()
    }

    func rejected() async {
        let hook = lock.withLock { onRejected }
        await hook?()
    }
}

/// Apple's Find My web service.
///
/// An actor because Find My is stateful: the first call initializes a session
/// and every later one has to hand back the server context it was given, or
/// Apple starts over and the devices arrive empty.
actor FindMyClient {
    private enum SessionRejection: Swift.Error {
        case browserSessionExpired
        case serviceAuthorizationExpired
    }

    private static let log = Logger.service("location.findmy")

    private let transport: ICloudHTTPTransport
    nonisolated let account: ICloudAccount
    private let clientID: String
    /// `succeeded` runs after every complete operation Apple accepted, so the
    /// session can write a rotated cookie jar down before the app quits.
    /// `rejected` runs when Apple rejected the session itself, so the session
    /// can renew it. Each is awaited before the call returns or throws, which
    /// keeps them in the order Apple answered.
    nonisolated let events = FindMyClientEvents()

    private var serverContext: Any?
    private var snapshotInProgress = false
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    /// When each device was last asked to play a sound. A sound is loud and
    /// in the real world; a client retrying in a loop must not repeat it.
    private var lastSoundAt: [String: Date] = [:]
    static let soundCooldown: TimeInterval = 30

    init(transport: ICloudHTTPTransport, account: ICloudAccount, clientID: String) {
        self.transport = transport
        self.account = account
        self.clientID = clientID
    }

    /// `locate` asks Apple to wake the devices for a fresh fix instead of
    /// answering from its cache. It costs seconds and battery, which is why it
    /// is a parameter and not the default.
    func snapshot(locate: Bool = false, selectedDeviceID: String? = nil) async throws -> FindMySnapshot {
        await beginSnapshot()
        defer { endSnapshot() }
        try Task.checkCancellation()

        do {
            let result = try await performSnapshot(locate: locate, selectedDeviceID: selectedDeviceID)
            await events.succeeded()
            return result
        } catch FindMyError.noDevices {
            // A decoded empty list still proves Apple accepted the session.
            await events.succeeded()
            throw FindMyError.noDevices
        } catch let rejection as SessionRejection {
            throw await rejected(rejection)
        }
    }

    /// Apple rejected the session itself: the server context it handed out
    /// is dead too, and the session hears so before the caller does.
    private func rejected(_ rejection: SessionRejection) async -> ICloudAuthError {
        serverContext = nil
        await events.rejected()
        return .trustExpired
    }

    private func performSnapshot(
        locate: Bool,
        selectedDeviceID: String?
    ) async throws -> FindMySnapshot {
        do {
            if serverContext == nil {
                let initialized = try await fetchSnapshotOnce(locate: false, selectedDeviceID: nil)
                guard locate else { return initialized }
            }
            return try await fetchSnapshotOnce(locate: locate, selectedDeviceID: selectedDeviceID)
        } catch SessionRejection.serviceAuthorizationExpired {
            // Apple's Find My client session can expire before the browser
            // session behind its cookies. Apple also retires web build identifiers
            // independently, so refresh those while reinitializing the cheaper
            // state before escalating to password authentication and its email.
            Self.log.notice("Find My request rejected; refreshing the iCloud web build and client session")
            serverContext = nil
            let initialized = try await fetchSnapshotOnce(
                locate: false,
                selectedDeviceID: nil,
                forceVersionRefresh: true
            )
            guard locate else {
                Self.log.notice("Find My recovered after starting a fresh client session")
                return initialized
            }
            let located = try await fetchSnapshotOnce(locate: true, selectedDeviceID: selectedDeviceID)
            Self.log.notice("Find My recovered after starting a fresh client session")
            return located
        }
    }

    /// Swift actors can re-enter while an awaited request is in flight. A
    /// snapshot is a transaction over Apple's server context, so later callers
    /// wait until the current transaction has either committed or failed.
    private func beginSnapshot() async {
        guard snapshotInProgress else {
            snapshotInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            snapshotWaiters.append(continuation)
        }
    }

    private func endSnapshot() {
        guard !snapshotWaiters.isEmpty else {
            snapshotInProgress = false
            return
        }
        snapshotWaiters.removeFirst().resume()
    }

    private func fetchSnapshotOnce(
        locate: Bool,
        selectedDeviceID: String?,
        forceVersionRefresh: Bool = false
    ) async throws -> FindMySnapshot {
        var clientContext: [String: Any] = [
            "appName": "iCloud Find (Web)",
            "appVersion": "2.0",
            "apiVersion": "3.0",
            "deviceListVersion": 1,
            "fmly": true,
            "timezone": TimeZone.current.identifier,
            "inactiveTime": 0,
        ]
        var body: [String: Any] = [:]
        // `refreshClient` is only meaningful with the context Apple handed back;
        // without it the call has to start the session over.
        let path = serverContext == nil ? "initClient" : "refreshClient"
        if let serverContext {
            body["serverContext"] = serverContext
            if locate {
                body["isUpdatingAllLocations"] = true
                clientContext["shouldLocate"] = true
                clientContext["selectedDevice"] = selectedDeviceID ?? "all"
            }
        }
        body["clientContext"] = clientContext

        let response = try await send(
            path: "fmipservice/client/web/\(path)",
            base: account.findMy,
            body: body,
            forceVersionRefresh: forceVersionRefresh
        )
        guard
            let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            throw ICloudAuthError.unreadableResponse
        }

        serverContext = root["serverContext"]

        let devices = (root["content"] as? [[String: Any]] ?? []).compactMap(Self.device(from:))
        guard !devices.isEmpty else { throw FindMyError.noDevices }
        return FindMySnapshot(
            devices: devices,
            people: Self.people(from: devices, userInfo: root["userInfo"] as? [String: Any])
        )
    }

    func playSound(deviceID: String) async throws {
        let now = Date()
        if let last = lastSoundAt[deviceID], now.timeIntervalSince(last) < Self.soundCooldown {
            throw FindMyError.soundPlayedRecently
        }
        // Claimed before the request: the actor is re-entrant across the
        // await, and two overlapping calls must not both get through.
        lastSoundAt[deviceID] = now
        do {
            do {
                try await requestSound(deviceID: deviceID, forceVersionRefresh: false)
            } catch SessionRejection.serviceAuthorizationExpired {
                // The same retired-build check a snapshot makes before
                // calling the session dead. A rejected request played nothing.
                try await requestSound(deviceID: deviceID, forceVersionRefresh: true)
            }
        } catch let rejection as SessionRejection {
            lastSoundAt[deviceID] = nil
            throw await rejected(rejection)
        } catch {
            lastSoundAt[deviceID] = nil
            throw error
        }
        await events.succeeded()
    }

    private func requestSound(deviceID: String, forceVersionRefresh: Bool) async throws {
        _ = try await send(
            path: "fmipservice/client/web/playSound",
            base: account.findMy,
            body: [
                "device": deviceID,
                "subject": "Find My iPhone Alert",
                "clientContext": ["fmly": true],
            ],
            forceVersionRefresh: forceVersionRefresh
        )
    }

    private func send(
        path: String,
        base: URL,
        body: [String: Any],
        forceVersionRefresh: Bool = false
    ) async throws -> ICloudHTTPResponse {
        let url = ICloudWebRequest.url(
            base,
            path: path,
            version: await transport.iCloudWebClientVersion(forceRefresh: forceVersionRefresh),
            clientID: clientID,
            extra: [URLQueryItem(name: "dsid", value: account.dsid)]
        )
        let response = try await transport.send(try ICloudWebRequest.post(url, body: body))
        Self.log.notice(
            "POST \(path, privacy: .public) -> \(response.statusCode, privacy: .public)"
        )
        guard response.isSuccess else {
            // A lapsed service authorization can be a retired web build, which
            // is cheaper to fix, so the caller refreshes that once first.
            switch AppleSessionStatus(statusCode: response.statusCode) {
            case .browserSessionGone: throw SessionRejection.browserSessionExpired
            case .serviceAuthorizationLapsed: throw SessionRejection.serviceAuthorizationExpired
            case nil: throw FindMyError.appleRejectedRequest(status: response.statusCode)
            }
        }
        return response
    }

    // MARK: - Decoding

    /// Apple's payload is loosely typed and inconsistent between device
    /// classes, so each field is read defensively rather than through a
    /// `Decodable` conformance that a missing key would fail outright.
    private static func device(from raw: [String: Any]) -> FindMyDevice? {
        guard let id = raw["id"] as? String else { return nil }
        let features = raw["features"] as? [String: Any] ?? [:]
        return FindMyDevice(
            id: id,
            name: (raw["name"] as? String) ?? "Unnamed device",
            model: raw["deviceDisplayName"] as? String,
            deviceClass: raw["deviceClass"] as? String,
            batteryLevel: (raw["batteryLevel"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            batteryStatus: raw["batteryStatus"] as? String,
            isThisDevice: (raw["thisDevice"] as? Bool) ?? false,
            ownerID: raw["prsId"] as? String,
            canPlaySound: (features["SND"] as? Bool) ?? false,
            location: fix(from: raw["location"] as? [String: Any])
        )
    }

    private static func fix(from raw: [String: Any]?) -> FindMyFix? {
        guard
            let raw,
            let latitude = raw["latitude"] as? Double,
            let longitude = raw["longitude"] as? Double,
            // Apple reports the fix time in milliseconds since the epoch.
            let milliseconds = raw["timeStamp"] as? Double
        else { return nil }
        return FindMyFix(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: raw["horizontalAccuracy"] as? Double,
            timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
            positionType: raw["positionType"] as? String,
            isOld: (raw["isOld"] as? Bool) ?? false
        )
    }

    /// Groups devices by owner. Family members arrive as devices tagged with a
    /// person id; everything untagged belongs to the signed-in user.
    private static func people(
        from devices: [FindMyDevice],
        userInfo: [String: Any]?
    ) -> [FindMyPerson] {
        let members = userInfo?["membersInfo"] as? [String: Any] ?? [:]
        let byOwner = Dictionary(grouping: devices, by: \.ownerID)

        var people: [FindMyPerson] = []
        let untagged: String? = nil
        if let mine = byOwner[untagged] {
            people.append(
                FindMyPerson(id: nil, name: name(from: userInfo) ?? "Me", isMe: true, devices: mine)
            )
        }
        for (id, owned) in byOwner {
            guard let id else { continue }
            people.append(
                FindMyPerson(
                    id: id,
                    name: name(from: members[id] as? [String: Any]) ?? "Family member",
                    isMe: false,
                    devices: owned
                )
            )
        }
        return people.sorted { left, right in
            if left.isMe != right.isMe { return left.isMe }
            return left.name < right.name
        }
    }

    private static func name(from info: [String: Any]?) -> String? {
        guard let info else { return nil }
        let parts = [info["firstName"] as? String, info["lastName"] as? String]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
