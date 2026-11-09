import os

/// Lets exactly one caller through, from any queue, without awaiting: the
/// one that resumes a continuation several callbacks race to resume.
final class OnceFlag: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { alreadyClaimed in
            if alreadyClaimed { return false }
            alreadyClaimed = true
            return true
        }
    }
}
