import MapKit
import XCTest

@testable import iMCP

final class MapsServiceTests: XCTestCase {
    /// The category enum in the schema is read from this table, in this
    /// order; a reordering would change the cached tools/list payload.
    func testPointOfInterestTableKeepsItsSchemaOrder() {
        XCTAssertEqual(MKPointOfInterestCategory.names.names.first, "airport")
        XCTAssertEqual(MKPointOfInterestCategory.names.name(of: .gasStation), "gas")
    }

    func testMapsTimeoutIsClientFacing() {
        let error: Error = MapsError.timedOut
        XCTAssertTrue(error is ClientFacingError)
        XCTAssertFalse((error as? ClientFacingError)?.errorDescription?.isEmpty ?? true)
    }

    func testUnknownTransportModeIsRejectedNotRoutedByCar() throws {
        let transport = ToolArgument<MapsTransportMode>.choice("transportType", default: .automobile)
        XCTAssertEqual(try transport([:]), .automobile)
        XCTAssertThrowsError(try transport(["transportType": .string("bicycle")])) { error in
            XCTAssertTrue(error is ToolInputError)
        }
    }

    /// The cycling transport type tells callers that an error means "no data in
    /// this region", not "the trip is impossible". That guidance is worthless if
    /// the sanitizer collapses the error into the generic message.
    func testSanitizedMessagePassesThroughMapsRoutingErrors() {
        let cycling = sanitizedToolErrorMessage(for: MapsError.noRoute(mode: "cycling"))
        XCTAssertTrue(cycling.contains("cycling"))
        XCTAssertTrue(cycling.contains("no route data here"))

        let any = sanitizedToolErrorMessage(for: MapsError.noRoute(mode: "any"))
        XCTAssertTrue(any.contains("any mode of travel"))

        XCTAssertNotEqual(
            sanitizedToolErrorMessage(for: MapsError.routingUnavailable),
            sanitizedToolErrorMessage(for: NSError(domain: "x", code: 1))
        )
    }

    /// A placemark failure is a different problem than a missing route, so it
    /// must not be rewritten into one.
    func testRoutingErrorMapperLeavesUnrelatedMapKitErrorsAlone() {
        let placemark = MKError(.placemarkNotFound)
        let mapped = mapsRoutingError(from: placemark, mode: "cycling")
        XCTAssertNil(mapped as? MapsError)

        XCTAssertEqual(
            mapsRoutingError(from: MKError(.directionsNotFound), mode: "cycling") as? MapsError,
            MapsError.noRoute(mode: "cycling")
        )
        XCTAssertEqual(
            mapsRoutingError(from: MKError(.loadingThrottled), mode: "cycling") as? MapsError,
            MapsError.routingUnavailable
        )
    }
}
