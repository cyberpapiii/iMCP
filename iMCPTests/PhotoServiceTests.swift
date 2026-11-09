import Photos
import XCTest

@testable import iMCP

final class PhotoServiceTests: XCTestCase {
    func testPhotoImageCallbackUsesDegradedImage() {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let result = photoImageCallbackResult(
            image: image,
            info: [PHImageResultIsDegradedKey: true]
        )
        guard case .success = result else {
            return XCTFail("degraded callback must still yield an image")
        }
    }

    func testPhotoImageCallbackPropagatesErrorAndNil() {
        let error = NSError(domain: "PhotoService", code: 99)
        let failed = photoImageCallbackResult(image: nil, info: [PHImageErrorKey: error])
        guard case .failure(let received) = failed else {
            return XCTFail("expected PHImageErrorKey to fail")
        }
        XCTAssertEqual((received as NSError).domain, "PhotoService")
        XCTAssertEqual((received as NSError).code, 99)

        let missing = photoImageCallbackResult(image: nil, info: nil)
        guard case .failure(let missingError) = missing else {
            return XCTFail("expected nil image to fail")
        }
        XCTAssertEqual(sanitizedToolErrorMessage(for: missingError), "Failed to load image data for asset")
    }

    /// About 1 km granularity: nearby coordinates share one geocoding lookup.
    func testPlaceCacheKeyGroupsNearbyCoordinates() {
        let a = photoPlaceCacheKey(latitude: 40.6782, longitude: -73.9442)
        let b = photoPlaceCacheKey(latitude: 40.6799, longitude: -73.9401)
        XCTAssertEqual(a, b)
    }

    func testPlaceCacheKeySeparatesDistantCoordinates() {
        let brooklyn = photoPlaceCacheKey(latitude: 40.6782, longitude: -73.9442)
        let manhattan = photoPlaceCacheKey(latitude: 40.7831, longitude: -73.9712)
        XCTAssertNotEqual(brooklyn, manhattan)
    }

    /// Every other tool writes local-offset timestamps; Photos once wrote UTC.
    func testPhotoTimestampsCarryTheLocalOffset() {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        let modified = created.addingTimeInterval(3600)
        let timestamps = photoTimestamps(created: created, modified: modified)
        XCTAssertEqual(timestamps["createdAt"], .string(created.localISO8601))
        XCTAssertEqual(timestamps["modifiedAt"], .string(modified.localISO8601))
        XCTAssertTrue(photoTimestamps(created: nil, modified: nil).isEmpty)
    }

    /// `endDate: "2026-01-01"` ends at the next midnight, which belongs to
    /// January 2. Photos once included a photo taken at exactly that instant;
    /// every other date window leaves it out.
    func testTheEndOfASearchWindowIsExclusive() throws {
        let window = try ToolArgument.dateWindow()(["startDate": "2026-01-01", "endDate": "2026-01-01"])
        let start = try XCTUnwrap(window.start)
        let end = try XCTUnwrap(window.end)
        let matches = { (created: Date) in
            photoCreationDatePredicates(window).allSatisfy { $0.evaluate(with: ["creationDate": created]) }
        }

        XCTAssertTrue(matches(start))
        XCTAssertTrue(matches(end.addingTimeInterval(-1)))
        XCTAssertFalse(matches(end))
        XCTAssertFalse(matches(start.addingTimeInterval(-1)))
    }
}
