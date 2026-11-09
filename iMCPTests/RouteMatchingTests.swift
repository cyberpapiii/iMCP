import CoreLocation
import XCTest

@testable import iMCP

final class RouteMatchingTests: XCTestCase {
    private let home = CLLocationCoordinate2D(latitude: 40.7128, longitude: -73.9500)
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// A point `meters` north of home.
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: home.latitude + meters / 111_000, longitude: home.longitude)
    }

    private func segment(_ points: [CLLocationCoordinate2D], minutesApart: Double) -> LocationTimelineItems.Segment {
        LocationTimelineItems.Segment(
            points: points,
            times: points.indices.map { base.addingTimeInterval(Double($0) * minutesApart * 60) }
        )
    }

    func testStepsAreJudgedByLengthAndSpeed() {
        XCTAssertEqual(RouteMatching.travel(from: home, to: north(100), seconds: 600), .near)
        XCTAssertEqual(RouteMatching.travel(from: home, to: north(800), seconds: 600), .walking)
        XCTAssertEqual(RouteMatching.travel(from: home, to: north(5_000), seconds: 600), .driving)
        XCTAssertEqual(RouteMatching.travel(from: home, to: north(150_000), seconds: 600), .flight)
    }

    func testOnlyWalksAndDrivesAreAskedAboutAndEachOnce() {
        let there = segment([home, north(800), north(850)], minutesApart: 10)
        let back = segment([north(850), north(800), home], minutesApart: 10)
        let legs = RouteMatching.legs(in: [there, there, back])
        XCTAssertEqual(legs.map(\.travel), [.walking, .walking], "the 50 m step is too short to route")
        XCTAssertEqual(Set(legs.map(\.key)).count, 2, "the same walk twice is asked once")
        XCTAssertEqual(legs.first?.to.latitude, north(800).latitude, "the walk there, taken twice, is asked first")
    }

    func testARoutedStepFollowsTheStreetsAndStillMeetsTheFixes() throws {
        let track = segment([home, north(800)], minutesApart: 10)
        let leg = try XCTUnwrap(RouteMatching.legs(in: [track]).first)
        let corner = CLLocationCoordinate2D(latitude: north(400).latitude, longitude: home.longitude + 0.002)
        let shaped = RouteMatching.shape([track], routes: [leg.key: .path([home, corner, north(800)])])
        let path = try XCTUnwrap(shaped.ground.first).points
        XCTAssertTrue(path.contains { $0.longitude == corner.longitude }, "the street's corner is drawn")
        XCTAssertEqual(path.first?.latitude, home.latitude)
        XCTAssertEqual(path.last?.latitude, north(800).latitude)

        let unknown = RouteMatching.shape([track], routes: [:])
        XCTAssertEqual(unknown.ground.first?.points.count, 2, "without a route the step is drawn as recorded")
    }

    func testOnlyStaysAreJoinedToTheStreetAndRepeatWalksDrawTheSameLine() throws {
        let corner = CLLocationCoordinate2D(latitude: north(400).latitude, longitude: home.longitude + 0.002)
        let street = [CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude + 0.0003), corner]
        // Two walks from home to the same corner, each passing a fix a few
        // metres apart halfway; home is a stay both times.
        func walk(_ jitter: Double) -> LocationTimelineItems.Segment {
            LocationTimelineItems.Segment(
                points: [
                    home, CLLocationCoordinate2D(latitude: corner.latitude, longitude: corner.longitude + jitter),
                ],
                times: [base, base.addingTimeInterval(600)],
                stops: [0]
            )
        }
        let walks = [walk(0.00002), walk(-0.00002)]
        var routes: [String: RouteMatching.Answer] = [:]
        for leg in RouteMatching.legs(in: walks) { routes[leg.key] = .path(street) }
        let shaped = RouteMatching.shape(walks, routes: routes)
        let lines = shaped.ground.map { $0.points.map(\.longitude) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], lines[1], "the fixes on the move are left off, so both walks are the street")
        XCTAssertEqual(lines[0].first, home.longitude, "the stay is joined to the street")
    }

    func testAFlightIsAnArcApartFromTheJourneysOnEitherSide() {
        let track = segment([home, north(800), north(400_000), north(401_000)], minutesApart: 10)
        let shaped = RouteMatching.shape([track], routes: [:])
        XCTAssertEqual(shaped.ground.count, 2, "the walk before and the walk after")
        XCTAssertEqual(shaped.flights.count, 1)
        XCTAssertGreaterThan(shaped.flights[0].points.count, 2)
    }

    func testTheGreatCircleStartsAndEndsAtTheAirports() {
        let london = CLLocationCoordinate2D(latitude: 51.47, longitude: -0.45)
        let arc = RouteMatching.greatCircle(from: home, to: london)
        XCTAssertEqual(arc.first!.latitude, home.latitude, accuracy: 1e-9)
        XCTAssertEqual(arc.last!.longitude, london.longitude, accuracy: 1e-9)
        XCTAssertGreaterThan(arc.map(\.latitude).max()!, london.latitude, "it bends north over the Atlantic")
    }

    func testARoundaboutRouteIsNotBelieved() {
        XCTAssertTrue(RouteMatching.isPlausible(routeMeters: 1_100, between: home, and: north(800)))
        XCTAssertFalse(RouteMatching.isPlausible(routeMeters: 3_000, between: home, and: north(200)))
    }

    func testSimplifyingKeepsCornersAndDropsPointsAlongAStraightStreet() {
        let straight = (0 ... 20).map { north(Double($0) * 10) }
        let corner = CLLocationCoordinate2D(latitude: north(200).latitude, longitude: home.longitude + 0.002)
        let simple = RouteMatching.simplified(straight + [corner])
        XCTAssertEqual(simple.count, 3)
    }
}
