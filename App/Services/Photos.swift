import AppKit
import CoreLocation
import Foundation
import OSLog
import Photos

private let log = Logger.service("photos")

/// Reverse geocoding is rate-limited by the system, so lookups per search are
/// capped and results are cached by rounded coordinate (~1 km granularity).
private let maxGeocodeLookupsPerSearch = 5

/// Ceiling per reverse-geocoding lookup so slow network cannot stall a search;
/// on timeout the remaining lookups are skipped and the search proceeds.
private let geocodeTimeout: Duration = .seconds(2)

private struct GeocodeTimeoutError: Error {}

/// Images load from local storage only (`isNetworkAccessAllowed` is false),
/// so a request still unanswered after this long is not coming back.
private let imageLoadDeadline: Duration = .seconds(30)

private enum PhotoMediaFilter: String, CaseIterable { case image, video, any }

/// Cache key for reverse-geocoded place names, rounding coordinates to two
/// decimal places (~1 km) so nearby assets share one lookup.
func roundedPhotoCoordinate(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

func photoPlaceCacheKey(latitude: Double, longitude: Double) -> String {
    return String(format: "%.2f,%.2f", latitude, longitude)
}

/// The window's start is inclusive and its end exclusive, as in every date
/// window.
func photoCreationDatePredicates(_ window: DateWindow) -> [NSPredicate] {
    var predicates: [NSPredicate] = []
    if let start = window.start {
        predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
    }
    if let end = window.end {
        predicates.append(NSPredicate(format: "creationDate < %@", end as NSDate))
    }
    return predicates
}

func photoTimestamps(created: Date?, modified: Date?) -> [String: Value] {
    var timestamps: [String: Value] = [:]
    if let created { timestamps["createdAt"] = .string(created.localISO8601) }
    if let modified { timestamps["modifiedAt"] = .string(modified.localISO8601) }
    return timestamps
}

/// `highQualityFormat` typically delivers one callback. A degraded-only
/// result must still complete the request.
func photoImageCallbackResult(image: NSImage?, info: [AnyHashable: Any]?) -> Result<NSImage, any Error> {
    if let error = info?[PHImageErrorKey] as? NSError {
        return .failure(error)
    }
    guard let image else {
        return .failure(ToolFailure("Failed to load image data for asset"))
    }
    return .success(image)
}

/// Bounded LRU so a long-running app session cannot grow the cache without
/// limit as searches touch new ~1 km grid cells.
final class PlaceNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]
    private var recency: [String] = []  // least recently used first
    private let capacity: Int

    init(capacity: Int = 512) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func value(for key: String) -> String? {
        lock.withLock {
            guard let name = names[key] else { return nil }
            touch(key)
            return name
        }
    }

    func store(_ name: String, for key: String) {
        lock.withLock {
            names[key] = name
            touch(key)
            while names.count > capacity, let oldest = recency.first {
                recency.removeFirst()
                names.removeValue(forKey: oldest)
            }
        }
    }

    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

final class PhotoService: Service {
    static let shared = PhotoService()

    var permission: ServicePermission { .photos }

    var isActivated: Bool {
        get async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .authorized || status == .limited
        }
    }

    func activate() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            log.error("Photo library access not granted")
            throw permission.deniedError
        }
    }

    private static let window = ToolArgument.dateWindow(
        "Earliest creation date/time (ISO 8601). \(ArgumentDescription.localTimeAssumed)",
        "Latest creation date/time (ISO 8601). \(ArgumentDescription.localTimeAssumed)"
    )
    private static let limit = ToolArgument.limit("Maximum assets to return, newest first", minimum: 1, maximum: 100)
    private static let mediaType = ToolArgument.choice(
        "mediaType",
        description: "Filter by media type",
        among: NamedCases<PhotoMediaFilter>(),
        default: .any
    )
    private static let favorites = ToolArgument<Bool?>.bool(
        "favorites",
        description: "Keep only assets whose favorite flag equals this value"
    )
    private static let albumID = ToolArgument.text(
        "albumId",
        description: "Restrict the search to a single album, by its identifier (as returned by photos_albums)"
    )
    private static let assetID = ToolArgument.required(
        "id",
        description: "Local identifier of the asset to fetch"
    )
    private static let maxDimension = ToolArgument.integer(
        "maxDimension",
        description: ArgumentDescription.maxDimension,
        default: 2048,
        in: 1 ... 2048
    )

    var tools: [Tool] {
        Tool(
            name: "photos_search",
            description:
                "Search the photo library by date range, media type, favorite status, and album. Returns metadata only: dimensions, dates, coordinates, place name, and an identifier for photos_fetch_image.",
            arguments: [Self.window, Self.limit, Self.mediaType, Self.favorites, Self.albumID],
            annotations: .init(
                title: "Search Photos",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            var predicates = photoCreationDatePredicates(try Self.window(arguments))

            switch try Self.mediaType(arguments) {
            case .image:
                predicates.append(
                    NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                )
            case .video:
                predicates.append(
                    NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
                )
            case .any:
                break
            }

            if let favorites = try Self.favorites(arguments) {
                predicates.append(NSPredicate(format: "favorite == %@", NSNumber(value: favorites)))
            }

            let fetchOptions = PHFetchOptions()
            fetchOptions.fetchLimit = try Self.limit(arguments)
            fetchOptions.sortDescriptors = [
                NSSortDescriptor(key: "creationDate", ascending: false)
            ]
            if !predicates.isEmpty {
                fetchOptions.predicate = NSCompoundPredicate(
                    andPredicateWithSubpredicates: predicates
                )
            }

            let fetchResult: PHFetchResult<PHAsset>
            if let albumId = try Self.albumID(arguments) {
                guard let collection = Self.assetCollection(withIdentifier: albumId) else {
                    throw ToolFailure("Album not found with identifier: \(albumId)")
                }
                fetchResult = PHAsset.fetchAssets(in: collection, options: fetchOptions)
            } else {
                fetchResult = PHAsset.fetchAssets(with: fetchOptions)
            }

            var assets: [PHAsset] = []
            fetchResult.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }

            let placeNames = await Self.lookupPlaceNames(for: assets)

            var results: [Value] = []
            for asset in assets {
                var metadata = Self.metadata(for: asset)
                if let location = asset.location {
                    let key = photoPlaceCacheKey(
                        latitude: location.coordinate.latitude,
                        longitude: location.coordinate.longitude
                    )
                    if let placeName = placeNames[key] {
                        metadata["placeName"] = .string(placeName)
                    }
                }
                results.append(.object(metadata))
            }

            log.debug("Found \(results.count) matching photo assets")
            return results
        }

        Tool(
            name: "photos_albums",
            description:
                "List albums in the photo library, including user-created albums and built-in smart albums",
            arguments: [],
            annotations: .init(
                title: "List Photo Albums",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            var results: [Value] = []
            for type in [PHAssetCollectionType.album, .smartAlbum] {
                let collections = PHAssetCollection.fetchAssetCollections(
                    with: type,
                    subtype: .any,
                    options: nil
                )
                collections.enumerateObjects { collection, _, _ in
                    var album: [String: Value] = [
                        "@id": .string(collection.localIdentifier)
                    ]
                    if let title = collection.localizedTitle {
                        album["title"] = .string(title)
                    }
                    if collection.estimatedAssetCount != NSNotFound {
                        album["count"] = .int(collection.estimatedAssetCount)
                    }
                    results.append(.object(album))
                }
            }

            log.debug("Found \(results.count) photo albums")
            return results
        }

        Tool(
            name: "photos_fetch_image",
            description:
                "Fetch the image data for one photo library asset, by the identifier photos_search returns",
            arguments: [Self.assetID, Self.maxDimension],
            annotations: .init(
                title: "Fetch Photo",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let identifier = try Self.assetID(arguments)
            let maxDimension = try Self.maxDimension(arguments)

            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            )
            guard let asset = fetchResult.firstObject else {
                throw ToolFailure("Asset not found with identifier: \(identifier)")
            }

            return try await self.fetchImageValue(for: asset, maxDimension: maxDimension)
        }
    }

    private func fetchImageValue(for asset: PHAsset, maxDimension: Int) async throws -> Value {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .exact

        let targetSize = CGSize(width: maxDimension, height: maxDimension)

        let imageManager = PHImageManager.default()
        let requestID = OSAllocatedUnfairLock(initialState: PHInvalidImageRequestID)
        let jpegData: Data = try await withDeadline(
            imageLoadDeadline,
            throwing: ToolFailure("Loading the photo timed out after \(imageLoadDeadline.components.seconds) seconds"),
            onTimeout: { imageManager.cancelImageRequest(requestID.withLock { $0 }) }
        ) { report in
            let id = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                report(
                    photoImageCallbackResult(image: image, info: info).flatMap { image -> Result<Data, any Error> in
                        guard let data = ImageFormat.jpeg.encode(image) else {
                            return .failure(ToolFailure("Failed to encode scaled image data"))
                        }
                        return .success(data)
                    }
                )
            }
            requestID.withLock { $0 = id }
        }
        return .data(mimeType: ImageFormat.jpeg.mimeType, jpegData)
    }

    private static let placeNameCache = PlaceNameCache()

    /// Smart-album identifiers may not resolve via
    /// `fetchAssetCollections(withLocalIdentifiers:)`, so fall back to
    /// enumerating smart albums before reporting the album missing.
    private static func assetCollection(withIdentifier identifier: String) -> PHAssetCollection? {
        let direct = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        )
        if let collection = direct.firstObject {
            return collection
        }

        var match: PHAssetCollection?
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        smartAlbums.enumerateObjects { collection, _, stop in
            if collection.localIdentifier == identifier {
                match = collection
                stop.pointee = true
            }
        }
        return match
    }

    /// Best-effort: lookups are capped per search, and a geocoding error
    /// (likely rate limiting) stops further lookups without failing the search.
    private static func lookupPlaceNames(for assets: [PHAsset]) async -> [String: String] {
        var names: [String: String] = [:]
        var pending: [(key: String, location: CLLocation)] = []
        var seenKeys: Set<String> = []

        for asset in assets {
            guard let location = asset.location else { continue }
            let key = photoPlaceCacheKey(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            guard seenKeys.insert(key).inserted else { continue }
            if let cached = placeNameCache.value(for: key) {
                names[key] = cached
            } else {
                let rounded = CLLocation(
                    latitude: roundedPhotoCoordinate(location.coordinate.latitude),
                    longitude: roundedPhotoCoordinate(location.coordinate.longitude)
                )
                pending.append((key, rounded))
            }
        }

        let geocoder = CLGeocoder()
        for entry in pending.prefix(maxGeocodeLookupsPerSearch) {
            do {
                guard
                    let name = try await Self.reverseGeocodePlaceName(
                        for: entry.location,
                        using: geocoder
                    )
                else { continue }
                names[entry.key] = name
                placeNameCache.store(name, for: entry.key)
            } catch let error as CLError
                where error.code == .geocodeFoundNoResult
                || error.code == .geocodeFoundPartialResult
            {
                // A coordinate with no resolvable place (ocean, remote area)
                // should not suppress lookups for the remaining assets.
                continue
            } catch {
                // Network, timeout, or rate-limit class errors: cancel any
                // in-flight request and stop the batch, keeping results.
                geocoder.cancelGeocode()
                log.debug("Reverse geocoding stopped: \(error.localizedDescription)")
                break
            }
        }

        return names
    }

    private static func reverseGeocodePlaceName(
        for location: CLLocation,
        using geocoder: CLGeocoder
    ) async throws -> String? {
        try await withDeadline(geocodeTimeout, throwing: GeocodeTimeoutError()) {
            try await ReverseGeocoder.placemark(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                using: geocoder
            )
            .flatMap { PlacemarkAddress($0).text(.area) }
        }
    }

    private static func metadata(for asset: PHAsset) -> [String: Value] {
        var metadata: [String: Value] = [
            "@id": .string(asset.localIdentifier),
            "mediaType": .string(Self.mediaTypeName(for: asset.mediaType)),
            "width": .int(asset.pixelWidth),
            "height": .int(asset.pixelHeight),
            "isFavorite": .bool(asset.isFavorite),
        ]

        metadata.merge(photoTimestamps(created: asset.creationDate, modified: asset.modificationDate)) { $1 }

        if asset.mediaSubtypes.contains(.photoScreenshot) {
            metadata["isScreenshot"] = .bool(true)
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            metadata["isLivePhoto"] = .bool(true)
        }
        if asset.mediaSubtypes.contains(.photoPanorama) {
            metadata["isPanorama"] = .bool(true)
        }

        if asset.mediaType == .video {
            metadata["duration"] = .double(asset.duration)
        }

        if let location = asset.location {
            metadata["latitude"] = .double(roundedPhotoCoordinate(location.coordinate.latitude))
            metadata["longitude"] = .double(roundedPhotoCoordinate(location.coordinate.longitude))
        }

        return metadata
    }

    private static func mediaTypeName(for mediaType: PHAssetMediaType) -> String {
        switch mediaType {
        case .image:
            return "image"
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
}
