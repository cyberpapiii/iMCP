import Foundation

/// What a failed `open` or `access` says about a protected file, by its
/// `errno`. Only `denied` is fixed by granting Full Disk Access.
enum FileAccessStatus: Equatable {
    case denied
    case missing
    /// A component of the path is a file, not a directory.
    case notADirectory
    case other

    init(errno code: Int32) {
        switch code {
        case EACCES, EPERM: self = .denied
        case ENOENT: self = .missing
        case ENOTDIR: self = .notADirectory
        default: self = .other
        }
    }
}

/// Detects whether this app holds the Full Disk Access grant, which gates the
/// databases the `BookmarkedDatabaseService`s and Browser History read.
enum FullDiskAccess {
    /// Files that only a process holding Full Disk Access can open. macOS 27
    /// no longer keeps a per-user TCC database, so the list carries several
    /// candidates and the first one that exists decides.
    static var probePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            BookmarkedDatabase.messages.path,
        ]
    }

    static var isGranted: Bool {
        isGranted(probing: probePaths) { path in
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return errno }
            close(fd)
            return 0
        }
    }

    /// `openError` returns 0 when the file opened and the `errno` otherwise.
    /// A missing file says nothing about the grant, so the next candidate is
    /// tried; any other failure is the denial.
    static func isGranted(probing paths: [String], openError: (String) -> Int32) -> Bool {
        for path in paths {
            let error = openError(path)
            if error == 0 { return true }
            switch FileAccessStatus(errno: error) {
            case .missing, .notADirectory: continue
            case .denied, .other: return false
            }
        }
        return false
    }
}
