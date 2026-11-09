import CoreLocation
import Foundation

/// How a visit came to an end, as far as the evidence goes.
///
/// A recorded position is evidence that the phone was somewhere at a moment.
/// It says nothing about the moments in between, so "left at 18:48" is only
/// true when the next thing recorded is the phone somewhere else. Every other
/// ending is named for the reason the record stops, not for a departure the
/// data never saw.
enum VisitEnding: Equatable, Sendable {
    /// The next sample was somewhere else, within the gap threshold. The
    /// phone left between `lastObserved` and `departedBefore`.
    case movement(departedBefore: Date)
    /// The record stops for longer than the threshold. `until` is the next
    /// sample's time, or nil when nothing was recorded afterwards at all.
    case coverageGap(until: Date?)
    /// The requested range ends while the phone was still there.
    case queryBoundary
    /// The last sample is recent enough that the phone is presumably still
    /// there.
    case ongoing

    var name: String {
        switch self {
        case .movement: return "movement"
        case .coverageGap: return "coverageGap"
        case .queryBoundary: return "queryBoundary"
        case .ongoing: return "ongoing"
        }
    }
}

/// A run of samples that stayed put.
struct Visit: Equatable, Sendable {
    let samples: [LocationSample]
    let latitude: Double
    let longitude: Double
    let arrival: Date
    let lastObserved: Date
    let ending: VisitEnding
    /// The named place the centre lands in, when one does. Nil is not "no
    /// place"; it is "no name the user gave it".
    let place: NamedPlace?
    /// When no named place contains the centre, the closest one within
    /// `Rules.nearbyPlaceRadius` and how far away it is. "280 m from Office"
    /// is what turns an anonymous stay into "next door to work".
    let nearestPlace: NamedPlace?
    let nearestPlaceMeters: Double?

    init(
        samples: [LocationSample],
        latitude: Double,
        longitude: Double,
        arrival: Date,
        lastObserved: Date,
        ending: VisitEnding,
        place: NamedPlace?,
        nearestPlace: NamedPlace? = nil,
        nearestPlaceMeters: Double? = nil
    ) {
        self.samples = samples
        self.latitude = latitude
        self.longitude = longitude
        self.arrival = arrival
        self.lastObserved = lastObserved
        self.ending = ending
        self.place = place
        self.nearestPlace = nearestPlace
        self.nearestPlaceMeters = nearestPlaceMeters
    }

    /// One device has one visit at a time, so its arrival names it.
    var id: String { "visit-\(arrival.timeIntervalSince1970)" }
    var observedDuration: TimeInterval { lastObserved.timeIntervalSince(arrival) }
    var device: String { samples.first?.deviceName ?? "" }
}

/// A hole in the record longer than the threshold.
struct CoverageGap: Equatable, Sendable {
    let from: Date
    let to: Date
    var duration: TimeInterval { to.timeIntervalSince(from) }
}

struct DeviceTimeline: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let range: Range<Date>
    let sampleCount: Int
    /// Samples set aside because Apple's own accuracy radius was too wide to
    /// place them. They still count as contact with the phone.
    let ignoredLowAccuracyCount: Int
    let firstSampleAt: Date?
    let lastSampleAt: Date?
    let gaps: [CoverageGap]
    let visits: [Visit]
}

/// Deterministic rules from samples to visits. No clock, no network, no
/// store: everything it needs is an argument, so a test can check any rule
/// with a handful of samples.
enum VisitInference {
    struct Rules: Sendable {
        /// How far a stay can wander from its centre and still be one place.
        /// Wide enough for a building and a Wifi fix; narrow enough that the
        /// shop next door is somewhere else.
        var clusterRadius: CLLocationDistance = 150
        /// A silence longer than this is a hole in the record, not a stay.
        var maximumGap: TimeInterval = LocationPolicy.recordingOverdue
        /// A fix Apple itself places no tighter than this cannot say which
        /// building the phone was in.
        var maximumUsefulAccuracy: CLLocationDistance = 300
        /// Fewer samples than this is a single sighting, not a stay.
        var minimumSamples = 2
        var minimumDwell: TimeInterval = LocationPolicy.defaultDwell
        /// How far a named place can be and still be worth mentioning as
        /// context for an unnamed stay. A kilometre is "near work"; beyond
        /// that the nearest name says nothing about the stay.
        var nearbyPlaceRadius: CLLocationDistance = 1000

        init(minimumDwell: TimeInterval = LocationPolicy.defaultDwell) {
            self.minimumDwell = minimumDwell
        }
    }

    /// Reads one device's track. `samples` may be in any order and may hold
    /// other devices; only `deviceID` is used.
    static func timeline(
        deviceID: String,
        samples: [LocationSample],
        range: Range<Date>,
        now: Date,
        places: [NamedPlace],
        rules: Rules = Rules()
    ) -> DeviceTimeline {
        let track =
            samples
            .filter { $0.deviceID == deviceID && range.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        let usable = track.filter { isUsable($0, rules: rules) }
        var visits: [Visit] = []
        var successorIndex = 0
        for cluster in clusters(in: usable, rules: rules) {
            guard let first = cluster.first, let last = cluster.last else { continue }
            let centre = centre(of: cluster)
            while successorIndex < usable.count, usable[successorIndex].timestamp <= last.timestamp {
                successorIndex += 1
            }
            let next = successorIndex < usable.count ? usable[successorIndex].timestamp : nil
            let ending = ending(
                lastObserved: last.timestamp,
                next: next,
                range: range,
                now: now,
                rules: rules
            )
            let place = Self.place(containing: centre.latitude, longitude: centre.longitude, in: places)
            let nearest =
                place == nil
                ? nearestPlace(to: centre.latitude, longitude: centre.longitude, in: places, rules: rules) : nil
            visits.append(
                Visit(
                    samples: cluster,
                    latitude: centre.latitude,
                    longitude: centre.longitude,
                    arrival: first.timestamp,
                    lastObserved: last.timestamp,
                    ending: ending,
                    place: place,
                    nearestPlace: nearest?.place,
                    nearestPlaceMeters: nearest?.meters
                )
            )
        }
        return DeviceTimeline(
            deviceID: deviceID,
            deviceName: track.last?.deviceName ?? deviceID,
            range: range,
            sampleCount: track.count,
            ignoredLowAccuracyCount: track.count - usable.count,
            firstSampleAt: track.first?.timestamp,
            lastSampleAt: track.last?.timestamp,
            gaps: gaps(in: track.map { $0.timestamp }, range: range, now: now, rules: rules),
            visits: visits
        )
    }

    /// The device that was carried: the one seen in the most distinct
    /// places, then the one with the most samples. A Mac left at home moves
    /// nowhere on any day and must not be the timeline's source just because
    /// its id sorts first.
    static func mostMovedDevice(in samples: [LocationSample]) -> String? {
        var positions: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for sample in samples {
            // About a hundred metres, so a still device with a jittering Wifi
            // fix does not look like it travelled.
            let key = "\(Int(sample.latitude * 1000)),\(Int(sample.longitude * 1000))"
            positions[sample.deviceID, default: []].insert(key)
            counts[sample.deviceID, default: 0] += 1
        }
        return positions.max { left, right in
            if left.value.count != right.value.count {
                return left.value.count < right.value.count
            }
            let leftCount = counts[left.key] ?? 0
            let rightCount = counts[right.key] ?? 0
            if leftCount != rightCount {
                return leftCount < rightCount
            }
            return left.key < right.key
        }?.key
    }

    /// How many times each of `visits` was stayed at across `history`, counting
    /// the visit itself, for the window's "seen N times". Only unnamed visits
    /// are counted; a named place already has its answer. Two stays are the
    /// same spot when their centres are within `radius` of each other.
    static func recurrence(
        of visits: [Visit],
        in history: [Visit],
        radius: CLLocationDistance = Rules().clusterRadius
    ) -> [Int] {
        let unnamedHistory: [CLLocation] = history.compactMap { visit in
            guard visit.place == nil else { return nil }
            return CLLocation(latitude: visit.latitude, longitude: visit.longitude)
        }
        return visits.map { visit in
            guard visit.place == nil else { return 1 }
            let here = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            let matches = unnamedHistory.reduce(into: 0) { count, other in
                if here.distance(from: other) <= radius {
                    count += 1
                }
            }
            return max(1, matches)
        }
    }

    // MARK: - Rules

    /// The named place a point is inside. Places may overlap; the first by
    /// the order given wins, which for the store's lists is by name.
    static func place(containing latitude: Double, longitude: Double, in places: [NamedPlace]) -> NamedPlace? {
        places.first { $0.contains(latitude: latitude, longitude: longitude) }
    }

    /// The closest named place to a point, measured to its centre, when it
    /// is within `rules.nearbyPlaceRadius`.
    static func nearestPlace(
        to latitude: Double,
        longitude: Double,
        in places: [NamedPlace],
        rules: Rules = Rules()
    ) -> (place: NamedPlace, meters: Double)? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let candidates = places.map { place in
            (place, here.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)))
        }
        guard let closest = candidates.min(by: { $0.1 < $1.1 }), closest.1 <= rules.nearbyPlaceRadius else {
            return nil
        }
        return (closest.0, closest.1)
    }

    static func isUsable(_ sample: LocationSample, rules: Rules) -> Bool {
        guard let accuracy = sample.accuracyMeters else { return true }
        return accuracy <= rules.maximumUsefulAccuracy
    }

    /// Consecutive samples that stay within `clusterRadius` of their running
    /// centre, with no silence longer than `maximumGap` between neighbours.
    /// The centre moves with the samples so a building wider than the radius
    /// does not split into two stays at its edges; a step away from it that
    /// leaves the radius starts a new cluster.
    static func clusters(in track: [LocationSample], rules: Rules) -> [[LocationSample]] {
        var clusters: [[LocationSample]] = []
        var current: [LocationSample] = []
        var latitudeSum = 0.0
        var longitudeSum = 0.0
        for sample in track {
            if let previous = current.last {
                let silence = sample.timestamp.timeIntervalSince(previous.timestamp)
                let centre = (
                    latitude: latitudeSum / Double(current.count), longitude: longitudeSum / Double(current.count)
                )
                let distance = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
                    .distance(from: CLLocation(latitude: sample.latitude, longitude: sample.longitude))
                if silence > rules.maximumGap || distance > rules.clusterRadius {
                    clusters.append(current)
                    current = []
                    latitudeSum = 0
                    longitudeSum = 0
                }
            }
            current.append(sample)
            latitudeSum += sample.latitude
            longitudeSum += sample.longitude
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters.filter { cluster in
            guard cluster.count >= rules.minimumSamples,
                let first = cluster.first, let last = cluster.last
            else { return false }
            return last.timestamp.timeIntervalSince(first.timestamp) >= rules.minimumDwell
        }
    }

    static func centre(of cluster: [LocationSample]) -> (latitude: Double, longitude: Double) {
        let count = Double(max(cluster.count, 1))
        return (
            cluster.reduce(0) { $0 + $1.latitude } / count,
            cluster.reduce(0) { $0 + $1.longitude } / count
        )
    }

    static func ending(
        lastObserved: Date,
        next: Date?,
        range: Range<Date>,
        now: Date,
        rules: Rules
    ) -> VisitEnding {
        if let next {
            return next.timeIntervalSince(lastObserved) > rules.maximumGap
                ? .coverageGap(until: next)
                : .movement(departedBefore: next)
        }
        // Nothing recorded after this stay inside the range. Either the range
        // (or the present) cut it off, or the record stopped.
        let edge = min(range.upperBound, now)
        if edge.timeIntervalSince(lastObserved) <= rules.maximumGap {
            // A range that ends at (or within the threshold of) the present is
            // a question about now, not about a period that has closed.
            return now.timeIntervalSince(range.upperBound) <= rules.maximumGap ? .ongoing : .queryBoundary
        }
        return .coverageGap(until: nil)
    }

    /// Every silence longer than the threshold, including the one before the
    /// first sample and the one after the last, measured against the range
    /// clipped to the present.
    static func gaps(in timestamps: [Date], range: Range<Date>, now: Date, rules: Rules) -> [CoverageGap] {
        let end = min(range.upperBound, now)
        guard end > range.lowerBound else { return [] }
        var edges = [range.lowerBound]
        edges.append(contentsOf: timestamps.filter { $0 <= end })
        edges.append(end)
        var gaps: [CoverageGap] = []
        for (from, to) in zip(edges, edges.dropFirst()) where to.timeIntervalSince(from) > rules.maximumGap {
            gaps.append(CoverageGap(from: from, to: to))
        }
        return gaps
    }
}
