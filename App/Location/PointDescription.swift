import Foundation

/// What to call a stay or a fix. The tools and the window apply the same
/// rule (the user's name for the place, else the nearest address, else a
/// placeholder) in their own words.
enum StayName {
    enum Wording {
        /// Lower case, for the middle of an agent's sentence.
        case tool
        /// Sentence case, for a row title.
        case window
    }

    static func title(place: String?, address: String?, wording: Wording) -> String {
        if let place { return place }
        switch wording {
        case .tool: return address.map { "near \($0)" } ?? "unnamed location"
        case .window: return address.map { "Near \($0)" } ?? "Unnamed place"
        }
    }

    static func distance(_ meters: Double, from place: String) -> String {
        "\(wholeMeters(meters)) m from \(place)"
    }

    /// The tools' one-line label: a named place is called by its name.
    /// Anything else is "near" the address the geocoder returned, because
    /// that is all it is, with the nearest named place for context.
    static func label(
        place: String?,
        nearAddress: String?,
        nearPlace: String? = nil,
        nearPlaceMeters: Double? = nil
    ) -> String {
        var text = title(place: place, address: nearAddress, wording: .tool)
        if place == nil, let nearPlace, let nearPlaceMeters {
            text += ", " + distance(nearPlaceMeters, from: nearPlace)
        }
        return text
    }
}

func wholeMeters(_ meters: Double) -> Int {
    Int(meters.rounded())
}

/// What the tools say about one point: the named place it is in, or else
/// the closest named place, the street address, and the venues around it.
struct PointDescription: Sendable {
    let place: NamedPlace?
    let nearestPlace: NamedPlace?
    let nearestPlaceMeters: Double?
    /// Only looked up when there is no named place.
    let address: String?
    let venues: [NearbyVenue]?

    var label: String {
        StayName.label(
            place: place?.name,
            nearAddress: address,
            nearPlace: nearestPlace?.name,
            nearPlaceMeters: nearestPlaceMeters
        )
    }
}

/// Describes points for one tool request. Addresses are remembered by exact
/// coordinate for this request only: nothing a caller asked about outlives
/// the call, and a failed lookup is asked again.
struct PointDescriber {
    private let addresses: ReverseGeocoder.Loader
    private let venueLookup: VenueLookup
    private var known: [Coordinate: String] = [:]

    private struct Coordinate: Hashable {
        let latitude: Double
        let longitude: Double
    }

    init(addresses: @escaping ReverseGeocoder.Loader, venueLookup: VenueLookup) {
        self.addresses = addresses
        self.venueLookup = venueLookup
    }

    /// A point matched against `places` here.
    mutating func describe(latitude: Double, longitude: Double, places: [NamedPlace]) async -> PointDescription {
        let place = VisitInference.place(containing: latitude, longitude: longitude, in: places)
        let nearest =
            place == nil ? VisitInference.nearestPlace(to: latitude, longitude: longitude, in: places) : nil
        return await describe(
            latitude: latitude,
            longitude: longitude,
            place: place,
            nearestPlace: nearest?.place,
            nearestPlaceMeters: nearest?.meters
        )
    }

    /// A visit, whose places `VisitInference` already matched.
    mutating func describe(_ visit: Visit) async -> PointDescription {
        await describe(
            latitude: visit.latitude,
            longitude: visit.longitude,
            place: visit.place,
            nearestPlace: visit.nearestPlace,
            nearestPlaceMeters: visit.nearestPlaceMeters
        )
    }

    private mutating func describe(
        latitude: Double,
        longitude: Double,
        place: NamedPlace?,
        nearestPlace: NamedPlace?,
        nearestPlaceMeters: Double?
    ) async -> PointDescription {
        guard place == nil else {
            return PointDescription(
                place: place,
                nearestPlace: nil,
                nearestPlaceMeters: nil,
                address: nil,
                venues: nil
            )
        }
        return PointDescription(
            place: nil,
            nearestPlace: nearestPlace,
            nearestPlaceMeters: nearestPlaceMeters,
            address: await address(latitude: latitude, longitude: longitude),
            venues: await venueLookup.venues(latitude: latitude, longitude: longitude)
        )
    }

    mutating func address(latitude: Double, longitude: Double) async -> String? {
        let coordinate = Coordinate(latitude: latitude, longitude: longitude)
        if let cached = known[coordinate] { return cached }
        let address = await addresses(latitude, longitude)
        if let address { known[coordinate] = address }
        return address
    }
}
