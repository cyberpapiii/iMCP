import Foundation
import XCTest

@testable import iMCP

/// Location answers go into a model's context, where every digit of a
/// coordinate costs the caller tokens and tells it nothing: no fix iMCP reads
/// is precise past six decimal places.
final class LocationRoundingTests: XCTestCase {
    func testCoordinatesKeepSixDecimalPlaces() {
        XCTAssertEqual(roundedDegrees(40.73385992982547), 40.73386, accuracy: 1e-9)
        XCTAssertEqual(roundedDegrees(-74.98694568114337), -74.986946, accuracy: 1e-9)
        XCTAssertEqual(roundedDegrees(40.5), 40.5, accuracy: 1e-9)
    }

    /// Six decimal places is about 11 cm at the equator. Anything coarser would
    /// move a reported position.
    func testCoordinateErrorStaysBelowTwelveCentimeters() {
        let metersPerDegree = 111_320.0
        for value in [40.73385992982547, -74.98694568114337, 0.0000005, 179.9999994] {
            let error = abs(roundedDegrees(value) - value) * metersPerDegree
            XCTAssertLessThan(error, 0.12)
        }
    }

    func testDistancesKeepOneDecimalPlace() {
        XCTAssertEqual(roundedMeters(9.635369796145278), 9.6, accuracy: 1e-9)
        XCTAssertEqual(roundedMeters(35.0), 35.0, accuracy: 1e-9)
        XCTAssertNil(roundedMeters(Double?.none))
        XCTAssertEqual(roundedMeters(Double?.some(12.34)), 12.3)
    }
}
