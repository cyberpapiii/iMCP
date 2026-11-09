import Foundation

/// The user's own track over one range, read the same way by
/// `location_timeline`, `location_now`, and the Location window: the
/// signed-in user's samples when there are any (everyone's otherwise), on the
/// one device that was carried, without Find My People rows.
struct LocationTrack: Sendable {
    /// The subject's samples, every device.
    let samples: [LocationSample]
    let timeline: DeviceTimeline

    var person: String? { samples.max(by: { $0.timestamp < $1.timestamp })?.personName }

    var deviceName: String? { timeline.deviceName.isEmpty ? nil : timeline.deviceName }

    var deviceSamples: [LocationSample] { samples.filter { $0.deviceID == timeline.deviceID } }

    static func subject(of samples: [LocationSample]) -> [LocationSample] {
        let mine = samples.filter(\.isMe)
        return mine.isEmpty ? samples : mine
    }

    static func read(
        from store: LocationHistoryStore,
        range: Range<Date>,
        now: Date,
        places: [NamedPlace],
        rules: VisitInference.Rules = VisitInference.Rules(),
        fallbackDevice: String? = nil
    ) async throws -> LocationTrack {
        let samples = try await store.samples(
            person: nil,
            device: nil,
            from: range.lowerBound,
            to: range.upperBound,
            limit: LocationPolicy.historyReadCap,
            includePeople: false
        )
        return LocationTrack(
            samples: samples,
            range: range,
            now: now,
            places: places,
            rules: rules,
            fallbackDevice: fallbackDevice
        )
    }

    /// One device, not all of them: a Mac sitting at home and a phone out in
    /// the world would otherwise interleave into a track that teleports. The
    /// most-moved device is the one that was carried.
    init(
        samples: [LocationSample],
        range: Range<Date>,
        now: Date,
        places: [NamedPlace],
        rules: VisitInference.Rules = VisitInference.Rules(),
        fallbackDevice: String? = nil
    ) {
        let subject = Self.subject(of: samples)
        self.samples = subject
        timeline = VisitInference.timeline(
            deviceID: VisitInference.mostMovedDevice(in: subject) ?? fallbackDevice ?? "",
            samples: subject,
            range: range,
            now: now,
            places: places,
            rules: rules
        )
    }
}
