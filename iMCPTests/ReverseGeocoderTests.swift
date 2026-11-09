import MapKit
import XCTest

@testable import iMCP

/// Maps, Photos, and Location read placemarks through one formatter. Every
/// string here is wire output; each expectation is what that tool's own
/// formatter returned before they were merged.
final class ReverseGeocoderTests: XCTestCase {
    private func placemark(_ fields: [String: String]) -> CLPlacemark {
        MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 40.7, longitude: -73.9), addressDictionary: fields)
    }

    private var everything: CLPlacemark {
        placemark([
            "Name": "Brooklyn Bridge Park", "SubThoroughfare": "112", "Thoroughfare": "Harbor St",
            "City": "Brooklyn", "State": "NY", "ZIP": "11201", "Country": "United States",
        ])
    }

    func testStreetAddressJoinsNumberAndStreet() {
        XCTAssertEqual(PlacemarkAddress.street(number: "1", street: "Infinite Loop"), "1 Infinite Loop")
        XCTAssertEqual(PlacemarkAddress.street(number: nil, street: "Infinite Loop"), "Infinite Loop")
        XCTAssertEqual(PlacemarkAddress.street(number: "1", street: nil), "1")
        XCTAssertNil(PlacemarkAddress.street(number: nil, street: nil))
    }

    func testEachStyleWordsAFullPlacemarkAsItsToolDid() {
        XCTAssertEqual(PlacemarkAddress(everything).text(.full), "112 Harbor St, Brooklyn, NY")
        XCTAssertEqual(PlacemarkAddress(everything).text(.street), "112 Harbor St")
        XCTAssertEqual(PlacemarkAddress(everything).text(.streetAndLocality), "112 Harbor St, Brooklyn")
        XCTAssertEqual(PlacemarkAddress(everything).text(.area), "Brooklyn, NY, United States")
    }

    func testTheStreetStylesFallBackToTheNameAndSkipMissingParts() {
        let park = placemark(["Name": "Prospect Park", "State": "NY"])
        XCTAssertEqual(PlacemarkAddress(park).text(.full), "Prospect Park, NY")
        XCTAssertEqual(PlacemarkAddress(park).text(.streetAndLocality), "Prospect Park")
        XCTAssertEqual(PlacemarkAddress(park).text(.area), "NY")

        let numberOnly = placemark(["SubThoroughfare": "7", "Country": "Norway"])
        XCTAssertEqual(PlacemarkAddress(numberOnly).text(.street), "7")
        XCTAssertEqual(PlacemarkAddress(numberOnly).text(.area), "Norway")
    }

    /// A placemark reports an empty field as missing, so Photos, which never
    /// dropped empty parts, words it the same as before.
    func testAnEmptyFieldIsMissing() {
        let blank = placemark(["City": "", "State": "NY", "Country": ""])
        XCTAssertNil(blank.locality)
        XCTAssertEqual(PlacemarkAddress(blank).text(.area), "NY")
        XCTAssertNil(PlacemarkAddress(placemark([:])).text(.area))
        XCTAssertNil(PlacemarkAddress(placemark([:])).text(.full))
    }

    func testMapsPostalAddressKeepsItsFields() {
        XCTAssertEqual(
            MapsService.placeValue(from: everything, latitude: 40.7, longitude: -73.9),
            .object([
                "@context": "https://schema.org",
                "@type": "Place",
                "name": "Brooklyn Bridge Park",
                "geo": .object(["@type": "GeoCoordinates", "latitude": 40.7, "longitude": -73.9]),
                "address": .object([
                    "@type": "PostalAddress",
                    "streetAddress": "112 Harbor St",
                    "addressLocality": "Brooklyn",
                    "addressRegion": "NY",
                    "postalCode": "11201",
                    "addressCountry": "United States",
                ]),
            ])
        )
        XCTAssertEqual(
            MapsService.placeValue(from: placemark([:]), latitude: 1, longitude: 2),
            .object([
                "@context": "https://schema.org",
                "@type": "Place",
                "geo": .object(["@type": "GeoCoordinates", "latitude": 1.0, "longitude": 2.0]),
            ])
        )
    }
}
