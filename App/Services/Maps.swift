import AppKit
import Foundation
import MapKit
import OSLog
import Ontology

private let log = Logger.service("maps")

private let defaultSearchRadius: CLLocationDistance = 5000
private let defaultSearchLimit: Int = 10
private let defaultMapImageSize: CGSize = CGSize(width: 1024, height: 1024)
private let minMapImageDimension = 128
private let maxMapImageDimension = 2048
private let geocodeDeadline: Duration = .seconds(10)
private let mapsDeadline: Duration = .seconds(30)

private let maxSearchRadius: CLLocationDistance = 100_000

extension MKPointOfInterestCategory {
    static let names = NamedCases<MKPointOfInterestCategory>([
        ("airport", .airport),
        ("restaurant", .restaurant),
        ("gas", .gasStation),
        ("parking", .parking),
        ("hotel", .hotel),
        ("hospital", .hospital),
        ("police", .police),
        ("fire", .fireStation),
        ("store", .store),
        ("museum", .museum),
        ("park", .park),
        ("school", .school),
        ("library", .library),
        ("theater", .theater),
        ("bank", .bank),
        ("atm", .atm),
        ("cafe", .cafe),
        ("pharmacy", .pharmacy),
        ("gym", .fitnessCenter),
        ("laundry", .laundry),
    ])
}

enum MapsMapStyle: String, CaseIterable {
    case standard, satellite, hybrid, mutedStandard

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        case .mutedStandard: return .mutedStandard
        }
    }
}

enum MapsTransportMode: String, CaseIterable {
    case automobile, walking, transit, cycling, any

    var transportType: MKDirectionsTransportType {
        switch self {
        case .automobile: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        case .cycling: return .cycling
        case .any: return .any
        }
    }
}

/// The routing failures a caller can act on differently. Everything else stays
/// behind the generic sanitized message, so this stays deliberately small: an
/// agent only needs to tell "this mode has no data here" apart from "something
/// went wrong".
enum MapsError: Swift.Error, ClientFacingError, Equatable {
    case noRoute(mode: String)
    case routingUnavailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noRoute(let mode) where mode == "any":
            return "Apple Maps found no route between these points by any mode of travel."
        case .noRoute(let mode):
            return
                "Apple Maps returned no \(mode) route between these points. Its \(mode) coverage is regional, so this means there is no route data here, not that the trip cannot be made."
        case .routingUnavailable:
            return "Apple Maps routing is temporarily unavailable. Retrying shortly may succeed."
        case .timedOut:
            return "Apple Maps did not answer in time. Retrying shortly may succeed."
        }
    }
}

/// MapKit reports "no cycling data in this region" with the same code it uses
/// for "no route exists" (`.directionsNotFound`), and nothing in the response
/// separates them. Both become `.noRoute`, whose message says so rather than
/// implying the trip is impossible. A placemark failure is a different problem
/// and is left alone.
func mapsRoutingError(from error: Swift.Error, mode: String) -> Swift.Error {
    guard let mapKitError = error as? MKError else { return error }
    switch mapKitError.code {
    case .directionsNotFound:
        return MapsError.noRoute(mode: mode)
    case .loadingThrottled, .serverFailure:
        return MapsError.routingUnavailable
    default:
        return error
    }
}

final class MapsService: Service {
    static let shared = MapsService()

    private init() {
        log.debug("Initializing maps service")
    }

    private static let query = ToolArgument.required(
        "query",
        description: "Search text, such as a place name, category, or address"
    )
    private static let point = ToolArgument.coordinate()
    private static let region = ToolArgument<MKCoordinateRegion?>(
        "region",
        Tool.inputSchema(
            [point, searchRadius],
            description: "Area to bias results toward. Results outside it are still possible."
        )
    ) { present in
        guard let present else { return nil }
        let region = try ArgumentValue.object(present, "region")
        let radius = try searchRadius(region)
        // These are full extents, so a radius is half of each.
        return MKCoordinateRegion(
            center: try point(region),
            latitudinalMeters: radius * 2,
            longitudinalMeters: radius * 2
        )
    }
    private static let searchRadius = ToolArgument.number(
        "radius",
        description: "Search radius in meters",
        default: defaultSearchRadius,
        in: 1 ... maxSearchRadius,
        documentsRange: false
    )

    private enum Endpoint {
        case address(String)
        case point(CLLocationCoordinate2D)
    }

    /// An address, or failing that a point.
    private static func endpoint(_ name: String, addressDescription: String, coordinatesDescription: String)
        -> ToolArgument<Endpoint>
    {
        ToolArgument(
            properties: [
                ("\(name)Address", .string(description: addressDescription)),
                ("\(name)Coordinates", Tool.inputSchema([point], description: coordinatesDescription)),
            ]
        ) { arguments in
            if let address = try ArgumentValue.optional(
                arguments,
                "\(name)Address",
                { try ArgumentValue.trimmedNonBlankString($0, $1) }
            ) {
                return .address(address)
            }
            guard let coordinates = try ArgumentValue.optional(arguments, "\(name)Coordinates", ArgumentValue.object)
            else {
                throw ToolInputError(
                    "\(name.prefix(1).uppercased() + name.dropFirst()) address or coordinates required"
                )
            }
            return .point(try point(coordinates))
        }
    }
    private static let origin = endpoint(
        "origin",
        addressDescription: "Origin as an address or place name. Takes precedence over originCoordinates.",
        coordinatesDescription: "Origin as an exact point, used when originAddress is omitted"
    )
    private static let destination = endpoint(
        "destination",
        addressDescription: "Destination as an address or place name. Takes precedence over destinationCoordinates.",
        coordinatesDescription: "Destination as an exact point, used when destinationAddress is omitted"
    )
    private static func transport(_ description: String) -> ToolArgument<MapsTransportMode> {
        .choice("transportType", description: description, among: NamedCases(), default: .automobile)
    }
    private static let directionsTransport = transport(
        "Mode of travel to route by; \"any\" lets Maps pick. Apple has no cycling data in many regions, so \"cycling\" errors there rather than returning a route; that means no data, not that the trip is unridable."
    )
    private static let etaTransport = transport(
        "Mode of travel to estimate for; \"any\" lets Maps pick. Apple has no cycling data in many regions, so \"cycling\" errors there rather than returning an estimate; that means no data, not that the trip is unridable. The estimate does not report which mode was used, so pass an explicit mode when the answer needs to name one."
    )
    private static let etaOrigin = ToolArgument.coordinate(latitude: "originLatitude", longitude: "originLongitude")
    private static let etaDestination = ToolArgument.coordinate(
        latitude: "destinationLatitude",
        longitude: "destinationLongitude"
    )

    private static let category = ToolArgument.requiredChoice(
        "category",
        description: "The single category of place to look for",
        among: MKPointOfInterestCategory.names
    )
    private static let exploreLimit = ToolArgument.integer(
        "limit",
        description: "Maximum results to return",
        default: defaultSearchLimit,
        in: 1 ... 50
    )

    private static let span = ToolArgument<MKCoordinateSpan>(
        properties: [
            ("latitudeDelta", .number(description: "Height of the visible area, in degrees of latitude")),
            ("longitudeDelta", .number(description: "Width of the visible area, in degrees of longitude")),
        ],
        required: ["latitudeDelta", "longitudeDelta"]
    ) { arguments in
        guard let latitudeDelta = arguments["latitudeDelta"]?.numberValue,
            let longitudeDelta = arguments["longitudeDelta"]?.numberValue,
            latitudeDelta > 0, latitudeDelta <= 180,
            longitudeDelta > 0, longitudeDelta <= 360
        else {
            throw ToolInputError(
                "latitudeDelta must be greater than 0 and at most 180; longitudeDelta greater than 0 and at most 360"
            )
        }
        return MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
    private static let width = ToolArgument.integer(
        "width",
        description: "Image width in pixels",
        default: Int(defaultMapImageSize.width),
        in: minMapImageDimension ... maxMapImageDimension
    )
    private static let height = ToolArgument.integer(
        "height",
        description: "Image height in pixels",
        default: Int(defaultMapImageSize.height),
        in: minMapImageDimension ... maxMapImageDimension
    )
    private static let mapType = ToolArgument.choice(
        "mapType",
        description: "Base map style to render",
        among: NamedCases<MapsMapStyle>(),
        default: .standard
    )
    private static let format = ToolArgument<ImageFormat?>.choice(
        "format",
        description: "Image encoding. Defaults to jpeg for satellite and hybrid maps, png otherwise.",
        among: NamedCases<ImageFormat>()
    )
    private static let pointsOfInterest = ToolArgument<MKPointOfInterestFilter>(
        "showPointsOfInterest",
        .oneOf([
            .boolean(description: "Show all (true) or no (false) POIs", default: false),
            .array(
                description: "Show only these categories of point of interest",
                // One `enum` instead of an `anyOf` of `const` subschemas: same
                // accepted values, a third of the bytes in every tools/list reply.
                items: .string(enum: MKPointOfInterestCategory.names.names.map { .string($0) }),
                minItems: 1
            ),
        ])
    ) { present in
        guard let present else { return .excludingAll }
        if case .bool(let showsAll) = present { return showsAll ? .includingAll : .excludingAll }
        guard case .array = present else {
            throw ToolInputError.wrongType("showPointsOfInterest", "true, false, or an array of categories")
        }
        let categories = try ArgumentValue.array(present, "showPointsOfInterest") {
            try ArgumentValue.choice($0, "category", among: MKPointOfInterestCategory.names)
        }
        return categories.isEmpty ? .excludingAll : .init(including: categories)
    }
    private static let showBuildings = ToolArgument.bool(
        "showBuildings",
        description: "Draw building shapes on the map",
        default: false
    )
    private static let address = ToolArgument.required(
        "address",
        description: "Address to look up; a partial address or place name also works"
    )

    var tools: [Tool] {
        Tool(
            name: "maps_search",
            description: "Search Apple Maps for places, addresses, and points of interest by text",
            arguments: [Self.query, Self.region],
            annotations: .init(
                title: "Search Places",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await withDeadline(mapsDeadline, throwing: MapsError.timedOut) {
                let searchRequest = MKLocalSearch.Request()
                searchRequest.naturalLanguageQuery = try Self.query(arguments)
                if let region = try Self.region(arguments) {
                    searchRequest.region = region
                }

                return try await MKLocalSearch(request: searchRequest).start().mapItems.map(Place.init)
            }
        }

        Tool(
            name: "maps_directions",
            description:
                "Return the first route between two places as an ordered list of turn-by-turn steps. Give each endpoint as an address or as coordinates.",
            arguments: [Self.origin, Self.destination, Self.directionsTransport],
            annotations: .init(
                title: "Get Directions",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await withDeadline(mapsDeadline, throwing: MapsError.timedOut) {
                let transportMode = try Self.directionsTransport(arguments)
                let originEndpoint = try Self.origin(arguments)
                let destinationEndpoint = try Self.destination(arguments)

                async let origin = self.mapItem(for: originEndpoint)
                async let destination = self.mapItem(for: destinationEndpoint)

                let directionsRequest = MKDirections.Request()
                directionsRequest.source = try await origin
                directionsRequest.destination = try await destination
                let requestedMode = transportMode.rawValue
                directionsRequest.transportType = transportMode.transportType

                do {
                    let response = try await MKDirections(request: directionsRequest).calculate()
                    guard !response.routes.isEmpty else { throw MapsError.noRoute(mode: requestedMode) }
                    return Trip(response)
                } catch {
                    throw mapsRoutingError(from: error, mode: requestedMode)
                }
            }
        }

        Tool(
            name: "maps_explore",
            description: "Find points of interest of one category within a radius of a coordinate",
            arguments: [Self.category, Self.point, Self.searchRadius, Self.exploreLimit],
            annotations: .init(
                title: "Find Nearby Points of Interest",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await withDeadline(mapsDeadline, throwing: MapsError.timedOut) {
                let category = try Self.category(arguments)
                let center = try Self.point(arguments)
                let radius = try Self.searchRadius(arguments)
                let limit = try Self.exploreLimit(arguments)

                let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
                request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category])

                return try await MKLocalSearch(request: request).start().mapItems.prefix(limit).map(Place.init)
            }
        }

        Tool(
            name: "maps_eta",
            description:
                "Return expected departure and arrival times for travel between two coordinates",
            arguments: [Self.etaOrigin, Self.etaDestination, Self.etaTransport],
            annotations: .init(
                title: "Get Estimated Travel Time",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await withDeadline(mapsDeadline, throwing: MapsError.timedOut) {
                let transportMode = try Self.etaTransport(arguments)
                let originPlacemark = MKPlacemark(coordinate: try Self.etaOrigin(arguments))
                let destPlacemark = MKPlacemark(coordinate: try Self.etaDestination(arguments))

                let originItem = MKMapItem(placemark: originPlacemark)
                let destinationItem = MKMapItem(placemark: destPlacemark)

                let directionsRequest = MKDirections.Request()
                directionsRequest.source = originItem
                directionsRequest.destination = destinationItem
                let requestedMode = transportMode.rawValue
                directionsRequest.transportType = transportMode.transportType

                do {
                    return Trip(try await MKDirections(request: directionsRequest).calculateETA())
                } catch {
                    throw mapsRoutingError(from: error, mode: requestedMode)
                }
            }
        }

        Tool(
            name: "maps_generate",
            description: "Render a static map image centered on a coordinate",
            arguments: [
                Self.point, Self.span, Self.width, Self.height, Self.mapType, Self.format, Self.pointsOfInterest,
                Self.showBuildings,
            ],
            annotations: .init(
                title: "Generate Map Image",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await withDeadline(mapsDeadline, throwing: MapsError.timedOut) {
                let center = try Self.point(arguments)
                let span = try Self.span(arguments)
                let width = try Self.width(arguments)
                let height = try Self.height(arguments)
                let mapStyle = try Self.mapType(arguments)
                let format =
                    try Self.format(arguments) ?? (mapStyle == .satellite || mapStyle == .hybrid ? .jpeg : .png)

                let options = MKMapSnapshotter.Options()
                options.region = MKCoordinateRegion(center: center, span: span)
                options.mapType = mapStyle.mapType
                options.size = CGSize(width: width, height: height)

                options.pointOfInterestFilter = try Self.pointsOfInterest(arguments)
                options.showsBuildings = try Self.showBuildings(arguments)

                let snapshot = try await MKMapSnapshotter(options: options).start()
                // MapKit renders at the display's scale, so the image can have
                // more pixels than requested. Redraw to exactly the requested size.
                let image = clampedImage(snapshot.image, maxDimension: max(width, height))
                guard let data = format.encode(image) else {
                    throw ToolFailure("Failed to encode the map image")
                }
                return Value.data(mimeType: format.mimeType, data)
            }
        }

        Tool(
            name: "maps_geocode",
            description:
                "Look up an address and return the coordinates and postal address of the best match. Gives up after \(geocodeDeadline.components.seconds) seconds.",
            arguments: [Self.address],
            annotations: .init(
                title: "Geocode Address",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let address = try Self.address(arguments)
            return try await withDeadline(geocodeDeadline, throwing: MapsError.timedOut) {
                try await self.geocodeAddress(address)
            }
        }

        Tool(
            name: "maps_reverse_geocode",
            description:
                "Return the place name and postal address nearest to a pair of coordinates. Gives up after \(geocodeDeadline.components.seconds) seconds.",
            arguments: [Self.point],
            annotations: .init(
                title: "Reverse Geocode Location",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let coordinate = try Self.point(arguments)
            return try await withDeadline(geocodeDeadline, throwing: MapsError.timedOut) {
                try await self.reverseGeocode(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
        }
    }

    private func geocodeAddress(_ address: String) async throws -> Value {
        guard let placemark = try await CLGeocoder().geocodeAddressString(address).first,
            let location = placemark.location
        else {
            throw ToolFailure("No location found for address")
        }
        return Self.placeValue(
            from: placemark,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async throws -> Value {
        guard let placemark = try await ReverseGeocoder.placemark(latitude: latitude, longitude: longitude) else {
            throw ToolFailure("No address found for location")
        }
        return Self.placeValue(from: placemark, latitude: latitude, longitude: longitude)
    }

    static func placeValue(
        from placemark: CLPlacemark,
        latitude: Double,
        longitude: Double
    ) -> Value {
        var result: [String: Value] = [
            "@context": .string("https://schema.org"),
            "@type": .string("Place"),
            "geo": .object([
                "@type": .string("GeoCoordinates"),
                "latitude": .double(latitude),
                "longitude": .double(longitude),
            ]),
        ]

        let parts = PlacemarkAddress(placemark)
        if let name = parts.name {
            result["name"] = .string(name)
        }

        var addressComponents: [String: Value] = [
            "@type": .string("PostalAddress")
        ]
        if let street = parts.street {
            addressComponents["streetAddress"] = .string(street)
        }
        if let locality = parts.locality {
            addressComponents["addressLocality"] = .string(locality)
        }
        if let administrativeArea = parts.administrativeArea {
            addressComponents["addressRegion"] = .string(administrativeArea)
        }
        if let postalCode = parts.postalCode {
            addressComponents["postalCode"] = .string(postalCode)
        }
        if let country = parts.country {
            addressComponents["addressCountry"] = .string(country)
        }
        if addressComponents.count > 1 {
            result["address"] = .object(addressComponents)
        }
        return .object(result)
    }

    private func mapItem(for endpoint: Endpoint) async throws -> MKMapItem {
        switch endpoint {
        case .point(let coordinate):
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        case .address(let address):
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = address

            let search = MKLocalSearch(request: searchRequest)
            let response = try await search.start()

            guard let mapItem = response.mapItems.first else {
                throw ToolFailure("Could not find location for address: \(address)")
            }

            return mapItem
        }
    }
}
