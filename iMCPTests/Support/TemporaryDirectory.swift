import Foundation
import XCTest

/// A unique path under the system temporary directory.
enum TemporaryDirectory {
    static func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

extension XCTestCase {
    /// A unique directory path that does not exist yet, removed when the
    /// current test ends. For code that creates its own directory.
    func temporaryDirectoryURL() -> URL {
        let url = TemporaryDirectory.url()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A new, empty directory, removed when the current test ends.
    func makeTemporaryDirectory() throws -> URL {
        let url = temporaryDirectoryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
