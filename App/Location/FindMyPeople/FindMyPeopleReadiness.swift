import CryptoKit
import Foundation
import OSLog

private let findMyPeopleHealthLog = Logger.service("location.people.health")

enum FindMyPeopleReadinessState: Equatable, Sendable {
    case disabled
    case missingKey
    case keyUnavailable
    case identityUnavailable
    case ready
}

enum FindMyPeopleToolError: Error, ClientFacingError, Equatable {
    case disabled
    case missingKey
    case keyUnavailable
    case identityUnavailable
    case friendNotFound(String)
    case ambiguousName(String, identifiers: [String])

    /// The gate state an error that means "People is not ready" stands for;
    /// nil for an error about one friend.
    var readinessState: FindMyPeopleReadinessState? {
        switch self {
        case .disabled: return .disabled
        case .missingKey: return .missingKey
        case .keyUnavailable: return .keyUnavailable
        case .identityUnavailable: return .identityUnavailable
        case .friendNotFound, .ambiguousName: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Find My People is off. Enable it in iMCP Settings."
        case .missingKey:
            return "Find My People setup is incomplete. Import the LocalStorage key in iMCP Settings."
        case .keyUnavailable:
            return "The Find My People key could not be read from the Keychain."
        case .identityUnavailable:
            return "The Find My People identity secret could not be read from the Keychain."
        case .friendNotFound(let query):
            return "No Find My friend matches \"\(query)\". Call location_friends for current names and identifiers."
        case .ambiguousName(let name, let identifiers):
            return
                "More than one Find My person is named \"\(name)\". Use one of these identifiers: \(identifiers.joined(separator: ", "))."
        }
    }
}

enum FindMyPeopleLifecycleError: Error, ClientFacingError, Equatable {
    case historyPurgeFailed
    /// Which secrets are gone afterwards. Clearing the key alone leaves the
    /// identity secret in place, so it reports `identitySecretCleared: false`.
    case secretPurgeFailed(databaseKeyCleared: Bool, identitySecretCleared: Bool)
    case setupPurgeFailed

    var errorDescription: String? {
        switch self {
        case .historyPurgeFailed:
            return "Recorded Find My People locations could not be deleted. People access remains off."
        case .secretPurgeFailed:
            return "Some Find My People secrets could not be deleted. People access remains off."
        case .setupPurgeFailed:
            return "The pending Find My People setup could not be deleted. People access remains off."
        }
    }
}

struct FindMyFriendReport: Codable, Equatable, Sendable {
    let identifier: String
    let name: String
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double?
    let fixTime: String?
    let fixAgeMinutes: Int?
    let isStale: Bool?
    let verticalAccuracyMeters: Double?
    let altitudeMeters: Double?
    let speedMetersPerSecond: Double?
    let courseDegrees: Double?
    let motionActivityState: Int?
    let locationLabel: String?
    let source: String
}

struct FindMyFriendHistoryFix: Equatable, Sendable {
    let identifier: String
    let name: String
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double?
    let timestamp: Date
}

struct FindMyPeopleHealth: Equatable, Sendable {
    let lastSuccess: Date?
    let rowCount: Int?
    let lastErrorCategory: String?
}

/// One authority for the default-off People gate, secret readiness, and local
/// People reads. Settings, service activation, tools, and the sampler consume
/// this actor rather than probing the Keychain independently.
actor FindMyPeopleReadiness {
    static let peopleEnabledDefaultsKey = "findMyPeopleEnabled"

    typealias PeopleLoader = @Sendable (Data) async throws -> [LocalStoragePerson]

    private let storage: LocalStorageKeyStorage
    private let loadPeople: PeopleLoader
    private let persistPeopleEnabled: @Sendable (Bool) -> Void
    private let quiescePeopleSampling: @Sendable () async -> Void
    private let resumePeopleSampling: @Sendable () async -> Void
    private var peopleEnabled: Bool
    private var generation = 0
    private var lastSuccess: Date?
    private var lastRowCount: Int?
    private var lastErrorCategory: String?

    /// The app's gate: production Keychain items, the persisted switch, and
    /// the sampler whose People work it stops and resumes.
    static func production(
        quiescePeopleSampling: @escaping @Sendable () async -> Void,
        resumePeopleSampling: @escaping @Sendable () async -> Void
    ) -> FindMyPeopleReadiness {
        let provider = LocalStoragePeopleProvider()
        return FindMyPeopleReadiness(
            storage: .production,
            peopleEnabled: UserDefaults.standard.bool(forKey: peopleEnabledDefaultsKey),
            persistPeopleEnabled: { UserDefaults.standard.set($0, forKey: peopleEnabledDefaultsKey) },
            quiescePeopleSampling: quiescePeopleSampling,
            resumePeopleSampling: resumePeopleSampling,
            loadPeople: { key in try await provider.people(key: key) }
        )
    }

    init(
        storage: LocalStorageKeyStorage,
        peopleEnabled: Bool,
        persistPeopleEnabled: @escaping @Sendable (Bool) -> Void = { _ in },
        quiescePeopleSampling: @escaping @Sendable () async -> Void = {},
        resumePeopleSampling: @escaping @Sendable () async -> Void = {},
        loadPeople: @escaping PeopleLoader
    ) {
        self.storage = storage
        self.peopleEnabled = peopleEnabled
        self.persistPeopleEnabled = persistPeopleEnabled
        self.quiescePeopleSampling = quiescePeopleSampling
        self.resumePeopleSampling = resumePeopleSampling
        self.loadPeople = loadPeople
    }

    func setPeopleEnabled(_ enabled: Bool) async {
        guard peopleEnabled != enabled else { return }
        peopleEnabled = enabled
        generation += 1
        persistPeopleEnabled(enabled)
        if enabled {
            await resumePeopleSampling()
        } else {
            await quiescePeopleSampling()
        }
    }

    func isPeopleEnabled() -> Bool {
        peopleEnabled
    }

    /// What the secrets say whether or not the gate is on: `.ready` once both
    /// are imported. Setup shows this while `state()` says `.disabled`.
    func secretsState() async -> FindMyPeopleReadinessState {
        switch await validatedSecrets() {
        case .success: return .ready
        case .failure(let error): return error.readinessState ?? .identityUnavailable
        }
    }

    /// The database key and the identity secret, both present and the right
    /// length, or the error that says which is not.
    private func validatedSecrets() async -> Result<(key: Data, identity: Data), FindMyPeopleToolError> {
        let key: Data
        switch await storage.databaseKey() {
        case .missing:
            return .failure(.missingKey)
        case .unavailable:
            return .failure(.keyUnavailable)
        case .found(let data):
            guard data.count == LocalStorageKeyStorage.secretLength else { return .failure(.keyUnavailable) }
            key = data
        }
        switch await storage.identitySecret() {
        case .missing:
            // An import creates it, so this is setup left unfinished.
            return .failure(.missingKey)
        case .unavailable:
            return .failure(.identityUnavailable)
        case .found(let identity):
            guard identity.count == LocalStorageKeyStorage.secretLength else { return .failure(.identityUnavailable) }
            return .success((key, identity))
        }
    }

    func health() -> FindMyPeopleHealth {
        FindMyPeopleHealth(
            lastSuccess: lastSuccess,
            rowCount: lastRowCount,
            lastErrorCategory: lastErrorCategory
        )
    }

    func state() async -> FindMyPeopleReadinessState {
        guard peopleEnabled else { return .disabled }
        return await secretsState()
    }

    func isReady() async -> Bool {
        await state() == .ready
    }

    /// Bootstrap calls this after restored-security verification. Validation is
    /// a real memory-only provider read and completes before the old key is
    /// replaced. No key value crosses an MCP tool boundary.
    func importDatabaseKey(_ candidate: Data) async throws {
        guard candidate.count == LocalStorageKeyStorage.secretLength else {
            throw LocalStorageKeyStorageError.invalidDatabaseKey
        }
        _ = try await loadAndRecord(candidate)
        _ = try await storage.loadOrCreateIdentitySecret()
        try await storage.replaceDatabaseKey(candidate) { _ in }
    }

    /// Turns People off and deletes the imported key. Using People again
    /// needs a new capture; the identity secret stays, so friend identifiers
    /// stay stable if one is imported.
    func clearDatabaseKey() async throws {
        await revokeAndQuiesce()
        guard await storage.clearDatabaseKey() else {
            throw FindMyPeopleLifecycleError.secretPurgeFailed(databaseKeyCleared: false, identitySecretCleared: false)
        }
    }

    /// Called only after `revokeAndQuiesce()`, so nothing is reading with them.
    func clearSecrets() async -> (databaseKeyCleared: Bool, identitySecretCleared: Bool) {
        (await storage.clearDatabaseKey(), await storage.clearIdentitySecret())
    }

    /// Throws unless People history may be shown now. A real memory-only
    /// provider read, not a cheaper check: historical People rows and
    /// People-derived places are provider output too, so the current key,
    /// schema, source, and gate must all hold first.
    func assertHistoryAccess() async throws {
        _ = try await loadedPeople()
    }

    func friends() async throws -> [FindMyFriendReport] {
        let loaded = try await loadedPeople()
        let now = Date()
        return loaded.people
            .map { Self.report(person: $0, identitySecret: loaded.identity, now: now) }
            .sorted {
                let order = $0.name.caseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
            }
    }

    func historyFixes() async throws -> [FindMyFriendHistoryFix] {
        let loaded = try await loadedPeople()
        return loaded.people.compactMap { person in
            guard let timestamp = person.fix.timestamp else { return nil }
            return FindMyFriendHistoryFix(
                identifier: Self.opaqueIdentifier(
                    serverIdentifier: person.serverIdentifier,
                    identitySecret: loaded.identity
                ),
                name: person.displayName,
                latitude: person.fix.latitude,
                longitude: person.fix.longitude,
                horizontalAccuracyMeters: person.fix.horizontalAccuracy,
                timestamp: timestamp
            )
        }
    }

    private func loadedPeople() async throws -> (people: [LocalStoragePerson], identity: Data) {
        guard peopleEnabled else { throw FindMyPeopleToolError.disabled }
        let requestedGeneration = generation
        let (key, identity) = try await validatedSecrets().get()
        let people = try await loadAndRecord(key)
        guard peopleEnabled, generation == requestedGeneration else {
            throw FindMyPeopleToolError.disabled
        }
        return (people, identity)
    }

    /// Turns People off and waits until no People read in flight can still
    /// reach the history. Every deletion of People data comes after this.
    func revokeAndQuiesce() async {
        if peopleEnabled {
            peopleEnabled = false
            generation += 1
            persistPeopleEnabled(false)
        }
        await quiescePeopleSampling()
    }

    private func loadAndRecord(_ key: Data) async throws -> [LocalStoragePerson] {
        do {
            let people = try await loadPeople(key)
            lastSuccess = Date()
            lastRowCount = people.count
            lastErrorCategory = nil
            findMyPeopleHealthLog.notice("Local People read succeeded with \(people.count) rows")
            return people
        } catch {
            let category = Self.errorCategory(error)
            lastErrorCategory = category
            findMyPeopleHealthLog.error("Local People read failed in category: \(category)")
            throw error
        }
    }

    private static func errorCategory(_ error: Error) -> String {
        switch error {
        case LocalStoragePeopleError.databaseNotFound: return "database-not-found"
        case LocalStoragePeopleError.databaseInaccessible: return "database-inaccessible"
        case LocalStoragePeopleError.invalidKeyLength: return "invalid-key-length"
        case LocalStoragePeopleError.incorrectKey: return "incorrect-key"
        case LocalStoragePeopleError.inconsistentSnapshot: return "inconsistent-snapshot"
        case LocalStoragePeopleError.oversizedDatabase: return "oversized-database"
        case LocalStoragePeopleError.unsupportedSchema: return "unsupported-schema"
        case LocalStoragePeopleError.malformedDatabase: return "malformed-database"
        case LocalStoragePeopleError.memoryOnlySQLiteUnavailable: return "memory-sqlite-unavailable"
        default: return "unavailable"
        }
    }

    func friend(matching query: String) async throws -> FindMyFriendReport {
        let reports = try await friends()
        if let exactIdentifier = reports.first(where: { $0.identifier == query }) {
            return exactIdentifier
        }
        let named = reports.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard !named.isEmpty else { throw FindMyPeopleToolError.friendNotFound(query) }
        guard named.count == 1 else {
            throw FindMyPeopleToolError.ambiguousName(
                query,
                identifiers: named.map(\.identifier).sorted()
            )
        }
        return named[0]
    }

    private static func report(
        person: LocalStoragePerson,
        identitySecret: Data,
        now: Date
    ) -> FindMyFriendReport {
        let timestamp = person.fix.timestamp
        // A friend's clock can run ahead of this Mac's; a fix from the future
        // is fresh, not negative minutes old.
        let age = timestamp.map { max(0, now.timeIntervalSince($0)) }
        return FindMyFriendReport(
            identifier: opaqueIdentifier(
                serverIdentifier: person.serverIdentifier,
                identitySecret: identitySecret
            ),
            name: person.displayName,
            latitude: person.fix.latitude,
            longitude: person.fix.longitude,
            horizontalAccuracyMeters: person.fix.horizontalAccuracy,
            fixTime: timestamp?.localISO8601,
            fixAgeMinutes: age.map { Int($0 / 60) },
            isStale: timestamp.map { LocationPolicy.isStale(isOld: false, at: $0, now: now) },
            verticalAccuracyMeters: person.fix.verticalAccuracy,
            altitudeMeters: person.fix.altitude,
            speedMetersPerSecond: person.fix.speed,
            courseDegrees: person.fix.course,
            motionActivityState: person.fix.motionActivityState,
            locationLabel: person.fix.locationLabel,
            source: person.source
        )
    }

    static func opaqueIdentifier(serverIdentifier: String, identitySecret: Data) -> String {
        let key = SymmetricKey(data: identitySecret)
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(serverIdentifier.utf8),
            using: key
        )
        return LocationSubjectKey.friend(digest: Data(digest))
    }
}
