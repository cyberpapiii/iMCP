#if DEBUG

    import Foundation

    /// Where earlier Debug builds kept the secrets a release build keeps in the
    /// Keychain. Read-and-delete only: nothing writes here any more, and the
    /// store exists so a Debug build can migrate files written by those
    /// earlier builds into the Keychain.
    ///
    /// Release builds never reach this.
    enum SecretFileStore {
        enum Read: Equatable {
            case missing
            case data(Data)
            /// The file exists and could not be read. Not the same as absence,
            /// and callers must not overwrite on it.
            case failed
        }

        static func directory() -> URL {
            WireContract.appSupportDirectory()
        }

        static func read(_ name: String) -> Read {
            let url = directory().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            guard let data = try? Data(contentsOf: url) else { return .failed }
            return .data(data)
        }

        @discardableResult
        static func delete(_ name: String) -> Bool {
            let url = directory().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            return (try? FileManager.default.removeItem(at: url)) != nil
        }
    }

#endif
