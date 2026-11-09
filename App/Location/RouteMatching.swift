import CoreLocation
import MapKit

/// Turns the recorded track, one position every few minutes, into the way
/// it was most likely travelled. Each step between two positions is judged
/// by its length and the time it took: a few steps apart is drawn as it is,
/// a walk or a drive is asked of Apple Maps and drawn along the streets it
/// returns, and anything faster than a car is a flight, drawn as the arc a
/// plane flies. Maps' answers are kept in the history store, so each step is
/// asked about once.
enum RouteMatching {
    /// How a step between two recorded positions was most likely travelled.
    enum Travel: String, Sendable {
        /// Too short for a route to say anything; drawn straight.
        case near
        case walking
        case driving
        case flight
    }

    /// Shorter steps than this are drawn straight: a route between two
    /// points on one block is the block.
    static let shortestRoutedMeters: CLLocationDistance = 150
    /// About 8 km/h. Slower is on foot.
    static let walkingTopSpeed: CLLocationSpeed = 2.2
    /// About 250 km/h. Faster is in the air.
    static let flightSpeed: CLLocationSpeed = 70

    static func travel(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        seconds: TimeInterval
    ) -> Travel {
        let meters = distance(from, to)
        guard meters >= shortestRoutedMeters else { return .near }
        let speed = meters / max(seconds, 1)
        if speed > flightSpeed { return .flight }
        return speed > walkingTopSpeed ? .driving : .walking
    }

    /// Whether a hole in the record could only have been flown: covered
    /// faster than a car goes, or across more ground than anyone drives
    /// while their phone sleeps. Nine hours without a fix between two
    /// continents was a flight.
    static func isFlight(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, seconds: TimeInterval) -> Bool {
        travel(from: from, to: to, seconds: seconds) == .flight || distance(from, to) > longestDrive
    }

    /// Farther than this across a hole in the record is taken as a flight.
    static let longestDrive: CLLocationDistance = 1_500_000

    /// One step worth asking Maps about.
    struct Leg: Sendable {
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
        let travel: Travel

        /// The step as the store files it. Ends are rounded to about ten
        /// metres, so the same walk on another day finds the same answer.
        var key: String {
            func spot(_ point: CLLocationCoordinate2D) -> String {
                String(format: "%.4f,%.4f", point.latitude, point.longitude)
            }
            return "\(travel.rawValue)|\(spot(from))|\(spot(to))"
        }
    }

    /// What Maps said about a step: the streets to draw, or nothing worth
    /// drawing (no route, or one so roundabout it cannot be what happened).
    /// Both are kept; a step Maps could not be asked about is not.
    enum Answer: Sendable {
        case path([CLLocationCoordinate2D])
        case none
    }

    /// Asks Maps about one step. Nil when it could not be asked now, so it is
    /// asked again on a later load.
    typealias Router = @Sendable (Leg) async -> Answer?

    /// A router that never answers, so every step is drawn as recorded.
    static let offline: Router = { _ in nil }

    /// The steps in the track that a route would improve, each once, the
    /// most travelled first: Maps answers about one a second, and the
    /// streets walked every day are the ones the map is mostly made of.
    static func legs(in segments: [LocationTimelineItems.Segment]) -> [Leg] {
        var times: [String: Int] = [:]
        var legs: [Leg] = []
        for segment in segments {
            forEachStep(of: segment) { _, from, to, travel in
                guard travel == .walking || travel == .driving else { return }
                let leg = Leg(from: from, to: to, travel: travel)
                if times[leg.key] == nil { legs.append(leg) }
                times[leg.key, default: 0] += 1
            }
        }
        return legs.enumerated()
            .sorted { (times[$0.element.key]!, -$0.offset) > (times[$1.element.key]!, -$1.offset) }
            .map(\.element)
    }

    /// The track as it is drawn. `ground` is every journey on the ground,
    /// along the streets where Maps knew them and smoothed where it did not.
    /// `flights` are the steps taken by air, each its own arc, kept apart so
    /// an ocean crossing neither fills the heat map nor uses up the colour
    /// ramp of a day spent in town.
    struct Shaped {
        var ground: [LocationTimelineItems.Segment] = []
        var flights: [LocationTimelineItems.Segment] = []
    }

    static func shape(_ segments: [LocationTimelineItems.Segment], routes: [String: Answer]) -> Shaped {
        var shaped = Shaped()
        for segment in segments {
            var path: [CLLocationCoordinate2D] = []
            // Short steps not yet drawn, joined and smoothed together so a
            // run of them reads as one path.
            var straight: [CLLocationCoordinate2D] = []
            func append<C: Collection>(_ points: C) where C.Element == CLLocationCoordinate2D {
                for point in points {
                    if let last = path.last, last.latitude == point.latitude, last.longitude == point.longitude {
                        continue
                    }
                    path.append(point)
                }
            }
            func flushStraight() {
                append(LocationTimelineItems.smoothed(straight))
                straight = []
            }
            func flushPath() {
                flushStraight()
                if path.count > 1 { shaped.ground.append(LocationTimelineItems.Segment(points: path)) }
                path = []
            }
            forEachStep(of: segment) { index, from, to, travel in
                switch travel {
                case .flight:
                    flushPath()
                    shaped.flights.append(LocationTimelineItems.Segment(points: greatCircle(from: from, to: to)))
                case .walking, .driving:
                    if case .path(let streets) = routes[Leg(from: from, to: to, travel: travel).key], !streets.isEmpty {
                        flushStraight()
                        // A stay's pin is joined to the street, so the line
                        // meets it. A fix taken on the move is not: it is the
                        // street, give or take the fix's error, and the route
                        // already runs there. Joining each one drew a fan of
                        // spurs where one street was walked from fixes metres
                        // apart.
                        if segment.stops.contains(index - 1) || path.isEmpty { append([from]) }
                        append(streets)
                        if segment.stops.contains(index) { append([to]) }
                    } else {
                        if straight.isEmpty { straight = [path.last ?? from] }
                        straight.append(to)
                    }
                case .near:
                    if straight.isEmpty { straight = [path.last ?? from] }
                    straight.append(to)
                }
            }
            flushPath()
        }
        return shaped
    }

    /// Calls `body` for each step with the index of the point it ends at.
    private static func forEachStep(
        of segment: LocationTimelineItems.Segment,
        _ body: (Int, CLLocationCoordinate2D, CLLocationCoordinate2D, Travel) -> Void
    ) {
        let points = segment.points
        guard points.count > 1 else { return }
        for index in 1 ..< points.count {
            let seconds =
                index < segment.times.count
                ? segment.times[index].timeIntervalSince(segment.times[index - 1])
                : .infinity
            body(
                index,
                points[index - 1],
                points[index],
                travel(from: points[index - 1], to: points[index], seconds: seconds)
            )
        }
    }

    /// Whether a route Maps found could be the way the step was travelled.
    /// A walk of 200 m that Maps can only route as 3 km round a river is not
    /// what happened; the straight line says less, but nothing false.
    static func isPlausible(
        routeMeters: CLLocationDistance,
        between from: CLLocationCoordinate2D,
        and to: CLLocationCoordinate2D
    )
        -> Bool
    {
        routeMeters <= distance(from, to) * 2.2 + 300
    }

    /// Points along the shortest path over the globe, the line a plane flies.
    static func greatCircle(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        steps: Int = 48
    ) -> [CLLocationCoordinate2D] {
        func vector(_ point: CLLocationCoordinate2D) -> SIMD3<Double> {
            let lat = point.latitude * .pi / 180
            let lon = point.longitude * .pi / 180
            return SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        }
        let a = vector(from)
        let b = vector(to)
        let angle = acos(max(-1, min(1, (a * b).sum())))
        guard angle > 1e-9 else { return [from, to] }
        return (0 ... steps).map { step in
            let t = Double(step) / Double(steps)
            let v = (sin((1 - t) * angle) * a + sin(t * angle) * b) / sin(angle)
            return CLLocationCoordinate2D(
                latitude: atan2(v.z, (v.x * v.x + v.y * v.y).squareRoot()) * 180 / .pi,
                longitude: atan2(v.y, v.x) * 180 / .pi
            )
        }
    }

    /// Drops the points a line would pass within `tolerance` metres of
    /// anyway (Douglas-Peucker), so a street that Maps returns as hundreds
    /// of points is stored and drawn as the few its shape needs.
    static func simplified(_ points: [CLLocationCoordinate2D], tolerance: CLLocationDistance = 4)
        -> [CLLocationCoordinate2D]
    {
        guard points.count > 2 else { return points }
        let flat = points.map { MKMapPoint($0) }
        let perMeter = MKMapPointsPerMeterAtLatitude(points[0].latitude)
        let limit = tolerance * perMeter
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            let a = flat[start]
            let b = flat[end]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            var farthest = start
            var farthestDistance = 0.0
            for index in (start + 1) ..< end {
                let p = flat[index]
                let offset =
                    length > 0
                    ? abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / length
                    : ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
                if offset > farthestDistance {
                    farthestDistance = offset
                    farthest = index
                }
            }
            if farthestDistance > limit {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

/// Asks Apple Maps for walking and driving routes, taking turns with the
/// window's other Maps requests through a `MapsPacer`.
struct AppleMapsRouter: Sendable {
    let pacer: MapsPacer

    var router: RouteMatching.Router {
        { leg in await route(leg) }
    }

    func route(_ leg: RouteMatching.Leg) async -> RouteMatching.Answer? {
        guard await pacer.turn() else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg.from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: leg.to))
        request.transportType = leg.travel == .walking ? .walking : .automobile
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            guard
                let route = response.routes.first,
                RouteMatching.isPlausible(routeMeters: route.distance, between: leg.from, and: leg.to)
            else { return RouteMatching.Answer.none }
            let polyline = route.polyline
            let points = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount).map(\.coordinate)
            return .path(RouteMatching.simplified(points))
        } catch let error as MKError where error.code == .directionsNotFound {
            return RouteMatching.Answer.none
        } catch let error as MKError where error.code == .loadingThrottled {
            await pacer.refused()
            return nil
        } catch {
            // Offline or a server hiccup: ask again on a later load.
            return nil
        }
    }
}
