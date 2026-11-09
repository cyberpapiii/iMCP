import CoreLocation
import Foundation

/// What the Location window draws and lists, worked out from a timeline with
/// no map, session, or store in the room. Pure so the wording and the
/// "seen N times" count can be tested without a window.
enum LocationTimelineItems {
    /// One row in the sidebar, in time order. A gap is a row of its own
    /// because an hour with no data is a fact about the day, not decoration.
    enum Item: Identifiable, Equatable {
        case visit(Visit, recurrence: Int)
        case gap(CoverageGap)

        var id: String {
            switch self {
            case .visit(let visit, _): return visit.id
            case .gap(let gap): return "gap-\(gap.from.timeIntervalSince1970)"
            }
        }

        var start: Date {
            switch self {
            case .visit(let visit, _): return visit.arrival
            case .gap(let gap): return gap.from
            }
        }
    }

    /// The items in order, under the day each starts on.
    static func days(_ items: [Item], calendar: Calendar = .current) -> [(day: Date, items: [Item])] {
        var days: [(day: Date, items: [Item])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.start)
            if days.last?.day == day {
                days[days.count - 1].items.append(item)
            } else {
                days.append((day, [item]))
            }
        }
        return days
    }

    static func items(from timeline: DeviceTimeline, recurrence: [Int]) -> [Item] {
        var rows: [Item] = []
        for (index, visit) in timeline.visits.enumerated() {
            rows.append(.visit(visit, recurrence: index < recurrence.count ? recurrence[index] : 1))
        }
        rows.append(contentsOf: timeline.gaps.map(Item.gap))
        return rows.sorted { $0.start < $1.start }
    }

    /// The line under a visit: what happened at the end, in the words a
    /// person would use. Says "unknown" where the record does.
    static func endingText(_ visit: Visit) -> String {
        switch visit.ending {
        case .ongoing:
            return "Still there · last seen \(clock(visit.lastObserved))"
        case .movement(let departedBefore):
            return "Left between \(clock(visit.lastObserved)) and \(clock(departedBefore))"
        case .coverageGap(let until):
            if let until {
                return "Signal lost after \(clock(visit.lastObserved)) · back \(clock(until))"
            }
            return "Signal lost after \(clock(visit.lastObserved)) · nothing since"
        case .queryBoundary:
            return "Still there when the period ended"
        }
    }

    /// What a stop is, which decides its icon in the list and its pin on the
    /// map. Each kind has its own outline, so it reads without colour.
    enum StopKind: Equatable {
        /// One of the owner's places, drawn on the map.
        case place
        /// A stop that was given a name without becoming a place.
        case label
        case unnamed

        init(_ place: NamedPlace?) {
            guard let place else {
                self = .unnamed
                return
            }
            self = place.isNotable ? .place : .label
        }

        var symbolName: String {
            switch self {
            case .place: return "mappin.circle.fill"
            case .label: return "circle.fill"
            case .unnamed: return "circle.dashed"
            }
        }
    }

    /// Offer the closest venue as a stop's name only when it is close and
    /// clearly closer than the runner-up. Anything less is a coin toss, and
    /// a wrong name is worse than an address.
    static func suggestion(from venues: [NearbyVenue]) -> NearbyVenue? {
        let sorted = venues.sorted { $0.meters < $1.meters }
        guard let closest = sorted.first, closest.meters <= 40 else { return nil }
        if let next = sorted.dropFirst().first, next.meters < closest.meters * 2 {
            return nil
        }
        return closest
    }

    /// What was looked up about an unnamed stop. A stop with no lookup yet is
    /// still being looked up.
    struct StopLookup: Equatable {
        /// The nearest street address: a street number, not a destination.
        var address: String?
        /// The nearest venues, closest first. Same list the tools report.
        var venues: [NearbyVenue]
        /// The one venue clear enough to offer; see `suggestion(from:)`.
        var suggestion: NearbyVenue?
    }

    /// A stop's title. `lookup` is nil while the address is being looked up;
    /// the title then holds the row's place and is drawn as a placeholder.
    static func stopTitle(place: NamedPlace?, lookup: StopLookup?) -> String {
        StayName.title(place: place?.name, address: lookup?.address, wording: .window)
    }

    /// What was looked up about the street a named place sits on.
    enum PlaceAddress: Equatable {
        case street(String)
        /// Looked up, and Maps had no street for it.
        case unknown
    }

    /// A named place's second line: its street and how far its name reaches.
    /// `address` is nil while the street is being looked up; the line then
    /// holds its room and is drawn as a placeholder.
    static func placeDetail(address: PlaceAddress?, radiusMeters: Double) -> String {
        let street: String
        switch address {
        case .street(let found): street = found
        case .unknown: street = "No street address"
        case nil: street = "Looking up the address"
        }
        return "\(street) · \(wholeMeters(radiusMeters)) m radius"
    }

    /// What "Copy Coordinates" puts on the clipboard.
    static func coordinatesText(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    /// Whether saving under `name` gives the owner a place they did not have:
    /// the one save a sheet marks. Naming a single visit does not, nor does
    /// saving again over one of their places, nor renaming one.
    static func addsPlace(name: String, kind: String, renaming: NamedPlace?, existing: [NamedPlace]) -> Bool {
        guard kind == NamedPlaceKind.notable, NamedPlace.name(from: name) != nil,
            renaming?.kind != NamedPlaceKind.notable
        else {
            return false
        }
        return !existing.contains { $0.kind == NamedPlaceKind.notable && NamedPlace.isSameName($0.name, as: name) }
    }

    static func saveFailureText(name: String, reason: String) -> String {
        guard let name = NamedPlace.name(from: name) else { return reason }
        return "\u{201C}\(name)\u{201D} was not saved. \(reason)"
    }

    static func deleteFailureText(name: String, reason: String) -> String {
        "\u{201C}\(name)\u{201D} was not deleted. \(reason)"
    }

    /// What deleting a place loses, for the confirmation.
    static func deleteWarningText(isNotable: Bool) -> String {
        isNotable
            ? "This removes it from the map and from the names agents use; your recorded history is kept."
            : "This removes it from the names agents use; your recorded history is kept."
    }

    /// One mark on the map for a place, however often it was visited: every
    /// stay at a named place, or unnamed stays close together, share it.
    struct StopPin: Equatable, Identifiable {
        /// The earliest stay's list ID; the map selects that stay.
        let id: String
        /// Every stay this pin stands for, so selecting any of them in the
        /// list marks it.
        let ids: [String]
        let latitude: Double
        let longitude: Double
        let title: String
        let diameter: CGFloat
        let kind: StopKind
    }

    /// Unnamed stays this close to a pin join it.
    static let pinMergeMeters: CLLocationDistance = 60

    static func stopPins(from items: [Item]) -> [StopPin] {
        struct Group {
            var ids: [String]
            var latitude: Double
            var longitude: Double
            var duration: TimeInterval
            var place: NamedPlace?
        }
        var groups: [Group] = []
        for item in items {
            guard case .visit(let visit, _) = item else { continue }
            let centre = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
            let match = groups.firstIndex { group in
                if let place = visit.place { return group.place?.id == place.id }
                return group.place == nil
                    && distance(CLLocationCoordinate2D(latitude: group.latitude, longitude: group.longitude), centre)
                        < pinMergeMeters
            }
            let weight = max(visit.observedDuration, 1)
            guard let index = match else {
                groups.append(
                    Group(
                        ids: [item.id],
                        latitude: visit.latitude,
                        longitude: visit.longitude,
                        duration: weight,
                        place: visit.place
                    )
                )
                continue
            }
            // The centre is weighted by time, so a night outweighs a minute.
            let total = groups[index].duration + weight
            groups[index].latitude = (groups[index].latitude * groups[index].duration + visit.latitude * weight) / total
            groups[index].longitude =
                (groups[index].longitude * groups[index].duration + visit.longitude * weight) / total
            groups[index].duration = total
            groups[index].ids.append(item.id)
        }
        return groups.map { group in
            StopPin(
                id: group.ids[0],
                ids: group.ids,
                latitude: group.place?.latitude ?? group.latitude,
                longitude: group.place?.longitude ?? group.longitude,
                title: group.place?.name ?? duration(group.duration),
                diameter: pinDiameter(for: group.duration),
                kind: StopKind(group.place)
            )
        }
    }

    /// One weighted spot for the heat map's density layer.
    struct HeatPoint: Equatable {
        let latitude: Double
        let longitude: Double
        /// A recorded position is 1; a point filled in along a journey
        /// between positions counts for less.
        let weight: Double
    }

    /// The density layer's spots: every usable recorded position, which
    /// piles up where time was spent, plus points every `spacing` metres
    /// along the travelled paths so journeys show as a trail. At most
    /// `limit`, thinned evenly, so drawing stays quick.
    static func heatPoints(
        samples: [LocationSample],
        paths: [Segment],
        spacing: CLLocationDistance = 25,
        limit: Int = 6000
    ) -> [HeatPoint] {
        var points = samples.filter { VisitInference.isUsable($0, rules: VisitInference.Rules()) }.map {
            HeatPoint(latitude: $0.latitude, longitude: $0.longitude, weight: 1)
        }
        for path in paths {
            for index in 1 ..< max(1, path.points.count) {
                let a = path.points[index - 1]
                let b = path.points[index]
                let steps = Int(distance(a, b) / spacing)
                guard steps > 0 else { continue }
                for step in 1 ... steps {
                    let t = Double(step) / Double(steps + 1)
                    points.append(
                        HeatPoint(
                            latitude: a.latitude + (b.latitude - a.latitude) * t,
                            longitude: a.longitude + (b.longitude - a.longitude) * t,
                            weight: 0.35
                        )
                    )
                }
            }
        }
        guard points.count > limit else { return points }
        let stride = Double(points.count) / Double(limit)
        return (0 ..< limit).map { points[Int(Double($0) * stride)] }
    }

    /// The track with each stay folded to its stop: the fixes recorded while
    /// the phone sat somewhere wander by tens of metres and drew a scribble
    /// over the pin. They become the stop's centre, once, so the line only
    /// shows movement and meets the pin where it is drawn.
    static func collapsingStays(
        _ segments: [Segment],
        visits: [Visit],
        anchors: [String: CLLocationCoordinate2D] = [:]
    ) -> [Segment] {
        segments.compactMap { segment in
            var points: [CLLocationCoordinate2D] = []
            var times: [Date] = []
            var stops: Set<Int> = []
            var lastStay: Int?
            var pointsInStay = 0
            for (point, time) in zip(segment.points, segment.times) {
                guard let stay = visits.firstIndex(where: { time >= $0.arrival && time <= $0.lastObserved }) else {
                    lastStay = nil
                    pointsInStay = 0
                    points.append(point)
                    times.append(time)
                    continue
                }
                // A stay is its pin's spot twice: once when it began and once
                // at its last fix, so the steps either side are timed from
                // arriving and from leaving. Every stay at one place shares
                // the spot, so the journeys from it start on top of each other.
                let visit = visits[stay]
                if stay != lastStay { pointsInStay = 0 }
                lastStay = stay
                if pointsInStay == 2 {
                    times[times.count - 1] = time
                    continue
                }
                let anchor =
                    anchors[visit.id]
                    ?? CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
                stops.insert(points.count)
                points.append(anchor)
                times.append(time)
                pointsInStay += 1
            }
            return points.count > 1 ? Segment(points: points, times: times, stops: stops) : nil
        }
    }

    /// The line above the list: whose day it is, how many stops, and whether
    /// the record has holes.
    static func summaryText(_ timeline: DeviceTimeline) -> String {
        let device = timeline.deviceName.isEmpty ? "No device" : timeline.deviceName
        let stops = timeline.visits.count == 1 ? "1 stop" : "\(timeline.visits.count) stops"
        let gaps: String
        if let longest = timeline.gaps.map(\.duration).max() {
            gaps =
                timeline.gaps.count == 1
                ? "1 gap of \(duration(longest))"
                : "\(timeline.gaps.count) gaps, longest \(duration(longest))"
        } else {
            gaps = "no gaps"
        }
        return "\(device) · \(stops) · \(gaps)"
    }

    /// The status strip's last part: when the device was last recorded and
    /// how exact that position was.
    static func lastSeenText(at date: Date?, accuracyMeters: Double?, now: Date = Date()) -> String {
        guard let date else { return "Not seen yet" }
        let accuracy = accuracyMeters.map { ", within \(wholeMeters($0)) m" } ?? ""
        return "Last seen \(RelativeAge.text(since: date, now: now))\(accuracy)"
    }

    static func gapText(_ gap: CoverageGap) -> String {
        "No data for \(duration(gap.duration)) · \(clock(gap.from)) to \(clock(gap.to))"
    }

    /// The Location window's title: the day itself, or the first and last
    /// day when several are shown.
    static func periodTitle(lastDay: Date, days: Int, calendar: Calendar = .current) -> String {
        if days == LocationPeriod.all.days { return "All History" }
        let last = calendar.startOfDay(for: lastDay)
        guard days > 1, let first = calendar.date(byAdding: .day, value: -(days - 1), to: last) else {
            var day = Date.FormatStyle.dateTime.weekday(.wide).month().day()
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            day.locale = calendar.locale ?? .current
            return last.formatted(day)
        }
        var style = Date.IntervalFormatStyle.interval.month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return (first ..< last).formatted(style)
    }

    /// "2h 10m", "35m", "under a minute".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Track segments the map may draw as a solid line: consecutive usable
    /// samples closer in time than the gap rule. Anything wider is a gap and
    /// is drawn dashed, because a straight line across an hour of silence
    /// would claim a route nobody observed.
    struct Segment: Equatable {
        let points: [CLLocationCoordinate2D]
        /// One timestamp per point, so the map can colour the line by time.
        let times: [Date]
        /// The indexes of points that are a stay's pin rather than a fix
        /// recorded on the move.
        let stops: Set<Int>

        init(points: [CLLocationCoordinate2D], times: [Date] = [], stops: Set<Int> = []) {
            self.points = points
            self.times = times
            self.stops = stops
        }

        static func == (lhs: Segment, rhs: Segment) -> Bool {
            lhs.points.count == rhs.points.count
                && lhs.times == rhs.times
                && lhs.stops == rhs.stops
                && zip(lhs.points, rhs.points).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    /// A run of consecutive track points that share one colour band, so the
    /// map can draw a gradient as a manageable number of solid polylines.
    /// `progress` is 0 at the start of the drawn track and 1 at its end.
    /// It advances with distance travelled, not with the clock: a nine hour
    /// stay is one colour and the commute either side gets the whole ramp,
    /// which is what makes direction readable on the line itself.
    struct ColourRun: Equatable {
        let points: [CLLocationCoordinate2D]
        let progress: Double

        static func == (lhs: ColourRun, rhs: ColourRun) -> Bool {
            lhs.progress == rhs.progress
                && lhs.points.count == rhs.points.count
                && zip(lhs.points, rhs.points).allSatisfy {
                    $0.latitude == $1.latitude && $0.longitude == $1.longitude
                }
        }
    }

    static func trackSpan(of segments: [Segment]) -> ClosedRange<Date>? {
        let times = segments.flatMap(\.times)
        guard let first = times.min(), let last = times.max() else { return nil }
        return first ... last
    }

    /// Chaikin corner cutting: each corner is replaced by two points a
    /// quarter of the way along its edges, so a zigzag of sparse fixes
    /// reads as a path. The ends stay exactly where the fixes were, and the
    /// cut never leaves the triangle of the three fixes around a corner.
    static func smoothed(_ points: [CLLocationCoordinate2D], iterations: Int = 2) -> [CLLocationCoordinate2D] {
        guard points.count > 2, iterations > 0 else { return points }
        var current = points
        for _ in 0 ..< iterations {
            var next: [CLLocationCoordinate2D] = [current[0]]
            for index in 0 ..< (current.count - 1) {
                let a = current[index]
                let b = current[index + 1]
                next.append(
                    CLLocationCoordinate2D(
                        latitude: a.latitude * 0.75 + b.latitude * 0.25,
                        longitude: a.longitude * 0.75 + b.longitude * 0.25
                    )
                )
                next.append(
                    CLLocationCoordinate2D(
                        latitude: a.latitude * 0.25 + b.latitude * 0.75,
                        longitude: a.longitude * 0.25 + b.longitude * 0.75
                    )
                )
            }
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }

    /// Split the drawn track (already shaped by `RouteMatching.shape`) into runs by distance travelled, in `bands` equal
    /// steps of the whole drawn length. Adjacent runs share their boundary
    /// point so the line stays continuous. Segments keep their order, so a
    /// gap in the record still advances the colour across it.
    static func colourRuns(
        segments: [Segment],
        bands: Int = 96
    ) -> [ColourRun] {
        let steps = max(1, bands)
        let paths = segments.map(\.points).filter { $0.count > 1 }
        var total: CLLocationDistance = 0
        for path in paths {
            for index in 1 ..< path.count { total += distance(path[index - 1], path[index]) }
        }
        guard total > 0 else {
            return paths.map { ColourRun(points: $0, progress: 0) }
        }
        func band(_ travelled: CLLocationDistance) -> Int {
            min(steps - 1, max(0, Int(travelled / total * Double(steps))))
        }
        var runs: [ColourRun] = []
        var travelled: CLLocationDistance = 0
        for path in paths {
            var points: [CLLocationCoordinate2D] = [path[0]]
            var current = band(travelled)
            for index in 1 ..< path.count {
                travelled += distance(path[index - 1], path[index])
                let next = band(travelled)
                if next != current {
                    runs.append(ColourRun(points: points, progress: progress(of: current, steps: steps)))
                    points = [path[index - 1]]
                    current = next
                }
                points.append(path[index])
            }
            if points.count > 1 {
                runs.append(ColourRun(points: points, progress: progress(of: current, steps: steps)))
            }
        }
        return runs
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func progress(of band: Int, steps: Int) -> Double {
        steps <= 1 ? 0 : Double(band) / Double(steps - 1)
    }

    static func solidSegments(
        samples: [LocationSample],
        rules: VisitInference.Rules = VisitInference.Rules()
    ) -> [Segment] {
        let track =
            samples
            .filter { VisitInference.isUsable($0, rules: rules) }
            .sorted { $0.timestamp < $1.timestamp }
        var segments: [Segment] = []
        var current: [CLLocationCoordinate2D] = []
        var times: [Date] = []
        var previous: Date?
        for sample in track {
            if let previous, sample.timestamp.timeIntervalSince(previous) > rules.maximumGap {
                if current.count > 1 { segments.append(Segment(points: current, times: times)) }
                current = []
                times = []
            }
            current.append(CLLocationCoordinate2D(latitude: sample.latitude, longitude: sample.longitude))
            times.append(sample.timestamp)
            previous = sample.timestamp
        }
        if current.count > 1 { segments.append(Segment(points: current, times: times)) }
        return segments
    }

    struct GapSpan: Equatable, Identifiable {
        let gap: CoverageGap
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D

        var id: String { Item.gap(gap).id }

        /// Whether the phone was most likely in the air while it was silent.
        var isFlight: Bool { RouteMatching.isFlight(from: from, to: to, seconds: gap.duration) }

        static func == (lhs: GapSpan, rhs: GapSpan) -> Bool {
            lhs.gap == rhs.gap
                && lhs.from.latitude == rhs.from.latitude && lhs.from.longitude == rhs.from.longitude
                && lhs.to.latitude == rhs.to.latitude && lhs.to.longitude == rhs.to.longitude
        }
    }

    /// The dashed span across each gap: the last fix before it to the first
    /// fix after it. A gap that runs to the present has no far end and is not
    /// drawn as a line at all.
    static func gapSpans(
        samples: [LocationSample],
        gaps: [CoverageGap]
    ) -> [GapSpan] {
        let track = samples.sorted { $0.timestamp < $1.timestamp }
        func boundary(_ date: Date, inclusive: Bool) -> Int {
            var low = 0
            var high = track.count
            while low < high {
                let middle = low + (high - low) / 2
                let timestamp = track[middle].timestamp
                if timestamp < date || (inclusive && timestamp == date) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }
        return gaps.compactMap { gap in
            let beforeIndex = boundary(gap.from, inclusive: true) - 1
            let afterIndex = boundary(gap.to, inclusive: false)
            guard beforeIndex >= 0, afterIndex < track.count else { return nil }
            let before = track[beforeIndex]
            let after = track[afterIndex]
            guard after.timestamp > before.timestamp else { return nil }
            return GapSpan(
                gap: gap,
                from: CLLocationCoordinate2D(latitude: before.latitude, longitude: before.longitude),
                to: CLLocationCoordinate2D(latitude: after.latitude, longitude: after.longitude)
            )
        }
    }

    /// Pin size for the time spent at a place: a lunch is a dot, a night is
    /// a disc. It grows with the square root, so a week at home is not a
    /// moon over the neighbourhood.
    static func pinDiameter(for duration: TimeInterval) -> CGFloat {
        let hours = max(0, duration / 3600)
        return CGFloat(min(36, 12 + hours.squareRoot() * 4))
    }
}
