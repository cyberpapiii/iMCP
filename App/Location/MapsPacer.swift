import Foundation

/// Spaces out the Location window's requests to Apple Maps: routes, nearby
/// places and addresses. Maps refuses an app that asks more than about once
/// a second, and while it is refusing, every request (the map's own tiles
/// included) comes back empty. A long period has hundreds of stops and
/// steps to ask about, so they queue here one at a time, and after a refusal
/// the queue waits a minute before asking again.
actor MapsPacer {
    private let clock = ContinuousClock()
    private let spacing: Duration
    private let pauseAfterRefusal: Duration
    private var nextTurn: ContinuousClock.Instant

    init(spacing: Duration = .milliseconds(1200), pauseAfterRefusal: Duration = .seconds(60)) {
        self.spacing = spacing
        self.pauseAfterRefusal = pauseAfterRefusal
        nextTurn = clock.now
    }

    /// Waits for this request's turn. False when the wait was cancelled.
    func turn() async -> Bool {
        let slot = max(clock.now, nextTurn)
        nextTurn = slot + spacing
        do {
            try await clock.sleep(until: slot)
            return true
        } catch {
            return false
        }
    }

    /// Maps said no, or did not answer: hold the queue for a while.
    func refused() {
        nextTurn = max(nextTurn, clock.now + pauseAfterRefusal)
    }
}
