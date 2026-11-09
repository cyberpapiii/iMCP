import Foundation

/// The Location numbers more than one place reads: the tools, their schemas
/// and descriptions, the sampler, the visit rules, the readiness gate, and
/// the window. Clustering rules that only `VisitInference` reads live in
/// `VisitInference.Rules`.
enum LocationPolicy {
    /// How often the sampler records. Long enough to bound phone battery and
    /// network cost, short enough that a visit of any consequence lands more
    /// than one sample.
    static let sampleInterval: TimeInterval = 10 * 60

    /// How old a fix can be before an answer calls it stale in words, so the
    /// caller does not have to do arithmetic on a timestamp.
    static let staleFixAge: TimeInterval = 30 * 60

    static func isStale(isOld: Bool, at timestamp: Date, now: Date) -> Bool {
        isOld || now.timeIntervalSince(timestamp) > staleFixAge
    }

    /// The sampler's interval in whole minutes, as every report states it.
    static var expectedIntervalMinutes: Int { Int(sampleInterval / 60) }

    /// A silence longer than this is a hole in the record, and a record this
    /// far behind means recording is behind. Three sampler intervals: one
    /// missed tick is ordinary, three is not.
    static let recordingOverdue: TimeInterval = 3 * sampleInterval

    /// The shortest stay that counts as a visit unless a caller asks otherwise.
    static let defaultDwell: TimeInterval = 10 * 60
    static var defaultDwellMinutes: Int { Int(defaultDwell / 60) }

    /// The most samples one read takes into memory.
    static let historyReadCap = 20_000

    /// How far back a question with no start date looks.
    enum Lookback {
        static let historyDays = 7
        static let timelineDays = 3
        /// "Seen N times" in the window counts stays over this many days.
        static let recurrenceDays = 30

        static func seconds(days: Int) -> TimeInterval { TimeInterval(days) * 24 * 60 * 60 }
    }

    enum PlaceRadius {
        static let `default`: Double = 150
        /// What the store accepts.
        static let bounds: ClosedRange<Double> = 10 ... 5000
        /// One storefront: a venue accepted as the name of a stop.
        static let storefront: Double = 60
        /// Where the window's sheets start.
        static let sheetDefault: Double = 100

        /// The window's slider: wide enough for a building or a block, and
        /// wider still when the place being edited already reaches past it,
        /// so opening a sheet never changes a radius on its own.
        static func slider(including radius: Double? = nil) -> ClosedRange<Double> {
            let usual: ClosedRange<Double> = 30 ... 400
            guard let radius, bounds.contains(radius) else { return usual }
            return min(usual.lowerBound, radius) ... max(usual.upperBound, radius)
        }
    }
}
