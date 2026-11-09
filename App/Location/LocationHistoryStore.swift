import CoreLocation
import Foundation
import OSLog
import SQLite3

private let log = Logger.service("location.history")

extension LocationSubjectKey {
    static func person(of sample: LocationSample) -> String {
        person(provider: sample.provider, subjectID: sample.subjectID, personName: sample.personName)
    }
}

struct LocationSample: Sendable, Equatable {
    let provider: String
    let subjectID: String
    let subjectKind: String
    let sourceDeviceID: String?
    let deviceID: String
    let deviceName: String
    let personName: String
    let isMe: Bool
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let positionType: String?
    let timestamp: Date

    init(
        provider: String = LocationSampleProvider.web,
        subjectID: String? = nil,
        subjectKind: String = LocationSubjectKind.device,
        sourceDeviceID: String? = nil,
        deviceID: String,
        deviceName: String,
        personName: String,
        isMe: Bool,
        latitude: Double,
        longitude: Double,
        accuracyMeters: Double?,
        positionType: String?,
        timestamp: Date
    ) {
        self.provider = provider
        self.subjectID = subjectID ?? deviceID
        self.subjectKind = subjectKind
        self.sourceDeviceID = sourceDeviceID ?? (provider == LocationSampleProvider.web ? deviceID : nil)
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.personName = personName
        self.isMe = isMe
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.positionType = positionType
        self.timestamp = timestamp
    }
}

/// How a place got its name. Stored in `places.source`, because a place the
/// user typed deserves more trust than one derived.
enum NamedPlaceSource {
    static let manual = "manual"
    /// Where someone on the web provider was when it was named.
    static let person = "person"
    /// Where a Find My People friend was. Hidden while People is off.
    static let findMyPeople = LocationSampleProvider.people
}

/// A place the user has named, so history reads "Home" instead of a pair of
/// coordinates.
enum NamedPlaceKind {
    static let notable = "notable"
    static let label = "label"
}

struct NamedPlace: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    /// One of `NamedPlaceSource`.
    let source: String
    let createdAt: Date
    /// `notable` is one of the user's own places: drawn on the map and
    /// significant to an agent. `label` only names a spot that was
    /// identified once, so a stay there gets a name without the place
    /// becoming part of the user's world.
    let kind: String

    init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        source: String,
        createdAt: Date,
        kind: String = NamedPlaceKind.notable
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.source = source
        self.createdAt = createdAt
        self.kind = kind
    }

    var isNotable: Bool { kind == NamedPlaceKind.notable }

    /// The name as the store keeps it: without the whitespace around it.
    /// Nil when nothing is left, which the store refuses.
    static func name(from typed: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Every lookup is by name, so names that differ only in case or in the
    /// whitespace around them are one name.
    static func isSameName(_ name: String, as other: String) -> Bool {
        let trimmed = { (name: String) in name.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmed(name).caseInsensitiveCompare(trimmed(other)) == .orderedSame
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        CLLocation(latitude: self.latitude, longitude: self.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude))
            <= radiusMeters
    }
}

/// How much the store holds, so the user never has to find the file to find out.
struct LocationHistorySummary: Sendable, Equatable {
    let sampleCount: Int
    let peopleSampleCount: Int
    let oldest: Date?
    let newest: Date?
    let placeCount: Int
}

enum LocationHistoryError: Swift.Error, ClientFacingError, Equatable {
    case unavailable
    case invalidRequest(String)
    case unknownPlace(String)
    case ambiguousPerson(String, identifiers: [String])

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The location history store is unavailable."
        case .invalidRequest(let detail):
            return detail
        case .unknownPlace(let name):
            return "No place named \"\(name)\". Call location_places for the ones that exist."
        case .ambiguousPerson(let name, let identifiers):
            return
                "More than one Find My person is named \"\(name)\". Use one of these identifiers: \(identifiers.joined(separator: ", "))."
        }
    }
}

/// The device recording without Find My People rows: what tool health and the
/// window both mean by "recording".
/// Maps' answer for one spot: the venues around it, closest first, and its
/// street address.
struct SpotLookup: Sendable, Equatable, Codable {
    var venues: [NearbyVenue]
    var address: String?
}

struct DeviceRecording: Sendable, Equatable {
    let began: Date
    /// The newest fix, the signed-in user's own when there is one.
    let latest: LocationSample
}

/// iMCP's own record of where devices have been.
///
/// Apple exposes no location history at all through Find My — only the latest
/// fix — so anything historical has to be recorded here as it happens. Nothing
/// in this file leaves the Mac.
actor LocationHistoryStore {
    /// How long a recorded fix is kept. Apple exposes no history of its own,
    /// so this file is the only record; it still has to stop growing.
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    private let url: URL
    private let now: @Sendable () -> Date
    private var handle: OpaquePointer?
    private var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        url: URL = LocationHistoryStore.defaultURL(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.now = now
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        watchers.values.forEach { $0.finish() }
    }

    /// One element after every write that changed what the store holds: a
    /// new sample, a delete, a purge, or a place change.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        watchers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching(id) }
        }
        return stream
    }

    /// Bumped with every change `changes()` reports.
    private(set) var revision = 0

    private func stopWatching(_ id: UUID) {
        watchers[id] = nil
    }

    private func changed() {
        revision += 1
        watchers.values.forEach { $0.yield() }
    }

    static func defaultURL() -> URL {
        WireContract.appSupportDirectory().appendingPathComponent("location-history.sqlite")
    }

    // MARK: - Writing

    /// Appends samples, refreshing mutable labels on fixes already recorded.
    ///
    /// Find My answers from a cache, so the poller sees the same fix many times
    /// over. `(provider, subject, timestamp)` is the logical identity and the insert ignores
    /// conflicts, which makes recording idempotent instead of filling the store
    /// with duplicates of one position. Names may change after the fix was first
    /// seen, so a repeated fix refreshes those display-only fields.
    func record(_ samples: [LocationSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let db = try connection()
        let sql = """
            INSERT INTO samples
            (provider, subject_id, subject_kind, source_device_id,
             device_id, device_name, person_name, is_me, latitude, longitude,
             accuracy, position_type, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, subject_id, timestamp) DO UPDATE SET
                device_name = excluded.device_name,
                person_name = excluded.person_name
            WHERE samples.device_name IS NOT excluded.device_name
               OR samples.person_name IS NOT excluded.person_name
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }

        var written = 0
        for sample in samples {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, sample.provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, sample.subjectID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, sample.subjectKind, -1, SQLITE_TRANSIENT)
            if let sourceDeviceID = sample.sourceDeviceID {
                sqlite3_bind_text(statement, 4, sourceDeviceID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_text(statement, 5, sample.deviceID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 6, sample.deviceName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 7, sample.personName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 8, sample.isMe ? 1 : 0)
            sqlite3_bind_double(statement, 9, sample.latitude)
            sqlite3_bind_double(statement, 10, sample.longitude)
            if let accuracy = sample.accuracyMeters {
                sqlite3_bind_double(statement, 11, accuracy)
            } else {
                sqlite3_bind_null(statement, 11)
            }
            if let positionType = sample.positionType {
                sqlite3_bind_text(statement, 12, positionType, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 12)
            }
            sqlite3_bind_double(statement, 13, sample.timestamp.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Self.unavailable(db)
            }
            written += Int(sqlite3_changes(db))
        }
        try prune(db)
        try enforceOwnerOnlyPermissions()
        if written > 0 { changed() }
        return written
    }

    // MARK: - Reading

    func samples(
        person: String? = nil,
        device: String? = nil,
        from start: Date,
        to end: Date,
        everySeconds interval: Int? = nil,
        limit: Int = 1000,
        includePeople: Bool = false
    ) throws -> [LocationSample] {
        let db = try connection()
        var conditions = ["timestamp >= ?", "timestamp < ?"]
        var values: [String] = []
        if !includePeople {
            conditions.append("provider != ?")
            values.append(LocationSampleProvider.people)
        }
        // A web person's identifier names no column: it is the provider and
        // a lowercased name, so rows are matched on the whole key as read.
        var webPerson: String?
        if let person {
            switch LocationSubjectKey.parse(person) {
            case .friend(let identifier):
                conditions.append("provider = ? AND subject_id = ?")
                values.append(LocationSampleProvider.people)
                values.append(identifier)
            case .webPerson(let identifier):
                conditions.append("provider = ?")
                values.append(LocationSampleProvider.web)
                webPerson = identifier
            case .name:
                if includePeople {
                    let matches = try logicalPersonIdentifiers(named: person, db: db)
                    guard matches.count < 2 else {
                        throw LocationHistoryError.ambiguousPerson(person, identifiers: matches)
                    }
                }
                conditions.append("person_name = ? COLLATE NOCASE")
                values.append(person)
            }
        }
        if let device {
            conditions.append("device_name = ? COLLATE NOCASE")
            values.append(device)
        }
        let sql = """
            SELECT \(Self.sampleColumnList)
            FROM samples
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY timestamp DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 3), value, -1, SQLITE_TRANSIENT)
        }

        var rows: [LocationSample] = []
        // Read newest first so a full `limit` drops the oldest rows, never
        // the latest; the result goes back out in time order. Downsampling
        // keeps the newest sample in each bucket per device.
        var lastBucket: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let sample = Self.sample(from: statement)
            if let webPerson, LocationSubjectKey.person(of: sample) != webPerson { continue }
            if let interval, interval > 0 {
                let bucket = Int(sample.timestamp.timeIntervalSince1970) / interval
                // Per device: a person's phone and watch thin independently.
                let identity = "\(sample.provider):\(sample.subjectID):\(sample.sourceDeviceID ?? "")"
                if lastBucket[identity] == bucket { continue }
                lastBucket[identity] = bucket
            }
            rows.append(sample)
            if rows.count >= limit { break }
        }
        return rows.reversed()
    }

    /// How much the store holds and how far back. Counting is cheap enough to
    /// do on demand and always honest.
    func summary() throws -> LocationHistorySummary {
        let db = try connection()
        var statement: OpaquePointer?
        let sql = """
            SELECT COUNT(*), MIN(timestamp), MAX(timestamp),
                   SUM(CASE WHEN provider = ? THEN 1 ELSE 0 END)
            FROM samples
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, LocationSampleProvider.people, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw Self.unavailable(db)
        }
        let count = Int(sqlite3_column_int64(statement, 0))
        let oldest =
            sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let newest =
            sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        return LocationHistorySummary(
            sampleCount: count,
            peopleSampleCount: Int(sqlite3_column_int64(statement, 3)),
            oldest: oldest,
            newest: newest,
            placeCount: try places().count
        )
    }

    func deviceRecording() throws -> DeviceRecording? {
        let db = try connection()
        var began: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "SELECT MIN(timestamp) FROM samples WHERE provider != ?", -1, &began, nil)
                == SQLITE_OK
        else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(began) }
        sqlite3_bind_text(began, 1, LocationSampleProvider.people, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(began) == SQLITE_ROW else { throw Self.unavailable(db) }
        guard sqlite3_column_type(began, 0) != SQLITE_NULL else { return nil }
        let start = Date(timeIntervalSince1970: sqlite3_column_double(began, 0))

        var latest: OpaquePointer?
        let sql = """
            SELECT \(Self.sampleColumnList) FROM samples
            WHERE provider != ?
            ORDER BY is_me DESC, timestamp DESC
            LIMIT 1
            """
        guard sqlite3_prepare_v2(db, sql, -1, &latest, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(latest) }
        sqlite3_bind_text(latest, 1, LocationSampleProvider.people, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(latest) == SQLITE_ROW else { throw Self.unavailable(db) }
        return DeviceRecording(began: start, latest: Self.sample(from: latest))
    }

    /// Throws the recorded positions away. Named places survive: they are
    /// something the user typed, not something the sampler collected.
    func deleteSamples() throws {
        let db = try connection()
        guard
            sqlite3_exec(
                db,
                "DELETE FROM samples; DELETE FROM routes; DELETE FROM spots; PRAGMA wal_checkpoint(TRUNCATE)",
                nil,
                nil,
                nil
            )
                == SQLITE_OK
        else {
            throw Self.unavailable(db)
        }
        changed()
    }

    /// The routes Maps gave for steps of the track, by `RouteMatching.Leg`
    /// key. They are worked out from the recorded positions, so they are
    /// kept here and go with them: deleting the history deletes them, and
    /// they age out with it.
    func routes(for keys: [String]) throws -> [String: RouteMatching.Answer] {
        guard !keys.isEmpty else { return [:] }
        let db = try connection()
        var found: [String: RouteMatching.Answer] = [:]
        // SQLite's variable limit is far above a week of steps, but a long
        // range is read in pages anyway.
        for start in stride(from: 0, to: keys.count, by: 500) {
            let page = Array(keys[start ..< min(keys.count, start + 500)])
            let sql = "SELECT key, path FROM routes WHERE key IN (\(page.map { _ in "?" }.joined(separator: ",")))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.unavailable(db) }
            defer { sqlite3_finalize(statement) }
            for (offset, key) in page.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), key, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(statement, 0))
                let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Double>.size
                guard count >= 4, let bytes = sqlite3_column_blob(statement, 1) else {
                    found[key] = RouteMatching.Answer.none
                    continue
                }
                let values = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Double.self), count: count)
                found[key] = .path(
                    stride(from: 0, to: count - 1, by: 2).map {
                        CLLocationCoordinate2D(latitude: values[$0], longitude: values[$0 + 1])
                    }
                )
            }
        }
        return found
    }

    /// Keeps one route. Not a change to the history, so nothing watching the
    /// store reloads for it.
    func saveRoute(_ answer: RouteMatching.Answer, for key: String) throws {
        let db = try connection()
        var values: [Double] = []
        if case .path(let points) = answer {
            values = points.flatMap { [$0.latitude, $0.longitude] }
        }
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO routes (key, path, saved_at) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.unavailable(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        if values.isEmpty {
            // A null pointer would bind NULL; "no route" is an empty blob.
            sqlite3_bind_zeroblob(statement, 2, 0)
        } else {
            values.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
            }
        }
        sqlite3_bind_double(statement, 3, now().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.unavailable(db) }
    }

    /// What Maps said about the spots the window's stops were at: the
    /// venues nearby and the street address, by building key. Like routes,
    /// they come from the recorded positions and go with them.
    func spots(for keys: [String]) throws -> [String: SpotLookup] {
        guard !keys.isEmpty else { return [:] }
        let db = try connection()
        var found: [String: SpotLookup] = [:]
        for start in stride(from: 0, to: keys.count, by: 500) {
            let page = Array(keys[start ..< min(keys.count, start + 500)])
            let sql = "SELECT key, value FROM spots WHERE key IN (\(page.map { _ in "?" }.joined(separator: ",")))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.unavailable(db) }
            defer { sqlite3_finalize(statement) }
            for (offset, key) in page.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), key, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(statement, 0))
                guard let bytes = sqlite3_column_blob(statement, 1) else { continue }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
                if let spot = try? JSONDecoder().decode(SpotLookup.self, from: data) { found[key] = spot }
            }
        }
        return found
    }

    /// Keeps one spot's lookup. Not a change to the history.
    func saveSpot(_ spot: SpotLookup, for key: String) throws {
        let db = try connection()
        let data = try JSONEncoder().encode(spot)
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO spots (key, value, saved_at) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.unavailable(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(statement, 3, now().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.unavailable(db) }
    }

    func deletePeopleSamples() throws {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM samples WHERE provider = ?", -1, &statement, nil) == SQLITE_OK
        else {
            throw Self.unavailable(db)
        }
        sqlite3_bind_text(statement, 1, LocationSampleProvider.people, -1, SQLITE_TRANSIENT)
        // The checkpoint cannot truncate the WAL while the statement is live.
        let stepped = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard stepped == SQLITE_DONE else { throw Self.unavailable(db) }
        changed()
        guard sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
    }

    var fileURL: URL { url }

    func places(includePeople: Bool = true) throws -> [NamedPlace] {
        let db = try connection()
        var statement: OpaquePointer?
        let sql = """
            SELECT id, name, latitude, longitude, radius, source, created_at, kind
            FROM places WHERE ? OR source != ? ORDER BY name ASC
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, includePeople ? 1 : 0)
        sqlite3_bind_text(statement, 2, NamedPlaceSource.findMyPeople, -1, SQLITE_TRANSIENT)
        var rows: [NamedPlace] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                NamedPlace(
                    id: String(cString: sqlite3_column_text(statement, 0)),
                    name: String(cString: sqlite3_column_text(statement, 1)),
                    latitude: sqlite3_column_double(statement, 2),
                    longitude: sqlite3_column_double(statement, 3),
                    radiusMeters: sqlite3_column_double(statement, 4),
                    source: String(cString: sqlite3_column_text(statement, 5)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    kind: String(cString: sqlite3_column_text(statement, 7))
                )
            )
        }
        return rows
    }

    /// Creates a place, or moves and renames one that already exists.
    ///
    /// Named places are matched by name because that is the only handle a
    /// caller has; `renaming` is what makes a rename different from creating a
    /// second place at the same spot.
    @discardableResult
    func setPlace(
        name typed: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        source: String,
        kind: String = NamedPlaceKind.notable,
        renaming previousName: String? = nil
    ) throws -> NamedPlace {
        let name = try Self.requireName(typed)
        try Self.validate(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
        let existing = try places()
        let target = previousName ?? name
        let match = existing.first { NamedPlace.isSameName($0.name, as: target) }
        if previousName != nil, match == nil {
            throw LocationHistoryError.unknownPlace(target)
        }
        if previousName != nil {
            try Self.requireUnused(name, by: match?.id, in: existing)
        }
        return try write(
            NamedPlace(
                id: match?.id ?? UUID().uuidString,
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters,
                source: source,
                createdAt: match?.createdAt ?? Date(),
                kind: kind
            )
        )
    }

    /// Changes the place with `id` in place: its name, radius and kind, and
    /// its centre only when one is given. Its source and creation date stay,
    /// so a place the user found by address search is never moved or
    /// relabelled by renaming it.
    @discardableResult
    func updatePlace(
        id: String,
        name typed: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radiusMeters: Double,
        kind: String
    ) throws -> NamedPlace {
        let name = try Self.requireName(typed)
        let existing = try places()
        guard let place = existing.first(where: { $0.id == id }) else {
            throw LocationHistoryError.unknownPlace(name)
        }
        let latitude = latitude ?? place.latitude
        let longitude = longitude ?? place.longitude
        try Self.validate(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
        try Self.requireUnused(name, by: id, in: existing)
        return try write(
            NamedPlace(
                id: id,
                name: name,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters,
                source: place.source,
                createdAt: place.createdAt,
                kind: kind
            )
        )
    }

    private static func validate(latitude: Double, longitude: Double, radiusMeters: Double) throws {
        let radius = LocationPolicy.PlaceRadius.bounds
        guard
            CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
            radius.contains(radiusMeters)
        else {
            throw LocationHistoryError.invalidRequest(
                "Latitude must be -90 to 90, longitude -180 to 180, and radiusMeters "
                    + "\(Int(radius.lowerBound)) to \(Int(radius.upperBound))."
            )
        }
    }

    private static func requireName(_ typed: String) throws -> String {
        guard let name = NamedPlace.name(from: typed) else {
            throw LocationHistoryError.invalidRequest("A place needs a name.")
        }
        return name
    }

    /// Every lookup is by name, so two rows sharing one would be
    /// indistinguishable.
    private static func requireUnused(_ name: String, by id: String?, in places: [NamedPlace]) throws {
        guard places.contains(where: { $0.id != id && NamedPlace.isSameName($0.name, as: name) })
        else { return }
        throw LocationHistoryError.invalidRequest("A place named \"\(name)\" already exists. Choose another name.")
    }

    private func write(_ place: NamedPlace) throws -> NamedPlace {
        let db = try connection()
        let sql = """
            INSERT INTO places (id, name, latitude, longitude, radius, source, created_at, kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                radius = excluded.radius,
                source = excluded.source,
                kind = excluded.kind
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, place.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, place.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 3, place.latitude)
        sqlite3_bind_double(statement, 4, place.longitude)
        sqlite3_bind_double(statement, 5, place.radiusMeters)
        sqlite3_bind_text(statement, 6, place.source, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 7, place.createdAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 8, place.kind, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Self.unavailable(db)
        }
        changed()
        return place
    }

    /// Matched by name, case-insensitively, because that is the handle a tool
    /// client has.
    @discardableResult
    func deletePlace(named name: String) throws -> Bool {
        guard let match = try places().first(where: { NamedPlace.isSameName($0.name, as: name) })
        else { return false }
        return try deletePlace(id: match.id)
    }

    @discardableResult
    func deletePlace(id: String) throws -> Bool {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM places WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.unavailable(db) }
        guard sqlite3_changes(db) > 0 else { return false }
        changed()
        return true
    }

    // MARK: - Connection

    private func connection() throws -> OpaquePointer {
        if let handle { return handle }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw LocationHistoryError.unavailable
            }
        }
        var db: OpaquePointer?
        guard
            sqlite3_open_v2(
                url.path,
                &db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK,
            let db
        else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            log.error("Failed to open the location history store: \(message, privacy: .public)")
            throw LocationHistoryError.unavailable
        }
        do {
            try Self.migrate(db)
            try prune(db)
            try enforceOwnerOnlyPermissions()
        } catch {
            sqlite3_close(db)
            throw error
        }
        handle = db
        return db
    }

    private func prune(_ db: OpaquePointer) throws {
        let cutoff = now().addingTimeInterval(-Self.retention).timeIntervalSince1970
        for sql in [
            "DELETE FROM samples WHERE timestamp < ?",
            "DELETE FROM routes WHERE saved_at < ?",
            "DELETE FROM spots WHERE saved_at < ?",
        ] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw Self.unavailable(db)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Self.unavailable(db)
            }
        }
    }

    private static func unavailable(_ db: OpaquePointer) -> LocationHistoryError {
        let message = String(cString: sqlite3_errmsg(db))
        log.error("Location history store failed: \(message, privacy: .public)")
        return .unavailable
    }

    private static func migrate(_ db: OpaquePointer) throws {
        let initialStatements = [
            "PRAGMA journal_mode = WAL",
            "PRAGMA secure_delete = ON",
            "PRAGMA temp_store = MEMORY",
            """
            CREATE TABLE IF NOT EXISTS samples (
                provider TEXT NOT NULL DEFAULT 'find-my-web',
                subject_id TEXT NOT NULL,
                subject_kind TEXT NOT NULL DEFAULT 'device',
                source_device_id TEXT,
                device_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                person_name TEXT NOT NULL,
                is_me INTEGER NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                accuracy REAL,
                position_type TEXT,
                timestamp REAL NOT NULL,
                PRIMARY KEY (provider, subject_id, timestamp)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS spots (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL,
                saved_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS routes (
                key TEXT PRIMARY KEY,
                path BLOB NOT NULL,
                saved_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS places (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                radius REAL NOT NULL,
                source TEXT NOT NULL,
                created_at REAL NOT NULL,
                kind TEXT NOT NULL DEFAULT 'notable'
            )
            """,
        ]
        for sql in initialStatements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw Self.unavailable(db)
            }
        }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        do {
            let columns = try columns(of: "samples", db)
            let additions = [
                ("provider", "ALTER TABLE samples ADD COLUMN provider TEXT NOT NULL DEFAULT 'find-my-web'"),
                ("subject_id", "ALTER TABLE samples ADD COLUMN subject_id TEXT"),
                ("subject_kind", "ALTER TABLE samples ADD COLUMN subject_kind TEXT NOT NULL DEFAULT 'device'"),
                ("source_device_id", "ALTER TABLE samples ADD COLUMN source_device_id TEXT"),
            ]
            for (column, sql) in additions where !columns.contains(column) {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw Self.unavailable(db)
                }
            }
            if !(try Self.columns(of: "places", db)).contains("kind") {
                let sql = "ALTER TABLE places ADD COLUMN kind TEXT NOT NULL DEFAULT 'notable'"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw Self.unavailable(db)
                }
            }
            let statements = [
                "UPDATE samples SET subject_id = device_id WHERE subject_id IS NULL OR subject_id = ''",
                "UPDATE samples SET source_device_id = device_id WHERE source_device_id IS NULL AND provider = 'find-my-web'",
                "CREATE INDEX IF NOT EXISTS samples_by_time ON samples (timestamp)",
                "CREATE UNIQUE INDEX IF NOT EXISTS samples_by_subject_fix ON samples (provider, subject_id, timestamp)",
                "PRAGMA user_version = 2",
            ]
            for sql in statements {
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                    throw Self.unavailable(db)
                }
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw Self.unavailable(db)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func columns(of table: String, _ db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            columns.insert(String(cString: sqlite3_column_text(statement, 1)))
        }
        return columns
    }

    private func logicalPersonIdentifiers(named name: String, db: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        let sql = """
            SELECT DISTINCT provider, subject_id, person_name FROM samples
            WHERE person_name = ? COLLATE NOCASE
            ORDER BY provider, subject_id
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.unavailable(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        var identifiers = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let provider = String(cString: sqlite3_column_text(statement, 0))
            let subjectID = String(cString: sqlite3_column_text(statement, 1))
            let personName = String(cString: sqlite3_column_text(statement, 2))
            identifiers.insert(
                LocationSubjectKey.person(provider: provider, subjectID: subjectID, personName: personName)
            )
        }
        return identifiers.sorted()
    }

    private func enforceOwnerOnlyPermissions() throws {
        let manager = FileManager.default
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        for protectedURL in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        where manager.fileExists(atPath: protectedURL.path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protectedURL.path)
        }
    }

    /// The columns `sample(from:)` reads, in its order.
    private static let sampleColumnList = """
        provider, subject_id, subject_kind, source_device_id, \
        device_id, device_name, person_name, is_me, latitude, longitude, \
        accuracy, position_type, timestamp
        """

    private static func sample(from statement: OpaquePointer?) -> LocationSample {
        LocationSample(
            provider: String(cString: sqlite3_column_text(statement, 0)),
            subjectID: String(cString: sqlite3_column_text(statement, 1)),
            subjectKind: String(cString: sqlite3_column_text(statement, 2)),
            sourceDeviceID: sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(statement, 3)),
            deviceID: String(cString: sqlite3_column_text(statement, 4)),
            deviceName: String(cString: sqlite3_column_text(statement, 5)),
            personName: String(cString: sqlite3_column_text(statement, 6)),
            isMe: sqlite3_column_int(statement, 7) == 1,
            latitude: sqlite3_column_double(statement, 8),
            longitude: sqlite3_column_double(statement, 9),
            accuracyMeters: sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 10),
            positionType: sqlite3_column_type(statement, 11) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(statement, 11)),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
        )
    }
}
