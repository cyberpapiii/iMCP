import CoreLocation
import Foundation
import OSLog

private let log = Logger.service("geocoding")

/// Coordinates to place text. Maps, Photos, and Location all ask the system
/// geocoder through `placemark`, and all read what it answers through
/// `PlacemarkAddress`, so a change of geocoder or of wording lands once.
enum ReverseGeocoder {
    /// Takes a coordinate, returns its address or nil. A failed lookup is
    /// not worth failing an answer over.
    typealias Loader = @Sendable (_ latitude: Double, _ longitude: Double) async -> String?

    enum Style: Sendable {
        /// "112 Harbor St, Brooklyn, NY": what the Location tools report.
        case full
        /// "112 Harbor St": the Location window, about one person's day,
        /// where the city and state are noise.
        case street
        /// "112 Harbor St, Brooklyn": a search result to choose from.
        case streetAndLocality
        /// "Brooklyn, NY, United States": the area a photo was taken in.
        case area
    }

    static func placemark(
        latitude: Double,
        longitude: Double,
        using geocoder: CLGeocoder = CLGeocoder()
    ) async throws -> CLPlacemark? {
        try await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)).first
    }

    static func appleMaps(_ style: Style) -> Loader {
        { latitude, longitude in
            do {
                return try await placemark(latitude: latitude, longitude: longitude)
                    .flatMap { PlacemarkAddress($0).text(style) }
            } catch {
                log.debug("Reverse geocoding a point failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// About ten metres, so the same building always gives the same key.
    static func buildingKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}

/// The parts of a placemark the app reports.
struct PlacemarkAddress: Equatable, Sendable {
    var name: String?
    /// The number and the street, "112 Harbor St".
    var street: String?
    var locality: String?
    var administrativeArea: String?
    var postalCode: String?
    var country: String?

    init(
        name: String? = nil,
        street: String? = nil,
        locality: String? = nil,
        administrativeArea: String? = nil,
        postalCode: String? = nil,
        country: String? = nil
    ) {
        self.name = name
        self.street = street
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.postalCode = postalCode
        self.country = country
    }

    init(_ placemark: CLPlacemark) {
        self.init(
            name: placemark.name,
            street: Self.street(number: placemark.subThoroughfare, street: placemark.thoroughfare),
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            postalCode: placemark.postalCode,
            country: placemark.country
        )
    }

    /// A placemark splits a street address into the number
    /// (`subThoroughfare`) and the street (`thoroughfare`).
    static func street(number: String?, street: String?) -> String? {
        let parts = [number, street].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The parts `style` names, joined with commas; an empty part is left
    /// out. The street styles fall back to the placemark's own name where
    /// there is no street.
    func text(_ style: ReverseGeocoder.Style) -> String? {
        let parts: [String?]
        switch style {
        case .full: parts = [street ?? name, locality, administrativeArea]
        case .street: parts = [street ?? name]
        case .streetAndLocality: parts = [street ?? name, locality]
        case .area: parts = [locality, administrativeArea, country]
        }
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: ", ")
    }
}
