import Foundation
import XCTest

@testable import iMCP

final class VenueLookupTests: XCTestCase {
    func testCategoryNamesDropThePrefix() {
        XCTAssertEqual(VenueLookup.categoryName(.restaurant), "restaurant")
        XCTAssertEqual(VenueLookup.categoryName(.nightlife), "nightlife")
        XCTAssertNil(VenueLookup.categoryName(nil))
    }

    func testLookupCachesPerSpotAndSwallowsFailures() async {
        let counter = Counter()
        let lookup = VenueLookup { _, _, _ in
            if counter.increment() == 1 { return [NearbyVenue(name: "A", category: nil, meters: 30)] }
            throw URLError(.notConnectedToInternet)
        }
        let first = await lookup.venues(latitude: 40.7, longitude: -73.9)
        let again = await lookup.venues(latitude: 40.70001, longitude: -73.90001)
        XCTAssertEqual(first.map(\.name), ["A"])
        XCTAssertEqual(again.map(\.name), ["A"])
        XCTAssertEqual(counter.value, 1)
        let failed = await lookup.venues(latitude: 41, longitude: -74)
        XCTAssertEqual(failed, [])
        _ = await lookup.venues(latitude: 41, longitude: -74)
        XCTAssertEqual(counter.value, 3, "a failed spot is asked again, not remembered as empty")
    }

    func testTheCacheStartsOverAtItsLimit() async {
        let counter = Counter()
        let lookup = VenueLookup { _, _, _ in
            counter.increment()
            return []
        }
        for step in 0 ... VenueLookup.cacheLimit {
            _ = await lookup.venues(latitude: Double(step) * 0.01, longitude: 0)
        }
        _ = await lookup.venues(latitude: 0, longitude: 0)
        XCTAssertEqual(counter.value, VenueLookup.cacheLimit + 2)
    }
}
