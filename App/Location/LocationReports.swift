import Foundation

// What the Location tools send. Field order is the JSON key order, so these
// declarations are wire format: add fields, never reorder or rename them.

/// Coordinates go out at six decimal places, about 11 cm. No fix iMCP can read
/// is that precise, and the trailing `Double` digits are pure payload in the
/// caller's context window.
func roundedDegrees(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
}

/// Distances go out at one decimal place. Accuracy radii are estimates; the
/// digits past a decimetre say nothing.
func roundedMeters(_ value: Double) -> Double {
    (value * 10).rounded() / 10
}

func roundedMeters(_ value: Double?) -> Double? {
    value.map(roundedMeters)
}

/// One person and where they are, flattened for a caller that just asked
/// "where is everyone".
struct PersonLocation: Encodable {
    let name: String
    let isMe: Bool
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracyMeters: Double?
    let fixTime: String?
    let fixAgeMinutes: Int?
    let isStale: Bool?
    /// Which of their devices the position came from. A person's location is
    /// always really a device's location, and saying which one lets the caller
    /// judge it: a phone in a pocket means more than a Mac left at home.
    let fromDevice: String?
    let deviceCount: Int
}

struct DeviceFix: Encodable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double?
    let fixTime: String
    let fixAgeMinutes: Int
    let positionType: String?
    let isStale: Bool
}

struct DeviceReport: Encodable {
    let id: String
    let name: String
    let model: String?
    let deviceClass: String?
    let owner: String
    let isMine: Bool
    let isThisDevice: Bool
    let batteryPercent: Int?
    let batteryStatus: String?
    let canPlaySound: Bool
    let location: DeviceFix?
}

struct HistorySample: Encodable {
    let person: String
    let device: String
    let time: String
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double?
    let positionType: String?
    let provider: String?
    let subjectIdentifier: String?
}

struct HistoryReport: Encodable {
    let samples: [HistorySample]
    /// True when the range held more than `limit` samples. The ones
    /// returned are the newest.
    let truncated: Bool
}

struct VenueReport: Encodable {
    let name: String
    let category: String?
    let meters: Int
}

struct VisitReport: Encodable {
    let person: String
    let fromDevice: String
    /// What to call the stay: the named place, or "near <address>" when the
    /// only name is a reverse-geocoded one. A geocoded address is the nearest
    /// street address to a 150 m cluster, not a confirmed destination.
    let label: String
    /// The user-named place this visit landed in, when one matches. Only a
    /// name the user gave is definitive.
    let place: String?
    /// "notable" when `place` is one of the user's own places; "label" when
    /// they only identified the spot. A labelled stop is not a significant
    /// place, just a named one.
    let placeKind: String?
    /// The nearest street address, when there is no named place.
    let nearAddress: String?
    /// Same as `nearAddress`. Kept for callers written against the old shape.
    let address: String?
    /// When no named place matches: the closest one within a kilometre and
    /// the distance to it, so "280 m from Office" can be read as "next door
    /// to work" rather than as an address nobody recognises.
    let nearPlace: String?
    let nearPlaceMeters: Int?
    /// Businesses Apple Maps lists within the fix's reach, closest first, when
    /// there is no named place. Candidates for what the stay was, not the
    /// answer: a fix sits within its own accuracy of several at once.
    let nearbyVenues: [VenueReport]?
    let latitude: Double
    let longitude: Double
    let arrival: String
    let lastObserved: String
    /// Only present when the next recorded position was somewhere else. It
    /// equals `lastObserved`; the phone left between then and
    /// `departedBefore`. Absent when the record stopped instead.
    let departure: String?
    let departedBefore: String?
    /// One of `VisitEnding.name`.
    let endedBy: String
    /// Minutes between arrival and the last observation. A lower bound.
    let durationMinutes: Int
    let sampleCount: Int
    let provider: String?
    let subjectIdentifier: String?
}

/// The tracked phone's latest fix and everything a reader needs to weigh it.
struct NowReport: Encodable {
    let person: String
    let device: String
    let deviceClass: String?
    let source: String
    let label: String?
    let place: String?
    let nearAddress: String?
    let nearPlace: String?
    let nearPlaceMeters: Int?
    let nearbyVenues: [VenueReport]?
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracyMeters: Double?
    let positionType: String?
    let fixTime: String?
    let fixAgeMinutes: Int?
    let isStale: Bool?
    let health: HealthReport
}

struct HealthReport: Encodable {
    /// One of `LocationHealth.ICloud`.
    let iCloud: String
    let iCloudDetail: String?
    let samplerRunning: Bool
    let expectedIntervalMinutes: Int
    let lastSampleAt: String?
    let lastSampleAgeMinutes: Int?
    let lastSampleFailure: String?
    /// One sentence a person can act on, or nil when everything is fine.
    let message: String?
}

struct GapReport: Encodable {
    let from: String
    let to: String
    let minutes: Int
}

struct CoverageReport: Encodable {
    let from: String
    let to: String
    let sampleCount: Int
    let ignoredLowAccuracySamples: Int
    let firstSampleAt: String?
    let lastSampleAt: String?
    let expectedIntervalMinutes: Int
    let gapThresholdMinutes: Int
    /// When this Mac first recorded anything. Nothing before it exists.
    let recordingBeganAt: String?
    let periodPredatesRecording: Bool
}

struct TimelineReport: Encodable {
    let person: String
    let device: String
    let coverage: CoverageReport
    let gaps: [GapReport]
    let visits: [VisitReport]
    let health: HealthReport
    /// A plain reading of the coverage, so an empty visit list is never
    /// mistaken for "was nowhere".
    let note: String
}

struct PlaceReport: Encodable {
    let name: String
    /// "notable": one of the user's own places, significant by their say-so.
    /// "label": a spot they identified once so stays there have a name; not
    /// a place that matters to them.
    let kind: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let source: String
    let createdAt: String
}

struct RingResult: Encodable {
    let device: String
    let played: Bool
}

// MARK: - Building the reports

extension PersonLocation {
    init(_ person: FindMyPerson, address: String?, now: Date) {
        let best = person.bestFix
        let age = best.map { now.timeIntervalSince($0.fix.timestamp) }
        self.init(
            name: person.name,
            isMe: person.isMe,
            address: address,
            latitude: best.map { roundedDegrees($0.fix.latitude) },
            longitude: best.map { roundedDegrees($0.fix.longitude) },
            horizontalAccuracyMeters: best.flatMap { roundedMeters($0.fix.horizontalAccuracy) },
            fixTime: best?.fix.timestamp.localISO8601,
            fixAgeMinutes: age.map { Int($0 / 60) },
            isStale: best.map { $0.fix.isStale(now: now) },
            fromDevice: best?.device.name,
            deviceCount: person.devices.count
        )
    }
}

extension FindMyFix {
    func isStale(now: Date) -> Bool {
        LocationPolicy.isStale(isOld: isOld, at: timestamp, now: now)
    }
}

extension DeviceReport {
    init(_ device: FindMyDevice, owner: String?, now: Date) {
        self.init(
            id: device.id,
            name: device.name,
            model: device.model,
            deviceClass: device.deviceClass,
            owner: owner ?? "Me",
            isMine: device.ownerID == nil,
            isThisDevice: device.isThisDevice,
            // Apple reports the level as a fraction; a percentage is what the
            // caller is going to talk about.
            batteryPercent: device.batteryLevel.map { Int(($0 * 100).rounded()) },
            batteryStatus: device.batteryStatus,
            canPlaySound: device.canPlaySound,
            location: device.location.map { fix in
                DeviceFix(
                    latitude: roundedDegrees(fix.latitude),
                    longitude: roundedDegrees(fix.longitude),
                    horizontalAccuracyMeters: roundedMeters(fix.horizontalAccuracy),
                    fixTime: fix.timestamp.localISO8601,
                    fixAgeMinutes: Int(now.timeIntervalSince(fix.timestamp) / 60),
                    positionType: fix.positionType,
                    isStale: fix.isStale(now: now)
                )
            }
        )
    }
}

extension HistorySample {
    /// A friend's sample names its provider and opaque identifier; a device
    /// sample leaves both out.
    init(_ sample: LocationSample) {
        let isPeople = sample.provider == LocationSampleProvider.people
        self.init(
            person: sample.personName,
            device: sample.deviceName,
            time: sample.timestamp.localISO8601,
            latitude: roundedDegrees(sample.latitude),
            longitude: roundedDegrees(sample.longitude),
            horizontalAccuracyMeters: roundedMeters(sample.accuracyMeters),
            positionType: sample.positionType,
            provider: isPeople ? sample.provider : nil,
            subjectIdentifier: isPeople ? sample.subjectID : nil
        )
    }
}

extension VenueReport {
    init(_ venue: NearbyVenue) {
        self.init(name: venue.name, category: venue.category, meters: wholeMeters(venue.meters))
    }
}

extension VisitReport {
    init(_ visit: Visit, person: String, description: PointDescription) {
        var departure: String?
        var departedBefore: String?
        if case .movement(let before) = visit.ending {
            departure = visit.lastObserved.localISO8601
            departedBefore = before.localISO8601
        }
        let first = visit.samples.first
        let isPeople = first?.provider == LocationSampleProvider.people
        self.init(
            person: person,
            fromDevice: visit.device,
            label: description.label,
            place: visit.place?.name,
            placeKind: visit.place?.kind,
            nearAddress: description.address,
            address: description.address,
            nearPlace: visit.nearestPlace?.name,
            nearPlaceMeters: visit.nearestPlaceMeters.map(wholeMeters),
            nearbyVenues: description.venues?.map(VenueReport.init),
            latitude: roundedDegrees(visit.latitude),
            longitude: roundedDegrees(visit.longitude),
            arrival: visit.arrival.localISO8601,
            lastObserved: visit.lastObserved.localISO8601,
            departure: departure,
            departedBefore: departedBefore,
            endedBy: visit.ending.name,
            durationMinutes: Int(visit.observedDuration / 60),
            sampleCount: visit.samples.count,
            provider: isPeople ? LocationSampleProvider.people : nil,
            subjectIdentifier: isPeople ? first?.subjectID : nil
        )
    }
}

extension NowReport {
    /// Where `location_now`'s answer came from.
    enum Source: String {
        case findMy
        case lastRecorded
    }

    /// One fix, already described. Its age and staleness are worked out here
    /// so every source says them the same way.
    struct Fix {
        let latitude: Double
        let longitude: Double
        let accuracyMeters: Double?
        let positionType: String?
        let timestamp: Date
        /// Apple's own stale flag; a recorded sample has none.
        let isOld: Bool
    }

    init(
        person: String,
        device: String,
        deviceClass: String?,
        source: Source,
        fix: Fix?,
        description: PointDescription?,
        now: Date,
        health: HealthReport
    ) {
        let age = fix.map { now.timeIntervalSince($0.timestamp) }
        self.init(
            person: person,
            device: device,
            deviceClass: deviceClass,
            source: source.rawValue,
            label: description?.label,
            place: description?.place?.name,
            nearAddress: description?.address,
            nearPlace: description?.nearestPlace?.name,
            nearPlaceMeters: description?.nearestPlaceMeters.map(wholeMeters),
            nearbyVenues: description?.venues?.map(VenueReport.init),
            latitude: fix.map { roundedDegrees($0.latitude) },
            longitude: fix.map { roundedDegrees($0.longitude) },
            horizontalAccuracyMeters: fix.flatMap { roundedMeters($0.accuracyMeters) },
            positionType: fix?.positionType,
            fixTime: fix?.timestamp.localISO8601,
            fixAgeMinutes: age.map { Int($0 / 60) },
            isStale: fix.map { LocationPolicy.isStale(isOld: $0.isOld, at: $0.timestamp, now: now) },
            health: health
        )
    }
}

extension HealthReport {
    init(_ health: LocationHealth, iCloudDetail: String?, message: String? = nil) {
        self.init(
            iCloud: health.iCloud.rawValue,
            iCloudDetail: iCloudDetail,
            samplerRunning: health.sampler.isRunning,
            expectedIntervalMinutes: LocationPolicy.expectedIntervalMinutes,
            lastSampleAt: health.latestFixAt?.localISO8601,
            lastSampleAgeMinutes: health.lastSampleAgeMinutes,
            lastSampleFailure: health.sampler.lastFailure,
            message: message ?? health.message
        )
    }
}

extension PlaceReport {
    init(_ place: NamedPlace) {
        self.init(
            name: place.name,
            kind: place.kind,
            latitude: roundedDegrees(place.latitude),
            longitude: roundedDegrees(place.longitude),
            radiusMeters: roundedMeters(place.radiusMeters),
            source: place.source,
            createdAt: place.createdAt.localISO8601
        )
    }
}
