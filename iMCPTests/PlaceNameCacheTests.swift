import XCTest

@testable import iMCP

final class PlaceNameCacheTests: XCTestCase {
    func testStoresAndReturnsValues() {
        let cache = PlaceNameCache(capacity: 2)
        cache.store("Brooklyn", for: "40.68,-73.94")
        XCTAssertEqual(cache.value(for: "40.68,-73.94"), "Brooklyn")
        XCTAssertNil(cache.value(for: "unknown"))
    }

    func testEvictsLeastRecentlyUsedAtCapacity() {
        let cache = PlaceNameCache(capacity: 2)
        cache.store("A", for: "a")
        cache.store("B", for: "b")
        cache.store("C", for: "c")

        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), "B")
        XCTAssertEqual(cache.value(for: "c"), "C")
    }

    func testReadRefreshesRecency() {
        let cache = PlaceNameCache(capacity: 2)
        cache.store("A", for: "a")
        cache.store("B", for: "b")
        XCTAssertEqual(cache.value(for: "a"), "A")
        cache.store("C", for: "c")

        XCTAssertEqual(cache.value(for: "a"), "A")
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), "C")
    }

    func testOverwriteDoesNotGrowCount() {
        let cache = PlaceNameCache(capacity: 2)
        cache.store("A", for: "a")
        cache.store("A2", for: "a")
        cache.store("B", for: "b")

        XCTAssertEqual(cache.value(for: "a"), "A2")
        XCTAssertEqual(cache.value(for: "b"), "B")
    }
}
