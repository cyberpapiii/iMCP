import Foundation
import OSLog

private let log = Logger.service("notes")
private let notesAutomationActivatedKey = "notesAutomationActivated"

/// NSAppleScript is not thread-safe, so every script runs on this one
/// serial queue. It must not be the main queue: a script can take seconds,
/// and the main queue also drives the menu bar and accepts connections.
private let notesScriptQueue = DispatchQueue(label: "me.mattt.iMCP.notes.applescript")

func notesAutomationIsActivated(status: OSStatus, previouslyActivated: Bool) -> Bool {
    switch status {
    case noErr:
        return true
    case OSStatus(procNotFound):
        // AEDeterminePermissionToAutomateTarget cannot inspect a bundle target
        // while the target app is not running. Preserve a previously proven
        // grant instead of turning that transient state into a false warning.
        return previouslyActivated
    default:
        return false
    }
}

/// Escapes a string for safe embedding inside a double-quoted AppleScript
/// string literal, preventing script injection from tool arguments.
func notesEscapeAppleScriptString(_ string: String) -> String {
    return
        string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

extension AutomationTarget {
    static let notes = AutomationTarget(name: "Notes", bundleIdentifier: "com.apple.Notes")
}

final class NotesService: Service {
    static let shared = NotesService()

    var permission: ServicePermission { .automation(.notes) }

    private enum NotesError: LocalizedError {
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return "Notes script failed: \(message)"
            }
        }
    }

    var isActivated: Bool {
        get async {
            let target = NSAppleEventDescriptor(bundleIdentifier: AutomationTarget.notes.bundleIdentifier)
            guard let targetDescriptor = target.aeDesc else { return false }
            return withExtendedLifetime(target) {
                let status = AEDeterminePermissionToAutomateTarget(
                    targetDescriptor,
                    typeWildCard,
                    typeWildCard,
                    false
                )
                return notesAutomationIsActivated(
                    status: status,
                    previouslyActivated: UserDefaults.standard.bool(
                        forKey: notesAutomationActivatedKey
                    )
                )
            }
        }
    }

    func activate() async throws {
        if await isActivated { return }
        log.debug("Activating notes service")
        // Running any script against Notes launches it if needed and shows the
        // one-time macOS Automation consent prompt.
        _ = try await runAppleScript("tell application \"Notes\" to return count of folders")
    }

    private static let query = ToolArgument.searchTerm(
        "Search term matched against note names (case-insensitive)"
    )
    private static let folder = ToolArgument.text(
        "folder",
        description: "Restrict the search to a single folder, by name"
    )
    private static let limit = ToolArgument.limit("Maximum notes to return", minimum: 1)
    private static let noteID = ToolArgument.required("id", description: "The note identifier")

    var tools: [Tool] {
        Tool(
            name: "notes_folders",
            description: "List the folders in the Notes app with their note counts",
            arguments: [],
            annotations: .init(
                title: "List Note Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let script = """
                tell application "Notes"
                    set output to {}
                    repeat with f in folders
                        set end of output to {name of f as text, (count of notes of f) as text}
                    end repeat
                    return output
                end tell
                """
            let descriptor = try await self.runAppleScript(script)
            var folders: [[String: Value]] = []
            for row in Self.rows(from: descriptor, columns: 2) {
                folders.append([
                    "name": .string(row[0]),
                    "noteCount": .int(Int(row[1]) ?? 0),
                ])
            }
            return Value.itemList(folders.map { .object($0) })
        }

        Tool(
            name: "notes_search",
            description:
                "Search notes by name, returning each note's identifier, name, and folder. "
                + "Omit the query to list notes. Note bodies come from notes_fetch.",
            arguments: [Self.query, Self.folder, Self.limit],
            annotations: .init(
                title: "Search Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit = try Self.limit(arguments)

            var source = "notes"
            if let folder = try Self.folder(arguments) {
                source = "notes of folder \"\(notesEscapeAppleScriptString(folder))\""
            }

            var matches = source
            if let query = try Self.query(arguments) {
                matches = "(\(source) whose name contains \"\(notesEscapeAppleScriptString(query))\")"
            }

            let script = """
                tell application "Notes"
                    set matchedNotes to \(matches)
                    set output to {}
                    set counter to 0
                    repeat with n in matchedNotes
                        set counter to counter + 1
                        if counter > \(limit) then exit repeat
                        set end of output to {id of n as text, name of n as text, name of container of n as text}
                    end repeat
                    return output
                end tell
                """
            let descriptor = try await self.runAppleScript(script)
            var notes: [[String: Value]] = []
            for row in Self.rows(from: descriptor, columns: 3) {
                notes.append([
                    "@id": .string(row[0]),
                    "name": .string(row[1]),
                    "folder": .string(row[2]),
                ])
            }
            return Value.itemList(notes.map { .object($0) })
        }

        Tool(
            name: "notes_fetch",
            description:
                "Fetch one note's plain-text body by the identifier notes_search returns",
            arguments: [Self.noteID],
            annotations: .init(
                title: "Fetch Note",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.noteID(arguments)

            let script = """
                tell application "Notes"
                    set n to note id "\(notesEscapeAppleScriptString(id))"
                    return {id of n as text, name of n as text, name of container of n as text, plaintext of n as text}
                end tell
                """
            let descriptor = try await self.runAppleScript(script)
            guard let row = Self.rows(from: NSAppleEventDescriptor.list(from: [descriptor]), columns: 4).first
            else {
                throw ToolFailure("Notes returned an unexpected result")
            }

            let result: Value = .object([
                "@id": .string(row[0]),
                "name": .string(row[1]),
                "folder": .string(row[2]),
                "body": .string(row[3]),
            ])
            return result
        }
    }

    private func runAppleScript(_ source: String) async throws -> NSAppleEventDescriptor {
        try await withCheckedThrowingContinuation { continuation in
            notesScriptQueue.async {
                continuation.resume(with: Result { try Self.executeAppleScript(source) })
            }
        }
    }

    private static func executeAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw NotesError.scriptFailed("could not compile script")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int
            if errorNumber == errAEEventNotPermitted {
                log.error("Automation access to Notes denied")
                UserDefaults.standard.set(false, forKey: notesAutomationActivatedKey)
                throw ServicePermission.automation(.notes).deniedError
            }
            let message =
                errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            log.error("Notes script failed: \(message)")
            throw NotesError.scriptFailed(message)
        }

        UserDefaults.standard.set(true, forKey: notesAutomationActivatedKey)
        return result
    }

    private static func rows(from descriptor: NSAppleEventDescriptor, columns: Int) -> [[String]] {
        var rows: [[String]] = []
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems > 0 else {
            return rows
        }

        for rowIndex in 1 ... descriptor.numberOfItems {
            guard let rowDescriptor = descriptor.atIndex(rowIndex),
                rowDescriptor.descriptorType == typeAEList,
                rowDescriptor.numberOfItems >= columns
            else { continue }

            var row: [String] = []
            for columnIndex in 1 ... columns {
                row.append(rowDescriptor.atIndex(columnIndex)?.stringValue ?? "")
            }
            rows.append(row)
        }

        return rows
    }
}

extension NSAppleEventDescriptor {
    fileprivate static func list(from items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (offset, item) in items.enumerated() {
            list.insert(item, at: offset + 1)
        }
        return list
    }
}
