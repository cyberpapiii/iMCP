import XCTest

@testable import iMCP

/// The rules that turn recorded positions into stays, gaps, and endings.
/// Every case here is a shape of evidence the live history has produced;
/// the assertions say what may and may not be claimed from it.
final class VisitInferenceTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let home = (latitude: 40.7464, longitude: -74.9445)
    /// About a kilometre from `home`.
    private let office = (latitude: 40.7360, longitude: -74.9870)

    private func sample(
        minutes: Double,
        at point: (latitude: Double, longitude: Double)? = nil,
        accuracy: Double? = 15,
        device: String = "phone"
    ) -> LocationSample {
        let point = point ?? home
        return LocationSample(
            deviceID: device,
            deviceName: device == "phone" ? "Rob's iPhone" : "MacBook",
            personName: "Rob",
            isMe: true,
            latitude: point.latitude,
            longitude: point.longitude,
            accuracyMeters: accuracy,
            positionType: "Wifi",
            timestamp: base.addingTimeInterval(minutes * 60)
        )
    }

    /// Every 10 minutes from `from` to `to` inclusive.
    private func stay(
        from: Double,
        to: Double,
        at point: (latitude: Double, longitude: Double)? = nil
    ) -> [LocationSample] {
        stride(from: from, through: to, by: 10).map { sample(minutes: $0, at: point) }
    }

    /// `to` is exclusive, as the tools' `endDate` is.
    private func timeline(
        _ samples: [LocationSample],
        from: Double = 0,
        to: Double,
        now: Double? = nil,
        places: [NamedPlace] = [],
        rules: VisitInference.Rules = VisitInference.Rules()
    ) -> DeviceTimeline {
        VisitInference.timeline(
            deviceID: "phone",
            samples: samples,
            range: base.addingTimeInterval(from * 60) ..< base.addingTimeInterval(to * 60),
            now: base.addingTimeInterval((now ?? to) * 60),
            places: places,
            rules: rules
        )
    }

    func testLongStationaryTrackKeepsItsCentreAndEnding() throws {
        let samples = (0 ..< 4096).map { sample(minutes: Double($0)) }
        let result = timeline(samples, to: 4096)
        XCTAssertEqual(result.visits.count, 1)
        XCTAssertEqual(result.visits.first?.samples.count, samples.count)
        XCTAssertEqual(try XCTUnwrap(result.visits.first?.latitude), home.latitude, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.visits.first?.longitude), home.longitude, accuracy: 1e-9)
        XCTAssertEqual(result.visits.first?.ending, .ongoing)
    }

    func testSuccessorSkipsEqualTimestampsAndIncludesDiscardedSightings() {
        let samples =
            stay(from: 0, to: 20) + [
                sample(minutes: 20, at: office),
                sample(minutes: 25, at: office),
            ]
        let result = timeline(samples, to: 30)
        XCTAssertEqual(result.visits.count, 1)
        XCTAssertEqual(result.visits.first?.ending, .movement(departedBefore: base.addingTimeInterval(25 * 60)))
    }

    // MARK: - Gaps

    /// The live defect: 09-02 afternoon, one sample the next morning, and
    /// 09-03 evening at the same coordinates were reported as one 27-hour
    /// visit. A silence longer than three sampler intervals is a hole, and
    /// the stay before it ends in that hole, not in a departure.
    func testALongRecordingGapAtTheSameCoordinatesSplitsTheVisit() {
        let samples = stay(from: 0, to: 60) + stay(from: 60 + 300, to: 60 + 300 + 40)
        let result = timeline(samples, to: 60 + 300 + 41)

        XCTAssertEqual(result.visits.count, 2)
        XCTAssertEqual(result.visits[0].ending, .coverageGap(until: base.addingTimeInterval((360) * 60)))
        XCTAssertEqual(result.visits[0].lastObserved, base.addingTimeInterval(60 * 60))
        XCTAssertEqual(
            result.gaps,
            [CoverageGap(from: base.addingTimeInterval(60 * 60), to: base.addingTimeInterval(360 * 60))]
        )
    }

    /// Quit, reboot, or sign-out mid-stay: the record just stops. The stay
    /// ends in a gap with no "until", and the trailing silence is a gap.
    func testTheSamplerStoppingDuringAVisitEndsItInAnOpenGap() {
        let result = timeline(stay(from: 0, to: 60), to: 600)

        XCTAssertEqual(result.visits.count, 1)
        XCTAssertEqual(result.visits[0].ending, .coverageGap(until: nil))
        XCTAssertEqual(result.gaps.count, 1)
        XCTAssertEqual(result.gaps[0].from, base.addingTimeInterval(60 * 60))
        XCTAssertEqual(result.gaps[0].to, base.addingTimeInterval(600 * 60))
    }

    /// Asking about yesterday while the phone was still there at midnight is
    /// not a departure at midnight.
    func testTheQueryEndingDuringAVisitIsAQueryBoundary() {
        let result = timeline(stay(from: 0, to: 60), to: 70, now: 2_000)

        XCTAssertEqual(result.visits.count, 1)
        XCTAssertEqual(result.visits[0].ending, .queryBoundary)
        XCTAssertTrue(result.gaps.isEmpty)
    }

    func testAVisitSeenWithinTheThresholdOfNowIsOngoing() {
        let result = timeline(stay(from: 0, to: 60), to: 75)

        XCTAssertEqual(result.visits[0].ending, .ongoing)
    }

    // MARK: - Departure

    /// The only ending that supports "left": the next recorded position was
    /// somewhere else, and it came within the threshold.
    func testMovementToAnotherPlaceSupportsADepartureWindow() {
        let samples = stay(from: 0, to: 60) + stay(from: 70, to: 100, at: office)
        let result = timeline(samples, to: 200, now: 1_000)

        XCTAssertEqual(result.visits.count, 2)
        XCTAssertEqual(result.visits[0].ending, .movement(departedBefore: base.addingTimeInterval(70 * 60)))
        XCTAssertEqual(result.visits[0].lastObserved, base.addingTimeInterval(60 * 60))
        XCTAssertEqual(result.visits[1].arrival, base.addingTimeInterval(70 * 60))
        XCTAssertEqual(result.visits[1].ending, .coverageGap(until: nil))
    }

    // MARK: - Fix quality

    /// The live "brief stop near 713 Meridian Ave": one sample 250 m from
    /// home. One sighting is not a stay.
    func testASingleOutlierSampleIsNotAVisit() {
        let outlier = sample(minutes: 30, at: (40.74446, -74.94602))
        let samples = stay(from: 0, to: 20) + [outlier] + stay(from: 40, to: 80)
        let result = timeline(samples, to: 81, rules: VisitInference.Rules(minimumDwell: 0))

        XCTAssertEqual(result.visits.count, 2)
        XCTAssertTrue(result.visits.allSatisfy { $0.samples.count >= 2 })
        XCTAssertFalse(result.visits.contains { $0.samples.contains(outlier) })
    }

    /// A cell fix Apple itself places only within a kilometre says nothing
    /// about which building the phone was in. It neither splits the stay nor
    /// counts as a sample of it; it does count as contact with the phone.
    func testPoorAccuracyFixesAreSetAsideNotClustered() {
        let poor = sample(minutes: 30, at: office, accuracy: 1_000)
        let samples = stay(from: 0, to: 20) + [poor] + stay(from: 40, to: 60)
        let result = timeline(samples, to: 61)

        XCTAssertEqual(result.visits.count, 1)
        XCTAssertEqual(result.visits[0].samples.count, 6)
        XCTAssertEqual(result.ignoredLowAccuracyCount, 1)
        XCTAssertEqual(result.sampleCount, 7)
    }

    /// A building wider than the radius: samples drift 60 m at a time across
    /// 240 m. Anchoring on the first sample would split it; the running
    /// centre keeps it whole.
    func testADriftAcrossALargeBuildingStaysOneVisit() {
        // 0.00054 degrees of latitude is about 60 m.
        let drift = (0 ..< 5).map { step in
            sample(minutes: Double(step * 10), at: (home.latitude + Double(step) * 0.00054, home.longitude))
        }
        let result = timeline(drift, to: 41)

        XCTAssertEqual(result.visits.count, 1)
        XCTAssertEqual(result.visits[0].samples.count, 5)
    }

    func testAStepOutsideTheRadiusStartsANewVisit() {
        // 0.002 degrees of latitude is about 220 m.
        let next = (home.latitude + 0.002, home.longitude)
        let samples = stay(from: 0, to: 30) + stay(from: 40, to: 70, at: next)
        let result = timeline(samples, to: 71, now: 1_000)

        XCTAssertEqual(result.visits.count, 2)
    }

    // MARK: - Places and devices

    func testOnlyAUserNamedPlaceGivesAVisitAName() {
        let homePlace = NamedPlace(
            id: "home",
            name: "Home",
            latitude: home.latitude,
            longitude: home.longitude,
            radiusMeters: 150,
            source: "manual",
            createdAt: base
        )
        let samples = stay(from: 0, to: 30) + stay(from: 40, to: 70, at: office)
        let result = timeline(samples, to: 71, now: 1_000, places: [homePlace])

        XCTAssertEqual(result.visits[0].place?.name, "Home")
        XCTAssertNil(result.visits[1].place)
        XCTAssertEqual(StayName.label(place: "Home", nearAddress: nil), "Home")
        XCTAssertEqual(
            StayName.label(place: nil, nearAddress: "163 Quarry St, Brooklyn, NY"),
            "near 163 Quarry St, Brooklyn, NY"
        )
        XCTAssertEqual(StayName.label(place: nil, nearAddress: nil), "unnamed location")
        XCTAssertEqual(
            StayName.label(
                place: nil,
                nearAddress: "45 Main St, Brooklyn, NY",
                nearPlace: "Office",
                nearPlaceMeters: 280.4
            ),
            "near 45 Main St, Brooklyn, NY, 280 m from Office"
        )
        XCTAssertEqual(
            StayName.label(place: "Office", nearAddress: nil, nearPlace: "Home", nearPlaceMeters: 900),
            "Office"
        )
    }

    func testTheCarriedDeviceIsTheOneSeenInTheMostPlaces() {
        let mac = (0 ..< 20).map { sample(minutes: Double($0 * 10), device: "mac") }
        let phone = stay(from: 0, to: 30) + stay(from: 40, to: 70, at: office)

        XCTAssertEqual(VisitInference.mostMovedDevice(in: mac + phone), "phone")
    }

    func testARangeThatStartsBeforeTheFirstSampleHasALeadingGap() {
        let result = timeline(stay(from: 120, to: 180), from: 0, to: 180)

        XCTAssertEqual(result.gaps, [CoverageGap(from: base, to: base.addingTimeInterval(120 * 60))])
        XCTAssertEqual(result.firstSampleAt, base.addingTimeInterval(120 * 60))
    }

    func testAnEmptyRangeHasOneGapAndNoVisits() {
        let result = timeline([], from: 0, to: 600)

        XCTAssertTrue(result.visits.isEmpty)
        XCTAssertEqual(result.gaps.count, 1)
        XCTAssertEqual(result.sampleCount, 0)
    }
}

extension VisitInferenceTests {
    func testAnUnnamedStayNamesTheNearestPlaceWithinAKilometre() {
        let officePlace = NamedPlace(
            id: "1",
            name: "Office",
            latitude: office.latitude,
            longitude: office.longitude,
            radiusMeters: 100,
            source: "manual",
            createdAt: base
        )
        // About 300 m from the office: named as nearby, not as the office.
        let nextDoor = (latitude: office.latitude + 0.0027, longitude: office.longitude)
        let timeline = VisitInference.timeline(
            deviceID: "phone",
            samples: stay(from: 0, to: 30, at: nextDoor),
            range: base ..< base.addingTimeInterval(3600),
            now: base.addingTimeInterval(35 * 60),
            places: [officePlace]
        )
        XCTAssertEqual(timeline.visits.count, 1)
        XCTAssertNil(timeline.visits[0].place)
        XCTAssertEqual(timeline.visits[0].nearestPlace?.name, "Office")
        let meters = try? XCTUnwrap(timeline.visits[0].nearestPlaceMeters)
        XCTAssertEqual(meters ?? 0, 300, accuracy: 15)

        // Home is a kilometre and a half away: nothing nearby to mention.
        let far = VisitInference.timeline(
            deviceID: "phone",
            samples: stay(from: 0, to: 30, at: home),
            range: base ..< base.addingTimeInterval(3600),
            now: base.addingTimeInterval(35 * 60),
            places: [officePlace]
        )
        XCTAssertNil(far.visits[0].nearestPlace)
    }

    func testAStayInsideAPlaceDoesNotAlsoListItAsNearby() {
        let place = NamedPlace(
            id: "1",
            name: "Home",
            latitude: home.latitude,
            longitude: home.longitude,
            radiusMeters: 150,
            source: "manual",
            createdAt: base
        )
        let timeline = VisitInference.timeline(
            deviceID: "phone",
            samples: stay(from: 0, to: 30),
            range: base ..< base.addingTimeInterval(3600),
            now: base.addingTimeInterval(35 * 60),
            places: [place]
        )
        XCTAssertEqual(timeline.visits[0].place?.name, "Home")
        XCTAssertNil(timeline.visits[0].nearestPlace)
    }
}
