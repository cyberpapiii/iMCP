import Foundation
import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? WireContract.appBundleIdentifier

    static let server = Logger(subsystem: subsystem, category: "server")

    static func service(_ name: String) -> Logger {
        Logger(subsystem: subsystem, category: "services.\(name)")
    }
}
