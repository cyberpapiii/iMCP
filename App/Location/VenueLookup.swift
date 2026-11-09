import CoreLocation
import Foundation
import MapKit

/// A business or landmark Apple Maps lists near a point. A candidate for
/// what a stay was, never a fact about it: a fix inside a dense block sits
/// within its own accuracy of several of these at once.
struct NearbyVenue: Sendable, Equatable, Codable {
    let name: String
    let category: String?
    let meters: Double
}

/// Looks up venues around a point and remembers the answer, because a
/// timeline asks about the same few spots day after day.
actor VenueLookup {
    typealias Loader =
        @Sendable (_ latitude: Double, _ longitude: Double, _ radius: Double) async throws -> [NearbyVenue]

    /// How far around the centre to look. Wider than a fix's accuracy so the
    /// runner-up test has something to compare against.
    static let searchRadius: CLLocationDistance = 120
    /// The cache starts over at this many spots rather than growing for as
    /// long as the app runs.
    static let cacheLimit = 500

    private let loader: Loader
    private var cache: [String: [NearbyVenue]] = [:]

    init(loader: Loader? = nil) {
        self.loader = loader ?? Self.mapKitLoader
    }

    /// The nearest venues, closest first, at most `limit`. Empty when Maps
    /// has nothing or is unreachable; a lookup failure must not fail a
    /// timeline.
    func venues(latitude: Double, longitude: Double, limit: Int = 3) async -> [NearbyVenue] {
        await lookUp(latitude: latitude, longitude: longitude, limit: limit) ?? []
    }

    /// The same, but nil when Maps could not be asked or did not answer, so
    /// a caller can tell "nothing here" from "ask again later".
    func lookUp(latitude: Double, longitude: Double, limit: Int = 3) async -> [NearbyVenue]? {
        if let cached = cached(latitude: latitude, longitude: longitude, limit: limit) { return cached }
        // A failed lookup is not an answer. Left uncached, the next request retries.
        guard let found = try? await loader(latitude, longitude, Self.searchRadius) else { return nil }
        let sorted = found.sorted { $0.meters < $1.meters }
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[ReverseGeocoder.buildingKey(latitude: latitude, longitude: longitude)] = sorted
        return Array(sorted.prefix(limit))
    }

    /// The venues already found at a spot, without asking Maps.
    func cached(latitude: Double, longitude: Double, limit: Int = 3) -> [NearbyVenue]? {
        cache[ReverseGeocoder.buildingKey(latitude: latitude, longitude: longitude)].map { Array($0.prefix(limit)) }
    }

    private static let mapKitLoader: Loader = { latitude, longitude, radius in
        let centre = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: radius)
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            // Maps' way of saying there is nothing here, which is an answer.
            return []
        }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            let coordinate = item.placemark.coordinate
            let distance = here.distance(
                from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            return NearbyVenue(name: name, category: categoryName(item.pointOfInterestCategory), meters: distance)
        }
    }

    /// "MKPOICategoryRestaurant" as "restaurant".
    static func categoryName(_ category: MKPointOfInterestCategory?) -> String? {
        guard let raw = category?.rawValue else { return nil }
        let trimmed = raw.hasPrefix("MKPOICategory") ? String(raw.dropFirst("MKPOICategory".count)) : raw
        return trimmed.isEmpty ? nil : trimmed.prefix(1).lowercased() + trimmed.dropFirst()
    }
}
