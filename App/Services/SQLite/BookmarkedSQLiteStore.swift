import AppKit
import OSLog
import UniformTypeIdentifiers

/// One database a service reads with Full Disk Access or, failing that,
/// through a bookmark the user granted by picking the file once. Every name
/// the alert and the picker show is derived from `path`.
struct BookmarkedDatabase {
    enum Selection {
        case file
        /// The folder that holds the file.
        case directory
    }

    let path: String
    /// A persisted UserDefaults key; it must never change.
    let bookmarkKey: String
    let selection: Selection
    /// "Call History", as the alert title and picker name it.
    let displayName: String
    /// What reading it is for: "call history" in "To read your call history".
    let purpose: String

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    var expectedName: String {
        switch selection {
        case .file: fileName
        case .directory: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        }
    }

    fileprivate var resourceName: String { "the \(displayName) database" }

    fileprivate var selectionNoun: String {
        switch selection {
        case .file: "file"
        case .directory: "folder"
        }
    }

    /// What the picker asks for, as the tool errors name it: "the
    /// Notifications database folder".
    var pickerTarget: String { "\(resourceName) \(selectionNoun)" }

    fileprivate var alertTitle: String { "\(displayName) Database Access Required" }

    fileprivate var alertInformativeText: String {
        """
        To read your \(purpose), we need to open your \(displayName) database \(selectionNoun).

        In the next screen, please select the \(selectionNoun) `\(expectedName)` and click "Grant Access".
        """
    }

    fileprivate var pickerMessage: String {
        "Please select the \(displayName) database \(selectionNoun) (\(expectedName))"
    }

    fileprivate func databasePath(from url: URL) -> String {
        switch selection {
        case .file: url.path
        case .directory: url.appendingPathComponent(fileName).path
        }
    }
}

protocol BookmarkedDatabaseService: Service {
    var store: BookmarkedSQLiteStore { get }
}

extension BookmarkedDatabaseService {
    var permission: ServicePermission { .fullDiskAccess(hasPicker: true) }

    var isActivated: Bool {
        get async { store.isAccessible }
    }

    /// Shows the alert and the file picker when neither Full Disk Access nor
    /// a stored bookmark reaches the database. Never call it from a tool.
    func activate() async throws {
        try await store.activate()
    }
}

final class BookmarkedSQLiteStore: NSObject, NSOpenSavePanelDelegate {
    /// What a tool call can hit when the database is out of reach.
    enum AccessError: ClientFacingError {
        /// `picking` names what the picker asks for: "the Messages database file".
        case noBookmarkFound(picking: String)
        case securityScopeAccessFailed
        case bookmarkWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBookmarkFound(let picked):
                return "iMCP cannot read this database. \(ServicePermission.fullDiskAccessGrantInstruction) "
                    + ServicePermission.pickerHint(choosing: picked)
            case .securityScopeAccessFailed:
                return "Failed to access security-scoped resource"
            case .bookmarkWriteFailed(let resourceName):
                return "Failed to store security-scoped bookmark for \(resourceName)"
            }
        }
    }

    /// Thrown only while the user is choosing the file from the menu toggle,
    /// never from a tool, so it is not client-facing.
    enum SelectionError: LocalizedError {
        case userDeclinedAccess(String)
        case invalidSelection(String)
        case fileNotReadable

        var errorDescription: String? {
            switch self {
            case .userDeclinedAccess(let resourceName):
                return "User declined to grant access to \(resourceName)"
            case .invalidSelection(let resourceName):
                return "\(resourceName) access denied or invalid file selected"
            case .fileNotReadable:
                return "Selected database file is not readable"
            }
        }
    }

    let database: BookmarkedDatabase
    let log: Logger
    /// Where the bookmark is kept.
    private let defaults: UserDefaults

    init(_ database: BookmarkedDatabase, log: Logger, defaults: UserDefaults = .standard) {
        self.database = database
        self.log = log
        self.defaults = defaults
    }

    var canAccessDefaultPath: Bool {
        FileManager.default.isReadableFile(atPath: database.path)
    }

    var isAccessible: Bool {
        canAccessDefaultPath || canAccessUsingBookmark
    }

    var canAccessUsingBookmark: Bool {
        do {
            let url = try resolveBookmarkURL()
            return try withSecurityScopedAccess(url) { url in
                FileManager.default.isReadableFile(atPath: database.databasePath(from: url))
            }
        } catch AccessError.noBookmarkFound {
            return false
        } catch {
            log.error("Error accessing database with bookmark: \(error.localizedDescription)")
            return false
        }
    }

    func activate() async throws {
        if canAccessDefaultPath {
            log.debug("Successfully activated using default database path")
            return
        }

        if canAccessUsingBookmark {
            log.debug("Successfully activated using stored bookmark")
            return
        }

        log.debug("Opening file picker for manual database selection")
        guard await showDatabaseAccessAlert() else {
            throw SelectionError.userDeclinedAccess(database.resourceName)
        }

        let selectedURL = try await showPicker()

        guard FileManager.default.isReadableFile(atPath: database.databasePath(from: selectedURL)) else {
            throw SelectionError.fileNotReadable
        }

        try storeBookmark(for: selectedURL)
        log.debug("Successfully created and stored bookmark")
    }

    /// Runs `body` with a readable path to the database. Through a bookmark,
    /// the security scope stays open until `body` returns, because SQLite
    /// opens the `-wal`/`-shm` siblings lazily, at query time.
    func withAccess<T>(_ body: (String) throws -> T) throws -> T {
        if canAccessDefaultPath {
            return try body(database.path)
        }
        return try withSecurityScopedAccess(try resolveBookmarkURL()) { url in
            try body(database.databasePath(from: url))
        }
    }

    func withConnection<T>(
        mode: ReadOnlySQLite.Mode = .readOnly,
        _ body: (ReadOnlySQLite) throws -> T
    ) throws -> T {
        try withAccess { path in try body(try ReadOnlySQLite(path: path, mode: mode)) }
    }

    private func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = defaults.data(forKey: database.bookmarkKey) else {
            throw AccessError.noBookmarkFound(picking: database.pickerTarget)
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            log.debug("Refreshing stale database bookmark")
            try withSecurityScopedAccess(url) { url in
                try storeBookmark(for: url)
            }
        }

        return url
    }

    private func withSecurityScopedAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        guard url.startAccessingSecurityScopedResource() else {
            log.error("Failed to start accessing security-scoped resource")
            throw AccessError.securityScopeAccessFailed
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation(url)
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        switch database.selection {
        case .file:
            return url.lastPathComponent == database.expectedName
        case .directory:
            // Name-only: sandbox denies FileManager stats on this container
            // until access is granted, which would grey out the whole panel.
            return url.hasDirectoryPath && url.lastPathComponent == database.expectedName
        }
    }

    @MainActor
    private func showDatabaseAccessAlert() async -> Bool {
        let alert = NSAlert()
        alert.messageText = database.alertTitle
        alert.informativeText = database.alertInformativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        // iMCP lives in the menu bar and is rarely the active app. Without
        // this, the alert can open behind other windows, so the click on the
        // toggle appears to do nothing.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showPicker() async throws -> URL {
        let choosingDirectory = database.selection == .directory

        var directoryURL = URL(fileURLWithPath: database.path).deletingLastPathComponent()
        if choosingDirectory {
            directoryURL.deleteLastPathComponent()
        }

        let openPanel = NSOpenPanel()
        openPanel.delegate = self
        openPanel.message = database.pickerMessage
        openPanel.prompt = "Grant Access"
        openPanel.allowedContentTypes = [UTType.item]
        openPanel.directoryURL = directoryURL
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = choosingDirectory
        openPanel.canChooseFiles = !choosingDirectory
        openPanel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)

        guard openPanel.runModal() == .OK,
            let url = openPanel.url,
            url.lastPathComponent == database.expectedName
        else {
            throw SelectionError.invalidSelection(database.resourceName)
        }

        return url
    }

    private func storeBookmark(for url: URL) throws {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .securityScopeAllowOnlyReadAccess,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: database.bookmarkKey)
        } catch {
            log.error("Failed to create bookmark: \(error.localizedDescription)")
            throw AccessError.bookmarkWriteFailed(database.resourceName)
        }
    }
}
