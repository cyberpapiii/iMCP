import CoreLocation
import MapKit
import SwiftUI
import XCTest

@testable import iMCP

/// Noon today. A test that records an hour of fixes ending "now" and then
/// reads today's stays must not run on the real clock: for the first hour
/// after midnight that hour straddles two days and today has no stay yet.
private func noonToday() -> Date {
    Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
}

/// The window's model against a real store: what the sidebar lists and what
/// naming a stay writes, with no Find My in the room.
final class LocationWindowModelTests: XCTestCase {
    @MainActor
    func testReloadListsTodaysStaysAndNamingWritesThePlaceTheToolsRead() async throws {
        let directory = temporaryDirectoryURL()
        let now = noonToday()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { now })
        var samples: [LocationSample] = []
        for minutesAgo in stride(from: 60, through: 5, by: -10) {
            samples.append(
                LocationSample(
                    deviceID: "phone",
                    deviceName: "Rob's iPhone",
                    personName: "Rob",
                    isMe: true,
                    latitude: 40.7464,
                    longitude: -74.9445,
                    accuracyMeters: 20,
                    positionType: "Wifi",
                    timestamp: now.addingTimeInterval(-Double(minutesAgo) * 60)
                )
            )
        }
        _ = try await store.record(samples)
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in
                [
                    NearbyVenue(name: "Corner Deli", category: "store", meters: 20),
                    NearbyVenue(name: "Bank", category: "bank", meters: 110),
                ]
            },
            addressLoader: { _, _ in "112 Harbor St" },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true, lastSuccessAt: now) },
            clock: TestClock(start: now).wallClock
        )

        await model.reload()
        XCTAssertEqual(model.lookups.values.map(\.suggestion?.name), ["Corner Deli"])
        XCTAssertEqual(model.lookups.values.map(\.address), ["112 Harbor St"])
        XCTAssertEqual(model.lookups.values.first?.venues.map(\.name), ["Corner Deli", "Bank"])
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.scene?.stops.map(\.kind), [.unnamed])

        let visits = model.items.compactMap { item -> Visit? in
            if case .visit(let visit, _) = item { return visit }
            return nil
        }
        XCTAssertEqual(visits.count, 1)
        XCTAssertNil(visits.first?.place)
        XCTAssertEqual(visits.first?.ending, .ongoing)
        XCTAssertEqual(model.latest?.deviceName, "Rob's iPhone")
        XCTAssertEqual(
            model.health?.line.components(separatedBy: " · ").suffix(2),
            ["Recording every 10 min", "Last seen 10m ago, within 20 m"]
        )

        model.sheet = .naming(visits[0])
        await model.name(visits[0], as: "  Home \n", radiusMeters: 80, kind: NamedPlaceKind.notable)
        XCTAssertEqual(model.savedPlace, "Home", "A new place is marked before its sheet closes")
        XCTAssertEqual(model.sheet, .naming(visits[0]), "The sheet closes itself once the mark has shown")
        model.sheet = nil
        XCTAssertTrue(model.lookups.isEmpty, "a named stop gets no guess")
        XCTAssertEqual(model.scene?.stops.map(\.kind), [.place])
        XCTAssertEqual(model.scene?.places.map(\.name), ["Home"])

        let places = try await store.places(includePeople: false)
        XCTAssertEqual(places.map(\.name), ["Home"])
        XCTAssertEqual(places.first?.radiusMeters, 80)
        XCTAssertEqual(places.first?.source, "manual")
        let named = model.items.compactMap { item -> Visit? in
            if case .visit(let visit, _) = item { return visit }
            return nil
        }
        XCTAssertEqual(named.first?.place?.name, "Home")

        model.sheet = .naming(named[0])
        XCTAssertNil(model.savedPlace, "A sheet that opens starts unmarked")
        await model.name(named[0], as: "House", radiusMeters: 80, kind: NamedPlaceKind.notable)
        XCTAssertNil(model.savedPlace, "Renaming a place is routine")
        XCTAssertNil(model.sheet)
        let renamed = try await store.places(includePeople: false)
        XCTAssertEqual(renamed.map(\.id), places.map(\.id), "Renaming changes the place, never adds one")
        XCTAssertEqual(renamed.map(\.name), ["House"])

        model.sheet = .adding
        await model.name(named[0], as: "Deli", radiusMeters: 60, kind: NamedPlaceKind.label)
        XCTAssertNil(model.savedPlace, "Naming one visit is routine")
        XCTAssertEqual(model.sheet, .adding, "Naming a visit must not dismiss the add-place sheet")
    }
}

extension LocationWindowModelTests {
    @MainActor
    func testAddingBySearchKeepsSearchResultInsteadOfNearbyRecordedFixes() async throws {
        let directory = temporaryDirectoryURL()
        let now = noonToday()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { now })
        // Fixes 60 m north of the address the user will search for.
        let address = (latitude: 40.7340, longitude: -74.9869)
        let landed = (latitude: address.latitude + 0.00054, longitude: address.longitude)
        var samples: [LocationSample] = []
        for minutesAgo in [50, 40, 30] {
            samples.append(
                LocationSample(
                    deviceID: "phone",
                    deviceName: "Rob's iPhone",
                    personName: "Rob",
                    isMe: true,
                    latitude: landed.latitude,
                    longitude: landed.longitude,
                    accuracyMeters: 10,
                    positionType: "Wifi",
                    timestamp: now.addingTimeInterval(-Double(minutesAgo) * 60)
                )
            )
        }
        _ = try await store.record(samples)
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { _, _ in nil },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) },
            clock: TestClock(start: now).wallClock
        )

        model.sheet = .adding
        await model.addPlace(
            name: "  Office \n",
            latitude: address.latitude,
            longitude: address.longitude,
            radiusMeters: 100
        )
        XCTAssertEqual(model.savedPlace, "Office")
        XCTAssertEqual(model.sheet, .adding, "The sheet closes itself once the mark has shown")
        model.sheet = nil
        XCTAssertEqual(model.places.map(\.name), ["Office"])
        XCTAssertEqual(model.places[0].latitude, address.latitude, accuracy: 0.000_001)
        XCTAssertEqual(model.places[0].longitude, address.longitude, accuracy: 0.000_001)
        let visits = model.items.compactMap { item -> Visit? in
            if case .visit(let visit, _) = item { return visit }
            return nil
        }
        XCTAssertEqual(visits.first?.place?.name, "Office")

    }

    @MainActor
    func testEditingPlaceUpdatesExistingRowInsteadOfRecreatingIt() async throws {
        let directory = temporaryDirectoryURL()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { _, _ in "8 Orchard St" },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) }
        )
        await model.addPlace(name: "Home", latitude: 40.749_468, longitude: -74.941_196, radiusMeters: 100)
        await model.lookUpPlaceAddresses()
        let original = try XCTUnwrap(model.places.first)
        XCTAssertEqual(model.placeAddresses[original.id], .street("8 Orchard St"))

        model.editingPlace = original
        await model.editPlace(
            original,
            name: "My Home",
            latitude: 40.749_387,
            longitude: -74.941_302,
            radiusMeters: 140
        )

        let places = try await store.places()
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places[0].id, original.id)
        XCTAssertEqual(places[0].name, "My Home")
        XCTAssertEqual(places[0].latitude, 40.749_387, accuracy: 0.000_001)
        XCTAssertEqual(places[0].longitude, -74.941_302, accuracy: 0.000_001)
        XCTAssertEqual(places[0].radiusMeters, 140)
        XCTAssertEqual(model.savedPlace, "My Home")
        XCTAssertNil(model.placeAddresses[original.id], "The old coordinate's address must be discarded")
    }
}

extension LocationWindowModelTests {
    @MainActor
    func testWindowRefreshStopsWhenClosedAndRestartsOnReopen() async throws {
        let directory = temporaryDirectoryURL()
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let counter = Counter()
        let clock = TestClock()
        let model = LocationWindowModel(
            store: LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite")),
            venueLookup: noVenues,
            session: { session },
            samplerStatus: {
                counter.increment()
                return LocationSamplerStatus(isRunning: false)
            },
            clock: clock.wallClock
        )
        clock.advance(by: 600)
        await model.settle()
        XCTAssertEqual(counter.value, 0, "Constructing a hidden model must not read history")

        let controller = LocationWindowController(model: model)
        controller.showWindow(nil)
        await model.settle()
        let visibleCount = counter.value
        XCTAssertEqual(visibleCount, 1, "Opening the window reads once, at once")
        clock.advance(by: 60)
        await model.settle()
        XCTAssertEqual(counter.value, 2, "An open window refreshes once a refresh interval")

        controller.close()
        let closedCount = counter.value
        clock.advance(by: 600)
        await model.settle()
        XCTAssertEqual(counter.value, closedCount, "Closing the window stops refreshes")

        controller.showWindow(nil)
        await model.settle()
        XCTAssertEqual(counter.value, closedCount + 1)
        controller.close()
    }
}

extension LocationWindowModelTests {
    @MainActor
    func testPlaceSaveKeepsSheetsOpenForEmptyNamesAndStorageFailures() async throws {
        let directory = try makeTemporaryDirectory()
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedDirectory)
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: LocationHistoryStore(url: blockedDirectory.appendingPathComponent("history.sqlite")),
            venueLookup: noVenues,
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: false) }
        )
        let visit = Visit(
            samples: [],
            latitude: 40,
            longitude: -73,
            arrival: Date(),
            lastObserved: Date(),
            ending: .ongoing,
            place: nil
        )
        model.sheet = .adding
        await model.addPlace(name: " \n", latitude: 40, longitude: -73, radiusMeters: 80)
        XCTAssertEqual(model.sheet, .adding)
        model.sheet = .naming(visit)
        await model.name(visit, as: " \n", radiusMeters: 80)
        XCTAssertNil(model.loadError, "An empty name must not attempt persistence")
        XCTAssertEqual(model.sheet, .naming(visit))
        XCTAssertEqual(model.placeError, "A place needs a name.", "the store refuses it before opening the file")

        let saveFailure = "\u{201C}Home\u{201D} was not saved. The recorded history could not be changed. Try again."
        model.sheet = .adding
        await model.addPlace(name: " Home\n", latitude: 40, longitude: -73, radiusMeters: 80)
        XCTAssertEqual(model.placeError, saveFailure)
        XCTAssertEqual(model.sheet, .adding)
        model.sheet = .naming(visit)
        await model.name(visit, as: "Home", radiusMeters: 80)
        XCTAssertEqual(model.placeError, saveFailure)
        XCTAssertEqual(model.sheet, .naming(visit))
        XCTAssertTrue(model.places.isEmpty)
        XCTAssertNil(model.savedPlace, "A save that failed is never marked as done")

        let place = NamedPlace(
            id: "1",
            name: "Office",
            latitude: 40,
            longitude: -73,
            radiusMeters: 80,
            source: "manual",
            createdAt: Date()
        )
        model.sheet = .listing
        XCTAssertNil(model.placeError, "A sheet that opens must not show another sheet's failure")
        await model.deletePlace(place)
        XCTAssertEqual(
            model.placeError,
            "\u{201C}Office\u{201D} was not deleted. The recorded history could not be changed. Try again."
        )
        XCTAssertEqual(model.sheet, .listing)
        model.sheet = nil
        XCTAssertNil(model.placeError)
        XCTAssertNil(model.loadError, "A sheet's failure belongs to the sheet, not the status strip")
    }

    @MainActor
    func testPlaceAddressesAreKeptOnceFoundAndSayWhenThereIsNoStreet() async throws {
        let directory = temporaryDirectoryURL()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let lookups = Counter()
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { latitude, _ in
                lookups.increment()
                return latitude > 40 ? "1 Main St" : nil
            },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) }
        )
        await model.addPlace(name: "Office", latitude: 40.7, longitude: -73.9, radiusMeters: 100)
        await model.addPlace(name: "Pier", latitude: 10, longitude: -73.9, radiusMeters: 100)
        let ids = Dictionary(uniqueKeysWithValues: model.places.map { ($0.name, $0.id) })
        XCTAssertTrue(model.placeAddresses.isEmpty)
        XCTAssertNil(model.cachedStreet(latitude: 40.7, longitude: -73.9))

        await model.lookUpPlaceAddresses()
        XCTAssertEqual(model.placeAddresses[try XCTUnwrap(ids["Office"])], .street("1 Main St"))
        XCTAssertEqual(model.placeAddresses[try XCTUnwrap(ids["Pier"])], .unknown)
        XCTAssertEqual(model.cachedStreet(latitude: 40.7, longitude: -73.9), "1 Main St")
        let asked = lookups.value

        await model.lookUpPlaceAddresses()
        let askedAgain = lookups.value
        XCTAssertEqual(askedAgain, asked + 1, "Only the place Maps had no street for is asked about again")

        await model.deletePlace(model.places[0])
        await model.lookUpPlaceAddresses()
        XCTAssertEqual(model.placeAddresses.keys.sorted(), model.places.map(\.id).sorted())
    }

    @MainActor
    func testPlaceSheetsAreAsTallAsTheirContentUpToAMaximum() async throws {
        let directory = temporaryDirectoryURL()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { _, _ in "1 Main St" },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) }
        )
        var scrolls = false
        func height<Sheet: View>(_ sheet: Sheet) -> CGFloat {
            let host = NSHostingView(rootView: sheet)
            let size = host.fittingSize
            XCTAssertEqual(size.width, DesignTokens.Size.sheetWidth)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            var views: [NSView] = [host]
            scrolls = false
            while let view = views.popLast() {
                if view is NSScrollView { scrolls = true }
                views.append(contentsOf: view.subviews)
            }
            return size.height
        }
        func addPlaces(_ range: Range<Int>) async {
            for index in range {
                await model.addPlace(
                    name: "Place \(index)",
                    latitude: 40 + Double(index) * 0.01,
                    longitude: -73,
                    radiusMeters: 100
                )
            }
        }

        let empty = height(PlacesListSheet(model: model))
        await addPlaces(0 ..< 2)
        let two = height(PlacesListSheet(model: model))
        await addPlaces(2 ..< 4)
        let four = height(PlacesListSheet(model: model))
        XCTAssertFalse(scrolls, "A list that fits shows every row with nothing to scroll")
        await addPlaces(4 ..< 30)
        let thirty = height(PlacesListSheet(model: model))
        await addPlaces(30 ..< 40)
        let forty = height(PlacesListSheet(model: model))
        XCTAssertTrue(scrolls)
        XCTAssertLessThan(empty, two)
        XCTAssertLessThan(two, four)
        XCTAssertLessThan(four, thirty)
        XCTAssertEqual(thirty, forty, "Past the maximum the list scrolls and the sheet stops growing")
        XCTAssertLessThan(forty, 480)

        func results(_ count: Int) -> AddPlaceSheet.Search {
            .found(
                (0 ..< count).map { index in
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: 40, longitude: -73)))
                    item.name = "Result \(index)"
                    return item
                }
            )
        }
        let idle = height(AddPlaceSheet(model: model))
        let three = height(AddPlaceSheet(model: model, search: results(3)))
        let twenty = height(AddPlaceSheet(model: model, search: results(20)))
        let fifty = height(AddPlaceSheet(model: model, search: results(50)))
        XCTAssertLessThan(idle, three)
        XCTAssertLessThan(three, twenty)
        XCTAssertEqual(twenty, fifty)
    }
}

extension LocationWindowModelTests {
    @MainActor
    func testANewerReloadReplacesTheOneInFlight() async throws {
        let directory = temporaryDirectoryURL()
        let now = noonToday()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { now })
        var samples: [LocationSample] = []
        for minutesAgo in stride(from: 60, through: 5, by: -10) {
            samples.append(
                LocationSample(
                    deviceID: "phone",
                    deviceName: "Rob's iPhone",
                    personName: "Rob",
                    isMe: true,
                    latitude: 40.7464,
                    longitude: -74.9445,
                    accuracyMeters: 20,
                    positionType: "Wifi",
                    timestamp: now.addingTimeInterval(-Double(minutesAgo) * 60)
                )
            )
        }
        _ = try await store.record(samples)
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let calls = Counter()
        let gate = AsyncGate()
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { _, _ in
                guard calls.increment() == 1 else { return "Second St" }
                await gate.wait()
                return "First St"
            },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) },
            clock: TestClock(start: now).wallClock
        )

        let first = Task { await model.reload() }
        await gate.waitUntilWaiting()
        await model.reload()
        XCTAssertEqual(model.lookups.values.map(\.address), ["Second St"])

        await gate.open()
        await first.value
        XCTAssertEqual(
            model.lookups.values.map(\.address),
            ["Second St"],
            "A reload that was replaced must not publish when it finally returns"
        )
    }
}

extension LocationWindowModelTests {
    @MainActor
    func testTicksReloadOnlyWhenTheStoreChanges() async throws {
        let directory = temporaryDirectoryURL()
        let now = Date()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"), now: { now })
        func fix(minutesAgo: Double) -> LocationSample {
            LocationSample(
                deviceID: "phone",
                deviceName: "Rob's iPhone",
                personName: "Rob",
                isMe: true,
                latitude: 40.7464,
                longitude: -74.9445,
                accuracyMeters: 20,
                positionType: "Wifi",
                timestamp: now.addingTimeInterval(-minutesAgo * 60)
            )
        }
        _ = try await store.record([fix(minutesAgo: 30), fix(minutesAgo: 20)])
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let clock = TestClock(start: now)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { _, _ in nil },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) },
            clock: clock.wallClock
        )
        model.startRefreshing()
        defer { model.stopRefreshing() }
        await model.settle()
        let shown = try XCTUnwrap(model.timeline?.range)

        // Only a reload re-reads `period`, so the published range is the
        // tell for whether one ran.
        model.period = .week
        clock.advance(by: 60)
        await model.settle()
        clock.advance(by: 60)
        await model.settle()
        XCTAssertEqual(model.timeline?.range, shown, "Ticks over an unchanged store must not reload")

        _ = try await store.record([fix(minutesAgo: 1)])
        await model.settle()
        XCTAssertEqual(model.timeline?.range, shown, "A change waits for the next tick")
        clock.advance(by: 60)
        await model.settle()
        XCTAssertNotEqual(model.timeline?.range, shown, "A new sample must trigger a reload")
        XCTAssertEqual(
            model.latest?.at.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(-60).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    @MainActor
    func testReopeningTheWindowReturnsToToday() {
        let directory = temporaryDirectoryURL()
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite")),
            venueLookup: noVenues,
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: false) }
        )
        model.step(by: -3)
        XCTAssertFalse(model.isToday)
        let dayBefore = model.selectedDay
        model.period = .week
        model.step(by: -1)
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: model.selectedDay, to: dayBefore).day,
            7,
            "a week steps a week"
        )
        model.setPeriod(.all)
        XCTAssertTrue(model.isToday, "all of it ends today")
        XCTAssertFalse(model.canStep)
        model.startRefreshing()
        XCTAssertTrue(model.isToday)
        model.stopRefreshing()
    }
}

extension LocationWindowModelTests {
    /// Decision 4: "Rename…" on a stop renames its place by id. It never
    /// moves the place to the stop's centre or resets how it was named
    /// (docs/solutions/ui-bugs/searched-place-address-shift.md).
    @MainActor
    func testRenamingAStopsPlaceKeepsItsCentreAndSource() async throws {
        let directory = temporaryDirectoryURL()
        let store = LocationHistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let searched = try await store.setPlace(
            name: "Office",
            latitude: 40.7340,
            longitude: -74.9869,
            radiusMeters: 150,
            source: NamedPlaceSource.person
        )
        let (storage, _) = storageInMemory()
        let session = ICloudSession(transport: ScriptedTransport(), storage: storage)
        let model = LocationWindowModel(
            store: store,
            venueLookup: VenueLookup { _, _, _ in [] },
            addressLoader: { _, _ in nil },
            session: { session },
            samplerStatus: { LocationSamplerStatus(isRunning: true) }
        )
        let visit = Visit(
            samples: [],
            latitude: 40.7345,
            longitude: -74.9869,
            arrival: Date(),
            lastObserved: Date(),
            ending: .ongoing,
            place: searched
        )

        model.sheet = .naming(visit)
        await model.name(visit, as: "Work", radiusMeters: 120)
        model.sheet = .naming(visit)
        await model.name(visit, as: "Work", radiusMeters: 90, kind: NamedPlaceKind.label)

        let places = try await store.places()
        XCTAssertEqual(places.count, 1, "A rename never adds a second place")
        XCTAssertEqual(places[0].id, searched.id)
        XCTAssertEqual(places[0].name, "Work")
        XCTAssertEqual(places[0].latitude, searched.latitude)
        XCTAssertEqual(places[0].longitude, searched.longitude)
        XCTAssertEqual(places[0].source, NamedPlaceSource.person)
        XCTAssertEqual(
            places[0].createdAt.timeIntervalSince1970,
            searched.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(places[0].radiusMeters, 90)
        XCTAssertEqual(places[0].kind, NamedPlaceKind.label)
        XCTAssertNil(model.placeError)
    }

    func testTheRadiusSliderStaysInsideWhatTheStoreAcceptsAndReachesTheCurrentRadius() {
        let bounds = LocationPolicy.PlaceRadius.bounds
        let usual = LocationPolicy.PlaceRadius.slider()
        XCTAssertTrue(bounds.contains(usual.lowerBound) && bounds.contains(usual.upperBound))
        XCTAssertTrue(usual.contains(LocationPolicy.PlaceRadius.sheetDefault))
        XCTAssertTrue(usual.contains(LocationPolicy.PlaceRadius.storefront))
        XCTAssertTrue(LocationPolicy.PlaceRadius.slider(including: 1000).contains(1000))
        XCTAssertTrue(LocationPolicy.PlaceRadius.slider(including: 10).contains(10))
    }
}
