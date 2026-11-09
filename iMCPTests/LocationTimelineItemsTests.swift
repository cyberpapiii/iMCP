import CoreLocation
import MapKit
import SwiftUI
import XCTest

@testable import iMCP

/// The Location window's wording and drawing rules. Same evidence as the
/// tools, so the window can never say more than `location_timeline` does.
final class LocationTimelineItemsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = (latitude: 40.7464, longitude: -74.9445)
    private let office = (latitude: 40.7360, longitude: -74.9870)

    private func sample(
        minutes: Double,
        at point: (latitude: Double, longitude: Double)? = nil,
        accuracy: Double? = 15
    ) -> LocationSample {
        let point = point ?? home
        return LocationSample(
            deviceID: "phone",
            deviceName: "Rob's iPhone",
            personName: "Rob",
            isMe: true,
            latitude: point.latitude,
            longitude: point.longitude,
            accuracyMeters: accuracy,
            positionType: "Wifi",
            timestamp: base.addingTimeInterval(minutes * 60)
        )
    }

    private func stay(from: Double, to: Double, at point: (latitude: Double, longitude: Double)? = nil)
        -> [LocationSample]
    {
        stride(from: from, through: to, by: 10).map { sample(minutes: $0, at: point) }
    }

    private func visit(
        at point: (latitude: Double, longitude: Double),
        minutes: Double,
        ending: VisitEnding,
        place: NamedPlace? = nil
    ) -> Visit {
        let samples = stay(from: minutes, to: minutes + 20, at: point)
        return Visit(
            samples: samples,
            latitude: point.latitude,
            longitude: point.longitude,
            arrival: samples.first!.timestamp,
            lastObserved: samples.last!.timestamp,
            ending: ending,
            place: place
        )
    }

    func testItemsInterleaveVisitsAndGapsByTime() {
        let samples = stay(from: 0, to: 60) + stay(from: 180, to: 240, at: office)
        let timeline = VisitInference.timeline(
            deviceID: "phone",
            samples: samples,
            range: base ..< base.addingTimeInterval(300 * 60),
            now: base.addingTimeInterval(245 * 60),
            places: []
        )
        let items = LocationTimelineItems.items(from: timeline, recurrence: [1, 1])
        XCTAssertEqual(items.count, 3)
        guard case .visit = items[0], case .gap = items[1], case .visit = items[2] else {
            return XCTFail("expected visit, gap, visit; got \(items)")
        }
    }

    func testRecurrenceCountsUnnamedStaysAtTheSameSpotAcrossHistory() {
        let here = visit(at: home, minutes: 0, ending: .ongoing)
        let history = [
            here,
            visit(at: home, minutes: 1440, ending: .ongoing),
            visit(at: (latitude: home.latitude + 0.0005, longitude: home.longitude), minutes: 2880, ending: .ongoing),
            visit(at: office, minutes: 4320, ending: .ongoing),
        ]
        XCTAssertEqual(VisitInference.recurrence(of: [here], in: history), [3])
    }

    func testRecurrenceIsNotCountedForNamedPlaces() {
        let place = NamedPlace(
            id: "1",
            name: "Home",
            latitude: home.latitude,
            longitude: home.longitude,
            radiusMeters: 100,
            source: "manual",
            createdAt: base
        )
        let here = visit(at: home, minutes: 0, ending: .ongoing, place: place)
        XCTAssertEqual(VisitInference.recurrence(of: [here], in: [here, here, here]), [1])
    }

    func testRecurrencePreservesDuplicatesNamedExclusionsAndInclusiveRadius() {
        let here = visit(at: home, minutes: 0, ending: .ongoing)
        let there = visit(at: office, minutes: 60, ending: .ongoing)
        let place = NamedPlace(
            id: "1",
            name: "Office",
            latitude: office.latitude,
            longitude: office.longitude,
            radiusMeters: 100,
            source: "manual",
            createdAt: base
        )
        let named = visit(at: office, minutes: 120, ending: .ongoing, place: place)
        let distance = CLLocation(latitude: here.latitude, longitude: here.longitude)
            .distance(from: CLLocation(latitude: there.latitude, longitude: there.longitude))
        XCTAssertEqual(VisitInference.recurrence(of: [here], in: [there, there, named], radius: distance), [2])
        XCTAssertEqual(
            VisitInference.recurrence(of: [here], in: [there, there], radius: distance.nextDown),
            [1]
        )
        XCTAssertEqual(VisitInference.recurrence(of: [here], in: []), [1])
        XCTAssertEqual(VisitInference.recurrence(of: [], in: [there]), [])
    }

    func testEndingWordsSayUnknownWhereTheRecordDoes() {
        let ongoing = visit(at: home, minutes: 0, ending: .ongoing)
        XCTAssertTrue(LocationTimelineItems.endingText(ongoing).hasPrefix("Still there"))

        let moved = visit(at: home, minutes: 0, ending: .movement(departedBefore: base.addingTimeInterval(30 * 60)))
        XCTAssertTrue(LocationTimelineItems.endingText(moved).hasPrefix("Left between"))

        let lost = visit(at: home, minutes: 0, ending: .coverageGap(until: nil))
        XCTAssertTrue(LocationTimelineItems.endingText(lost).contains("nothing since"))

        let lostThenBack = visit(at: home, minutes: 0, ending: .coverageGap(until: base.addingTimeInterval(7200)))
        XCTAssertTrue(LocationTimelineItems.endingText(lostThenBack).contains("back"))

        let boundary = visit(at: home, minutes: 0, ending: .queryBoundary)
        XCTAssertEqual(LocationTimelineItems.endingText(boundary), "Still there when the period ended")
    }

    func testDurationWords() {
        XCTAssertEqual(LocationTimelineItems.duration(30), "under a minute")
        XCTAssertEqual(LocationTimelineItems.duration(35 * 60), "35m")
        XCTAssertEqual(LocationTimelineItems.duration(2 * 3600), "2h")
        XCTAssertEqual(LocationTimelineItems.duration(2 * 3600 + 10 * 60), "2h 10m")
    }

    func testSolidSegmentsBreakAtGapsAndSkipLowAccuracy() {
        let samples =
            stay(from: 0, to: 20) + [sample(minutes: 25, accuracy: 900)] + stay(from: 120, to: 140, at: office)
        let segments = LocationTimelineItems.solidSegments(samples: samples)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].points.count, 3)
        XCTAssertEqual(segments[1].points.count, 3)
    }

    func testGapSpansJoinTheFixesEitherSideAndSkipOpenEndedGaps() {
        let samples = stay(from: 0, to: 20) + stay(from: 120, to: 140, at: office)
        let range = base ..< base.addingTimeInterval(400 * 60)
        let timeline = VisitInference.timeline(
            deviceID: "phone",
            samples: samples,
            range: range,
            now: base.addingTimeInterval(300 * 60),
            places: []
        )
        XCTAssertEqual(timeline.gaps.count, 2)
        let spans = LocationTimelineItems.gapSpans(samples: samples, gaps: timeline.gaps)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].from.latitude, home.latitude)
        XCTAssertEqual(spans[0].to.latitude, office.latitude)
    }

    func testColourRunsAdvanceWithDistanceAndStayContinuous() throws {
        let samples = stay(from: 0, to: 20) + stay(from: 120, to: 140, at: office)
        let segments = LocationTimelineItems.solidSegments(samples: samples)
        let span = try XCTUnwrap(LocationTimelineItems.trackSpan(of: segments))
        XCTAssertEqual(span.lowerBound, base)
        XCTAssertEqual(span.upperBound, base.addingTimeInterval(140 * 60))
        XCTAssertNil(LocationTimelineItems.trackSpan(of: []))

        // Two stays with no movement inside them: the whole line is one colour band.
        XCTAssertTrue(LocationTimelineItems.colourRuns(segments: segments).allSatisfy { $0.progress == 0 })

        // A walk from home to the office: colour advances along the way, never back.
        let walk = (0 ..< 10).map { step in
            sample(
                minutes: Double(step) * 3,
                at: (
                    latitude: home.latitude + (office.latitude - home.latitude) * Double(step) / 9,
                    longitude: home.longitude + (office.longitude - home.longitude) * Double(step) / 9
                )
            )
        }
        let runs = LocationTimelineItems.colourRuns(
            segments: LocationTimelineItems.solidSegments(samples: walk),
            bands: 8
        )
        XCTAssertEqual(runs.first?.progress, 0)
        XCTAssertEqual(runs.last?.progress, 1)
        XCTAssertEqual(runs.map(\.progress), runs.map(\.progress).sorted())
        XCTAssertTrue(runs.allSatisfy { $0.points.count > 1 })
        for (left, right) in zip(runs, runs.dropFirst()) {
            XCTAssertEqual(left.points.last?.latitude, right.points.first?.latitude)
        }
    }

    func testSmoothingKeepsTheEndsAndCutsTheCorner() {
        let corner = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
        ]
        let smooth = LocationTimelineItems.smoothed(corner, iterations: 1)
        XCTAssertEqual(smooth.first?.latitude, 0)
        XCTAssertEqual(smooth.last?.longitude, 1)
        XCTAssertFalse(smooth.contains { $0.latitude == 1 && $0.longitude == 0 }, "the corner itself is cut")
        XCTAssertEqual(LocationTimelineItems.smoothed(Array(corner.prefix(2))).count, 2, "a plain line is left alone")
    }

    func testGapSearchPreservesDuplicateBoundariesAndGapOrder() {
        let samples = [
            sample(minutes: 0), sample(minutes: 0, at: office),
            sample(minutes: 60, at: office), sample(minutes: 60),
        ]
        let gaps = [
            CoverageGap(from: base, to: base.addingTimeInterval(3600)),
            CoverageGap(from: base.addingTimeInterval(-60), to: base),
            CoverageGap(from: base.addingTimeInterval(3600), to: base.addingTimeInterval(7200)),
        ]
        let spans = LocationTimelineItems.gapSpans(samples: samples, gaps: gaps)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.from.latitude, office.latitude)
        XCTAssertEqual(spans.first?.to.latitude, office.latitude)
    }

    func testWindowWordsSayStopsPlacesAndLastSeen() {
        let visits = [
            visit(at: home, minutes: 0, ending: .queryBoundary),
            visit(at: office, minutes: 60, ending: .queryBoundary),
        ]
        func timeline(_ gaps: [CoverageGap], visits: [Visit], device: String = "Rob's iPhone") -> DeviceTimeline {
            DeviceTimeline(
                deviceID: "phone",
                deviceName: device,
                range: base ..< base.addingTimeInterval(86400),
                sampleCount: 479,
                ignoredLowAccuracyCount: 0,
                firstSampleAt: base,
                lastSampleAt: base,
                gaps: gaps,
                visits: visits
            )
        }
        XCTAssertEqual(
            LocationTimelineItems.summaryText(timeline([], visits: visits)),
            "Rob's iPhone · 2 stops · no gaps"
        )
        XCTAssertEqual(
            LocationTimelineItems.summaryText(
                timeline([CoverageGap(from: base, to: base.addingTimeInterval(80 * 60))], visits: [visits[0]])
            ),
            "Rob's iPhone · 1 stop · 1 gap of 1h 20m"
        )
        XCTAssertEqual(
            LocationTimelineItems.summaryText(
                timeline(
                    [
                        CoverageGap(from: base, to: base.addingTimeInterval(20 * 60)),
                        CoverageGap(from: base, to: base.addingTimeInterval(3 * 3600)),
                    ],
                    visits: [],
                    device: ""
                )
            ),
            "No device · 0 stops · 2 gaps, longest 3h"
        )

        let now = base.addingTimeInterval(86400)
        func seen(_ secondsAgo: TimeInterval, accuracy: Double? = 7) -> String {
            LocationTimelineItems.lastSeenText(
                at: now.addingTimeInterval(-secondsAgo),
                accuracyMeters: accuracy,
                now: now
            )
        }
        XCTAssertEqual(seen(13 * 60), "Last seen 13m ago, within 7 m")
        XCTAssertEqual(seen(20), "Last seen just now, within 7 m")
        XCTAssertEqual(seen(3600, accuracy: nil), "Last seen 1h ago")
        XCTAssertEqual(seen(5 * 3600, accuracy: nil), "Last seen 5h ago")
        XCTAssertEqual(seen(30 * 3600, accuracy: nil), "Last seen 1d ago")
        XCTAssertEqual(seen(3 * 86400, accuracy: nil), "Last seen 3d ago")
        XCTAssertEqual(LocationTimelineItems.lastSeenText(at: nil, accuracyMeters: nil, now: now), "Not seen yet")

        let found = LocationTimelineItems.StopLookup(address: "112 Harbor St", venues: [], suggestion: nil)
        let nothing = LocationTimelineItems.StopLookup(address: nil, venues: [], suggestion: nil)
        XCTAssertEqual(LocationTimelineItems.stopTitle(place: nil, lookup: found), "Near 112 Harbor St")
        XCTAssertEqual(LocationTimelineItems.stopTitle(place: nil, lookup: nothing), "Unnamed place")
        XCTAssertEqual(LocationTimelineItems.stopTitle(place: nil, lookup: nil), "Unnamed place")
    }

    func testPlaceSheetWordsNameThePlaceAndWhatWentWrong() {
        XCTAssertEqual(
            LocationTimelineItems.placeDetail(address: .street("112 Harbor St"), radiusMeters: 100),
            "112 Harbor St · 100 m radius"
        )
        XCTAssertEqual(
            LocationTimelineItems.placeDetail(address: .unknown, radiusMeters: 60),
            "No street address · 60 m radius"
        )
        XCTAssertEqual(
            LocationTimelineItems.placeDetail(address: nil, radiusMeters: 60),
            "Looking up the address · 60 m radius"
        )
        XCTAssertEqual(
            LocationTimelineItems.coordinatesText(latitude: 40.734012, longitude: -74.986949),
            "40.73401, -74.98695"
        )
        XCTAssertEqual(
            LocationTimelineItems.deleteWarningText(isNotable: true),
            "This removes it from the map and from the names agents use; your recorded history is kept."
        )
        XCTAssertEqual(
            LocationTimelineItems.deleteWarningText(isNotable: false),
            "This removes it from the names agents use; your recorded history is kept."
        )
        XCTAssertEqual(
            AddPlaceSheet.statusText(.idle),
            "Type a street address or the name of a venue, then press Return."
        )
        XCTAssertEqual(
            AddPlaceSheet.statusText(.nothingFound(query: "zzz")),
            "Nothing found for \u{201C}zzz\u{201D}. Try the full street address or another spelling."
        )
        XCTAssertEqual(AddPlaceSheet.statusText(.failed("Search failed.")), "Search failed.")
        let symbols = [AddPlaceSheet.Search.idle, .nothingFound(query: "zzz"), .failed("x"), .found([])]
            .map(AddPlaceSheet.statusSymbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testOnlyANewPlaceOfTheOwnersIsMarkedWhenSaved() {
        func place(_ name: String, _ kind: String) -> NamedPlace {
            NamedPlace(
                id: name,
                name: name,
                latitude: home.latitude,
                longitude: home.longitude,
                radiusMeters: 100,
                source: "manual",
                createdAt: base,
                kind: kind
            )
        }
        let notable = NamedPlaceKind.notable
        let label = NamedPlaceKind.label
        let existing = [place("Home", notable), place("Deli", label)]
        func adds(_ name: String, _ kind: String, renaming: NamedPlace? = nil) -> Bool {
            LocationTimelineItems.addsPlace(name: name, kind: kind, renaming: renaming, existing: existing)
        }

        XCTAssertTrue(adds(" Office\n", notable))
        XCTAssertTrue(LocationTimelineItems.addsPlace(name: "Office", kind: notable, renaming: nil, existing: []))
        XCTAssertFalse(adds("Office", label), "Naming one visit is not a new place")
        XCTAssertFalse(adds("home", notable), "Saving over a place the owner has")
        XCTAssertFalse(adds("House", notable, renaming: existing[0]), "Renaming a place")
        XCTAssertTrue(adds("Deli", notable, renaming: existing[1]), "A visit's name kept as a place")
        XCTAssertFalse(adds(" ", notable), "Nothing is saved without a name")
    }

    func testEachKindOfStopHasItsOwnOutline() {
        func place(_ kind: String) -> NamedPlace {
            NamedPlace(
                id: kind,
                name: kind,
                latitude: home.latitude,
                longitude: home.longitude,
                radiusMeters: 100,
                source: "manual",
                createdAt: base,
                kind: kind
            )
        }
        let kinds: [LocationTimelineItems.StopKind] = [
            .init(place(NamedPlaceKind.notable)), .init(place(NamedPlaceKind.label)), .init(nil),
        ]
        XCTAssertEqual(kinds, [.place, .label, .unnamed])
        let symbols = kinds.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testPinGrowsWithDurationButStaysBounded() {
        XCTAssertGreaterThan(LocationTimelineItems.pinDiameter(for: 0), 0)
        XCTAssertLessThan(LocationTimelineItems.pinDiameter(for: 3600), LocationTimelineItems.pinDiameter(for: 7200))
        XCTAssertEqual(
            LocationTimelineItems.pinDiameter(for: 48 * 3600),
            LocationTimelineItems.pinDiameter(for: 100 * 3600)
        )
    }

    func testEveryStayAtOnePlaceSharesOnePin() {
        let place = NamedPlace(
            id: "1",
            name: "Home",
            latitude: home.latitude,
            longitude: home.longitude,
            radiusMeters: 100,
            source: "manual",
            createdAt: base
        )
        let first = visit(at: home, minutes: 0, ending: .ongoing, place: place)
        let away = visit(at: office, minutes: 60, ending: .ongoing)
        let again = visit(at: (home.latitude + 0.0002, home.longitude), minutes: 120, ending: .ongoing, place: place)
        let pins = LocationTimelineItems.stopPins(
            from: [first, away, again].map { LocationTimelineItems.Item.visit($0, recurrence: 1) }
        )
        XCTAssertEqual(pins.map(\.title), ["Home", LocationTimelineItems.duration(away.observedDuration)])
        XCTAssertEqual(pins[0].ids, [first.id, again.id])
        XCTAssertEqual(pins[0].latitude, home.latitude, "a named place's pin sits on the place")
        XCTAssertGreaterThan(
            pins[0].diameter,
            LocationTimelineItems.pinDiameter(for: first.observedDuration),
            "the time adds up"
        )
    }

    func testUnnamedStaysNextToEachOtherShareAPinAndFarOnesDoNot() {
        let near = (latitude: home.latitude + 0.0003, longitude: home.longitude)  // about 33 m
        let pins = LocationTimelineItems.stopPins(
            from: [
                visit(at: home, minutes: 0, ending: .ongoing),
                visit(at: near, minutes: 60, ending: .ongoing),
                visit(at: office, minutes: 120, ending: .ongoing),
            ].map { LocationTimelineItems.Item.visit($0, recurrence: 1) }
        )
        XCTAssertEqual(pins.map(\.ids.count), [2, 1])
    }

    func testFixesDuringAStayFoldToTheStopAndMovementIsKept() {
        let here = visit(at: home, minutes: 0, ending: .ongoing)
        let jitter = here.samples.enumerated().map { index, sample in
            CLLocationCoordinate2D(latitude: sample.latitude + Double(index) * 0.00005, longitude: sample.longitude)
        }
        let walk = [
            CLLocationCoordinate2D(latitude: office.latitude, longitude: office.longitude),
            CLLocationCoordinate2D(latitude: office.latitude + 0.001, longitude: office.longitude),
        ]
        let after = here.lastObserved
        let segment = LocationTimelineItems.Segment(
            points: jitter + walk,
            times: here.samples.map(\.timestamp) + [after.addingTimeInterval(60), after.addingTimeInterval(120)]
        )
        let folded = LocationTimelineItems.collapsingStays([segment], visits: [here])
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded[0].points.count, 4, "the stay is its spot when it began and when it ended, then the walk")
        XCTAssertEqual(folded[0].points[0].latitude, here.latitude)
        XCTAssertEqual(folded[0].points[1].latitude, here.latitude)
        XCTAssertEqual(folded[0].times[1], here.lastObserved, "the step away is timed from leaving")
        XCTAssertEqual(folded[0].stops, [0, 1])
        XCTAssertEqual(folded[0].points[2].latitude, office.latitude)

        let pin = CLLocationCoordinate2D(latitude: home.latitude + 0.001, longitude: home.longitude)
        let anchored = LocationTimelineItems.collapsingStays([segment], visits: [here], anchors: [here.id: pin])
        XCTAssertEqual(anchored[0].points[0].latitude, pin.latitude, "a stay folds to its pin")
    }

    func testHeatPointsFillJourneysAndStayUnderTheLimit() {
        let walk = LocationTimelineItems.Segment(points: [
            CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude),
            CLLocationCoordinate2D(latitude: home.latitude + 0.01, longitude: home.longitude),  // about 1.1 km
        ])
        let points = LocationTimelineItems.heatPoints(samples: stay(from: 0, to: 30), paths: [walk])
        XCTAssertEqual(points.filter { $0.weight == 1 }.count, 4, "every recorded position counts in full")
        XCTAssertGreaterThan(points.filter { $0.weight < 1 }.count, 20, "the journey is filled in between")
        XCTAssertEqual(
            LocationTimelineItems.heatPoints(samples: stay(from: 0, to: 600), paths: [walk], limit: 10).count,
            10
        )
    }

    func testItemsAreGroupedUnderTheDayTheyStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23))!
        let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 1))!
        let gap = { (from: Date) in
            LocationTimelineItems.Item.gap(CoverageGap(from: from, to: from.addingTimeInterval(600)))
        }
        let days = LocationTimelineItems.days(
            [gap(late), gap(early), gap(early.addingTimeInterval(3600))],
            calendar: calendar
        )
        XCTAssertEqual(days.map(\.items.count), [1, 2])
        XCTAssertEqual(days.map(\.day), [calendar.startOfDay(for: late), calendar.startOfDay(for: early)])
    }

    /// Foundation sets the dash between thin spaces.
    func testTheTitleNamesTheDayOrTheDaysShown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 15))!
        XCTAssertEqual(
            LocationTimelineItems.periodTitle(lastDay: saturday, days: 1, calendar: calendar),
            "Saturday, Nov 7"
        )
        XCTAssertEqual(
            LocationTimelineItems.periodTitle(lastDay: saturday, days: 7, calendar: calendar),
            "Nov 1\u{2009}–\u{2009}7"
        )
        let firstOfDecember = calendar.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        XCTAssertEqual(
            LocationTimelineItems.periodTitle(lastDay: firstOfDecember, days: 3, calendar: calendar),
            "Nov 29\u{2009}–\u{2009}Dec 1"
        )
        XCTAssertEqual(LocationTimelineItems.periodTitle(lastDay: base, days: LocationPeriod.all.days), "All History")
    }
}

final class VenueSuggestionTests: XCTestCase {
    private func venue(_ name: String, _ meters: Double) -> NearbyVenue {
        NearbyVenue(name: name, category: nil, meters: meters)
    }

    func testAClearCloseWinnerIsSuggested() {
        let guess = LocationTimelineItems.suggestion(from: [venue("Deli", 95), venue("Juniper's", 18)])
        XCTAssertEqual(guess?.name, "Juniper's")
    }

    func testNothingIsSuggestedWhenTwoVenuesAreEquallyClose() {
        XCTAssertNil(LocationTimelineItems.suggestion(from: [venue("Juniper's", 18), venue("Florist", 25)]))
    }

    func testNothingIsSuggestedWhenTheClosestIsTooFar() {
        XCTAssertNil(LocationTimelineItems.suggestion(from: [venue("Juniper's", 55), venue("Deli", 300)]))
        XCTAssertNil(LocationTimelineItems.suggestion(from: []))
    }
}
