import Foundation

/// The time of day and a wait until a given moment, passed in so tests move
/// time instead of sleeping. Named apart from the standard library's `Clock`
/// protocol, which measures durations rather than dates.
struct WallClock: Sendable {
    var now: @Sendable () -> Date
    /// Returns at `deadline`, or throws once cancelled.
    var sleepUntil: @Sendable (Date) async throws -> Void

    /// The moment `duration` from now, fractions of a second included.
    func date(after duration: Duration) -> Date {
        let (seconds, attoseconds) = duration.components
        return now().addingTimeInterval(TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
    }

    static let live = WallClock(
        now: { Date() },
        sleepUntil: { deadline in try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
    )
}
