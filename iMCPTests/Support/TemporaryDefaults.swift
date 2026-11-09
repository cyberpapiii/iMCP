import Foundation
import XCTest

/// A UserDefaults suite of its own, so a test never reads or writes the app's
/// real preferences or another test's.
struct TemporaryDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(prefix: String = "iMCPTests") {
        suiteName = "\(prefix).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

extension XCTestCase {
    /// A fresh suite, removed when the current test ends.
    func makeTemporaryDefaults() -> UserDefaults {
        let temporary = TemporaryDefaults(prefix: String(describing: type(of: self)))
        addTeardownBlock { temporary.remove() }
        return temporary.defaults
    }
}
