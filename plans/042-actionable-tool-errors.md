# Plan 042: Make tool failures say what to do, and stop tool calls opening modal dialogs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Controllers/ToolErrorResponse.swift App/Controllers/ServerNetworkManager.swift App/Controllers/ICloudSession.swift App/Services/BookmarkedSQLiteStore.swift App/Services/Messages.swift App/Services/CallHistory.swift App/Services/ScreenTime.swift App/Services/Capture.swift App/Services/Photos.swift App/Services/Maps.swift App/Services/Shortcuts.swift App/Services/Contacts.swift App/Services/Calendar.swift App/Services/Reminders.swift App/Services/Weather.swift App/Services/Notes.swift App/Services/Location/LocationSampler.swift App/Views/LocationWindow.swift App/Views/SettingsView.swift iMCPTests/ToolErrorSanitizationTests.swift iMCPTests/CallToolDispatchTests.swift iMCPTests/AppModelTests.swift iMCPTests/PhotoServiceTests.swift`
> Plans 038, 039 and 041 edit other lines of the same service files, so line
> numbers below may have shifted. A shifted line number is NOT a stop: find
> each site with the `git grep` command given in the step. It IS a stop if the
> quoted code itself no longer exists in the shape shown.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — many small mechanical edits across 9 service files; one
  behaviour change (tool calls no longer open the database-access dialog)
- **Depends on**: plans/037-isolate-tests-from-real-state.md
- **Category**: bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

iMCP hides every tool error from the MCP client unless its type conforms to
`ClientFacingError`. That is correct for errors that carry paths or SQL, but
the most common failures are permission denials, and those are thrown as
`NSError`. So a client that calls `contacts_search` without Contacts access
gets "Tool execution failed. See iMCP logs for details." and cannot tell the
user what to fix. Worse, five tool handlers call a function that opens a modal
alert and a file picker with no timeout: a remote client can make a dialog
appear on the Mac and the call hangs until someone clicks. After this plan,
permission failures name the System Settings pane to open, no tool call opens
a dialog, and about 50 five-line `NSError` throws become one-line throws of
one small error type.

## Current state

All excerpts are from commit `8165d29`.

### The trust boundary

`App/Controllers/ToolErrorResponse.swift` is the whole file that decides what
reaches a client:

```swift
// App/Controllers/ToolErrorResponse.swift:6-23
protocol ClientFacingError: LocalizedError {}

extension FetchPolicy.Error: ClientFacingError {}
extension NotificationFetchError: ClientFacingError {}
extension BrowserHistoryService.BrowserHistoryError: ClientFacingError {}
extension BookmarkedSQLiteStore.AccessError: ClientFacingError {}
...
func sanitizedToolErrorMessage(for error: Error) -> String {
    if let clientFacing = error as? ClientFacingError {
        return clientFacing.errorDescription
            ?? "Tool execution failed. See iMCP logs for details."
    }
    return "Tool execution failed. See iMCP logs for details."
}
```

```swift
// App/Controllers/ToolErrorResponse.swift:30-38
struct ToolInputError: ClientFacingError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
```

Current conformers (15): the four extensions above, `ToolInputError`, and
`FindMyError`, `FindMyPeopleBootstrapError`, `FindMyPeopleToolError`,
`FindMyPeopleLifecycleError`, `ICloudAuthError`, `ICloudHTTPError`,
`LocalStorageKeyStorageError`, `LocalStoragePeopleError`,
`LocationHistoryError`, `MapsError` (all under `App/Services/`).

Failures that are already actionable and need NO change: service switched off
("Utilities is off. Turn it on in the iMCP menu bar."), not signed in to
iCloud and expired iCloud session (`FindMyError.notSignedIn`,
`.sessionInvalidated`, `App/Services/Location/FindMyClient.swift:83-86`),
browser history without Full Disk Access (`BrowserHistoryError`).

Failures that are NOT client-facing today, and what they throw:

| Failure | Site | Thrown today |
|---|---|---|
| Contacts denied | `App/Services/Contacts.swift:102-141` | 4 × `NSError` |
| Calendar denied | `App/Services/Calendar.swift:116-125` | `NSError` |
| Reminders denied | `App/Services/Reminders.swift:16-25` | `NSError` |
| Photos denied | `App/Services/Photos.swift:102-141` | 4 × `NSError` |
| Camera / Microphone denied | `App/Services/Capture.swift:162-196` | 3 × `NSError` |
| Screen recording denied | `App/Services/Capture.swift:198-207` | `NSError` |
| Notes Automation denied | `App/Services/Notes.swift:259` | private `NotesError.automationDenied` (good text, never reaches the client) |
| Database unreadable (no Full Disk Access, no bookmark) | `App/Services/BookmarkedSQLiteStore.swift:21-22` | client-facing, but the text is "No stored bookmark found for database access" |

The shape repeated about 50 times (domain and code are never read, with the
two exceptions listed under "Tests that read domain/code" and Shortcuts below):

```swift
// App/Services/Calendar.swift:116-125
    func activate() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        guard try await eventStore.requestFullAccessToEvents() else {
            throw NSError(
                domain: "CalendarService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Calendar access denied"]
            )
        }
    }
```

`NSError(` counts per file: Capture 22, Photos 8, Maps 8, Shortcuts 7,
Contacts 4, BrowserHistory 3, Reminders 2, Calendar 1, Weather 1.

Shortcuts is the one place a domain IS read; Step 3 deletes that read:

```swift
// App/Services/Shortcuts.swift:167-184
        } catch {
            if process.isRunning {
                process.terminate()
            }
            log.error("Failed to run shortcuts command: \(error.localizedDescription)")
            let nsError = error as NSError
            if nsError.domain == "ShortcutsError" {
                throw error
            }
            throw NSError(
                domain: "ShortcutsError",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to run shortcuts command: \(error.localizedDescription)"
                ]
            )
        }
```

### Tool calls that open modal UI

```swift
// App/Services/BookmarkedSQLiteStore.swift:88-104
    func activate() async throws {
        if canAccessDefaultPath { ... return }
        if canAccessUsingBookmark { ... return }

        log.debug("Opening file picker for manual database selection")
        guard await showDatabaseAccessAlert() else {
            throw AccessError.userDeclinedAccess(resourceName)
        }

        let selectedURL = try await showPicker()
```

`showDatabaseAccessAlert()` calls `alert.runModal()` (`:186`) and
`showPicker()` calls `openPanel.runModal()` (`:219`). Both are reached from
tool handlers through each service's `activate()`:

```swift
// App/Services/Messages.swift:97-99
    private func fetchMessages(_ arguments: [String: Value]) async throws -> Value {
        log.debug("Starting message fetch with arguments: \(arguments)")
        try await self.activate()
```

Same line at `App/Services/CallHistory.swift:83` and
`App/Services/ScreenTime.swift:85`, `:158`, `:212`.

The handlers do not need it. The read path already fails with a client-facing
error when there is no access:

```swift
// App/Services/BookmarkedSQLiteStore.swift:114-125
    func resolvedAccess() throws -> (path: String, scopedURL: URL?) {
        if canAccessDefaultPath {
            return (defaultPath, nil)
        }
        let url = try resolveBookmarkURL()
        return (databasePath(from: url), url)
    }

    func resolveBookmarkURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw AccessError.noBookmarkFound
        }
```

`CallHistory.swift:157-160` and `ScreenTime.swift:272-275`
(`createDatabaseConnection()`) call `resolvedAccess()`;
`Messages.swift:350-360` (`withDatabaseConnection`) calls
`resolveBookmarkURL()`.

The interactive path must stay for the menu toggle. It is
`App/Views/ServiceToggleView.swift:32` (`try await config.service.activate()`)
and `App/Controllers/ServiceRegistry.swift:57` (`grantAccess()`). Commit
`40c9a3b` added `NSApp.activate(ignoringOtherApps: true)` before the alert and
the picker so the dialog is visible from the toggle; do not remove it.

`App/Services/Notifications.swift:375` also calls `store.activate()`, but only
inside the service's own `activate()`; the `notifications_fetch` handler never
calls it. Nothing to change there.

### Duplicate dispatch guards

The production handler checks "unknown tool" and "service off" inline:

```swift
// App/Controllers/ServerNetworkManager.swift:562-581
            let enabledServiceIDs = await self.enabledServiceIDs
            guard let definition = try await self.toolDefinition(named: params.name) else {
                let message = callToolUnknownNameText(params.name)
                serverLog.error("\(message)")
                return CallTool.Result(
                    content: [.text(text: message, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            guard enabledServiceIDs.contains(definition.serviceID) else {
                let message = callToolServiceDisabledText(
                    params.name,
                    serviceName: serviceDisplayName(forServiceID: definition.serviceID)
                )
                serverLog.error("\(message)")
                return CallTool.Result(
                    content: [.text(text: message, annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            do {
                let result = try await definition.localTool.callAsFunction(
                    params.arguments ?? [:]
                )
```

A second copy of the same two guards exists only for tests:

```swift
// App/Controllers/ServerNetworkManager.swift:779-812
func resolveToolDefinition(named name: String, from definitions: [ToolDefinition]) -> ToolDefinition? {
    definitions.first { $0.localTool.name == name }
}

func callToolUnknownNameText(_ name: String) -> String {
    "Tool not found: \(name)"
}

func serviceDisplayName(forServiceID id: String) -> String { ... }

func callToolServiceDisabledText(_: String, serviceName: String) -> String {
    "\(serviceName) is off. Turn it on in the iMCP menu bar."
}

/// Unknown names and known-but-disabled services must not share a string.
func callToolUnavailableText(
    name: String,
    definition: ToolDefinition?,
    enabledServiceIDs: Set<String>
) -> String? { ... }
```

`resolveToolDefinition` and `callToolUnavailableText` are called only from
`iMCPTests/CallToolDispatchTests.swift`. The handler's `catch` block
(`ServerNetworkManager.swift:628-642`) already turns any thrown error into
`CallTool.Result(isError: true)` with `sanitizedToolErrorMessage(for:)`.

### Tests that read domain/code

- `iMCPTests/AppModelTests.swift:31-35` — `CaptureServiceError` / `11`
- `iMCPTests/AppModelTests.swift:398-402` — `RemindersError` / `4`
- `iMCPTests/PhotoServiceTests.swift:31-46` — `PhotoService` / `99` and `4`
  through `photoImageCallbackResult`, which returns `Result<NSImage, NSError>`
  (`App/Services/Photos.swift:37-50`)

### Logs that publish caller-supplied text

`privacy: .public` on a shortcut name, shortcut stderr, and alarm arguments:
`App/Services/Shortcuts.swift:215, 284, 286, 296, 313`,
`App/Services/Calendar.swift:478, 514`. Raw error text logged public:
`App/Controllers/ICloudSession.swift:799` (three lines under a comment saying
Apple's errors "carry request ids and internal paths"),
`App/Services/Location/LocationSampler.swift:200`.

### Conventions

- Swift 6 strict concurrency, warnings are errors. An unused local variable is
  a warning, so it fails the build.
- `swift format`: 4-space indent, 120-column limit. The formatter does not
  wrap string literals; split a long message with `+` yourself.
- Errors reach MCP clients only if they conform to `ClientFacingError`. A
  client-facing message is authored text plus at most the caller's own
  argument echoed back. It never carries a path, SQL, stderr, or another
  error's `localizedDescription`.
- Tests are plain `XCTest` in `iMCPTests/`. Test files are NOT auto-discovered
  (four hand-made `project.pbxproj` entries per file). This plan adds tests to
  existing files only.
- All members of a SwiftUI `View` are `@MainActor`-isolated.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| App tests | `Scripts/test.sh --app-only` | all pass |
| One test class | `Scripts/test.sh --only iMCPTests/<TestClass>` | all pass |
| Both suites | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` prints nothing on success; success is exit code 0. Never run
`xcodebuild test -scheme iMCP` directly: the always-on watchdog relaunches the
installed app and breaks the test host. Never `launchctl bootout` the
always-on agent. Start from an up-to-date `main`.

## Scope

**In scope** (the only files you should modify):
- `App/Controllers/ToolErrorResponse.swift`
- `App/Controllers/ServerNetworkManager.swift` (CallTool handler and the
  free functions at `:779-812` only)
- `App/Controllers/ICloudSession.swift` (line 799 only)
- `App/Services/BookmarkedSQLiteStore.swift` (one message string)
- `App/Services/Messages.swift`, `CallHistory.swift`, `ScreenTime.swift`
  (delete one line per handler)
- `App/Services/Capture.swift`, `Photos.swift`, `Maps.swift`, `Shortcuts.swift`,
  `Contacts.swift`, `Calendar.swift`, `Reminders.swift`, `Weather.swift`,
  `Notes.swift` (error throws and log privacy only)
- `App/Services/Location/LocationSampler.swift` (the log line at 200 only)
- `App/Views/LocationWindow.swift` (line 1166 only)
- `App/Views/SettingsView.swift` (lines 744-748 only)
- `iMCPTests/ToolErrorSanitizationTests.swift`, `iMCPTests/CallToolDispatchTests.swift`,
  `iMCPTests/AppModelTests.swift`, `iMCPTests/PhotoServiceTests.swift`

**Out of scope** (do NOT touch, even though they look related):
- `App/Services/BrowserHistory.swift` — its 3 `NSError` throws carry
  `sqlite3_errmsg` text, which must stay hidden, and plan 049 rewrites that
  open/query code.
- Argument parsing, limits, enums, coordinates — plan 038.
- Tool annotations — plan 039.
- `status.lastFailure` at `LocationSampler.swift:199` and
  `App/Services/Location.swift:1257` — plan 040 (it uses the `fallback:`
  parameter this plan adds).
- `App/Services/Location/LocationHistoryStore.swift:530, 569` — these log
  `sqlite3_errmsg` for iMCP's own store. That text is written by SQLite, names
  only schema objects, and is the only diagnostic for a broken store. Keep.
- `App/Views/SettingsView.swift:466, 484` (launch at login) — the owner's own
  Settings window, the system's error is the actionable content, and there is
  no logger in that file to keep it otherwise. Keep.
- `App/Views/LocationWindow.swift:243, 410, 453` and
  `App/Views/SettingsView.swift:836, 853, 890` — every call in those `do`
  blocks is on `LocationHistoryStore`, which throws only
  `LocationHistoryError` (authored text). Nothing raw reaches the UI. Keep.
- `App/Views/ServiceToggleView.swift:41` — commit `40c9a3b` logs the
  activation failure reason on purpose.
- The `NSApp.activate(ignoringOtherApps: true)` lines in
  `BookmarkedSQLiteStore.swift:185, 217`.
- Permission prompts shown by macOS itself (Contacts, Calendar, Photos,
  Camera, Notes Automation) when a tool is called before the user has decided.
  Those are system prompts, not iMCP dialogs; removing them is a separate
  decision (see Maintenance notes).
- The Maps continuation blocks. Plan 049 replaces them; here you only swap the
  error expression inside them.

## Git workflow

- Branch: `advisor/042-actionable-tool-errors`
- Conventional commits, one per step, e.g.
  `fix: stop tool calls opening the database access dialog`,
  `refactor: replace NSError throws with ToolFailure`.
- Do NOT push or open a PR unless the operator instructed it. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream` (`mattt/iMCP`)
  must never receive pushes or PRs.

## Steps

### Step 1: Add `ToolFailure` and a `fallback:` parameter

In `App/Controllers/ToolErrorResponse.swift`:

1. Replace the body of `sanitizedToolErrorMessage` so the generic text exists
   once and callers can supply their own:

```swift
func sanitizedToolErrorMessage(
    for error: Error,
    fallback: String = "Tool execution failed. See iMCP logs for details."
) -> String {
    (error as? ClientFacingError)?.errorDescription ?? fallback
}
```

2. Add below `ToolInputError`:

```swift
/// A failure the caller cannot fix by changing an argument but can act on: a
/// permission the user must grant, something that was not found, a timeout.
/// Same content rule as `ToolInputError`.
struct ToolFailure: ClientFacingError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
```

Do not merge it with `ToolInputError`; tests assert `error is ToolInputError`.

**Verify**: `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"` → `exit=0`.

### Step 2: Stop tool handlers opening the database dialog

1. Delete the line `try await self.activate()` at `App/Services/Messages.swift:99`,
   `App/Services/CallHistory.swift:83`, and `App/Services/ScreenTime.swift:85`,
   `:158`, `:212`. Delete nothing else. Each service's `func activate()` stays
   (the menu toggle calls it).
2. In `App/Services/BookmarkedSQLiteStore.swift:21-22`, replace the
   `.noBookmarkFound` text so the failure the handlers now surface says what
   to do:

```swift
            case .noBookmarkFound:
                return "iMCP cannot read this database. Grant iMCP Full Disk Access in System Settings > "
                    + "Privacy & Security, or switch the service off and on in the iMCP menu to choose the file."
```

**Verify**:
```console
git grep -n 'self.activate()' -- App/Services/Messages.swift App/Services/CallHistory.swift App/Services/ScreenTime.swift ; echo "exit=$?"
git grep -c 'runModal' -- App/Services/BookmarkedSQLiteStore.swift
git grep -c 'NSApp.activate(ignoringOtherApps: true)' -- App/Services/BookmarkedSQLiteStore.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ no matches and `exit=1`; `App/Services/BookmarkedSQLiteStore.swift:2`;
`App/Services/BookmarkedSQLiteStore.swift:2`; `exit=0`.

### Step 3: Replace the `NSError` throws

List the sites first: `git grep -n 'NSError(' -- App/Services`.

**Default rule** for every site not named in the tables below: replace the
whole `NSError(domain: ..., code: ..., userInfo: [NSLocalizedDescriptionKey: S])`
expression with `ToolFailure(S)`, keeping the string `S` exactly as it is.
`throw NSError(...)` becomes `throw ToolFailure(S)`;
`continuation.resume(throwing: NSError(...))` becomes
`continuation.resume(throwing: ToolFailure(S))`; `.failure(NSError(...))`
becomes `.failure(ToolFailure(S))`. Every string covered by the default rule
is a fixed literal or echoes the caller's own argument (`albumId`,
`identifier`, `address`, shortcut `name`), so it is safe to send.

Do one file, build, then the next. Commit once at the end of the step.

**Permission sites — replace the whole function body shown.**

`App/Services/Contacts.swift:102-141`:

```swift
    func activate() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return }
        if status == .notDetermined, try await contactStore.requestAccess(for: .contacts) { return }
        log.error("Contacts access not granted")
        throw ToolFailure(
            "Contacts access is not granted. Allow iMCP in System Settings > Privacy & Security > Contacts."
        )
    }
```

`App/Services/Photos.swift:102-141`:

```swift
    func activate() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            log.error("Photo library access not granted")
            throw ToolFailure(
                "Photo library access is not granted. Allow iMCP in System Settings > Privacy & Security > Photos."
            )
        }
    }
```

`App/Services/Capture.swift:162-196` (`requestPermission(for:)`):

```swift
    private func requestPermission(for mediaType: AVMediaType) async throws {
        let mediaName = mediaType == .video ? "Camera" : "Microphone"
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        if status == .authorized { return }
        if status == .notDetermined, await AVCaptureDevice.requestAccess(for: mediaType) { return }
        log.error("\(mediaName) access not granted")
        throw ToolFailure(
            "\(mediaName) access is not granted. Allow iMCP in System Settings > Privacy & Security > \(mediaName)."
        )
    }
```

**Sites with a new message or a different type:**

| Site | Replace the thrown expression with |
|---|---|
| `Calendar.swift:119` | `ToolFailure("Calendar access is not granted. Allow iMCP full access in System Settings > Privacy & Security > Calendars.")` |
| `Reminders.swift:19` | `ToolFailure("Reminders access is not granted. Allow iMCP full access in System Settings > Privacy & Security > Reminders.")` |
| `Capture.swift:201` | `ToolFailure("Screen recording access is not granted. Allow iMCP in System Settings > Privacy & Security > Screen & System Audio Recording. iMCP may need a restart afterwards.")` |
| `Shortcuts.swift:68` | `ToolInputError("Shortcut name is required")` |
| `Shortcuts.swift:218` | `ToolInputError("Shortcut name must not start with -")` |
| `Shortcuts.swift:192` | `ToolFailure("shortcuts list failed. See iMCP logs for details.")` (stderr stays in the log line above it) |
| `Shortcuts.swift:297` | `ToolFailure("Shortcut '\(name)' failed. See iMCP logs for details.")` (stderr stays in the log line above it) |

Split any message over 120 columns with `+`.

**`Shortcuts.swift:172-183`** — delete the domain check and the wrapping
throw. The `catch` block ends as:

```swift
            log.error("Failed to run shortcuts command: \(error.localizedDescription)")
            throw error
        }
```

The timeout `ToolFailure` from the task group passes through unchanged; any
other error becomes the generic text, exactly as the wrapped `NSError` did.

**`Capture.swift:852-899`** — after the three "Failed to convert to
\(convertLabel)" sites become `ToolFailure("Failed to convert to \(convertLabel)")`,
the local `let convertCode = format == .png ? 7 : 8` is unused. Delete that
line. Keep `convertLabel`.

**`Photos.swift:37-50`** — change the return type of
`photoImageCallbackResult` from `Result<NSImage, NSError>` to
`Result<NSImage, any Error>`; the nil-image branch returns
`.failure(ToolFailure("Failed to load image data for asset"))`. The
`PHImageErrorKey` branch is unchanged.

**`App/Services/Notes.swift`** (`NotesError`, `:34-54`, is private and not
client-facing, so its good Automation message never arrives):

- `:218` `throw NotesError.invalidArgument("id is required")` →
  `throw ToolInputError("id is required")`
- `:230` `throw NotesError.unexpectedResult` →
  `throw ToolFailure("Notes returned an unexpected result")`
- `:259` `throw NotesError.automationDenied` →
  `throw ToolFailure("Automation access to Notes was denied. Enable iMCP under "
  + "System Settings > Privacy & Security > Automation to grant access.")`
- Delete the cases `automationDenied`, `invalidArgument`, `unexpectedResult`
  and their `switch` arms from `NotesError`. Only `scriptFailed(String)`
  remains (it carries AppleScript's own message and must stay hidden).

**Verify**:
```console
git grep -c 'NSError(' -- App/Services
git grep -n 'ShortcutsError\|CaptureServiceError\|MapsServiceError\|convertCode' -- App ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ exactly one line, `App/Services/BrowserHistory.swift:3`; no matches and
`exit=1`; `exit=0`. (The test target does not build yet; Step 6 fixes it.)

### Step 4: One dispatch guard

In `App/Controllers/ServerNetworkManager.swift`:

1. Replace `resolveToolDefinition`, `callToolUnknownNameText`,
   `callToolServiceDisabledText` and `callToolUnavailableText` (`:779-812`)
   with one function. Keep `serviceDisplayName(forServiceID:)` as it is.

```swift
/// Unknown names and known-but-disabled services must not share a string.
func callableTool(
    named name: String,
    definition: ToolDefinition?,
    enabledServiceIDs: Set<String>
) throws -> ToolDefinition {
    guard let definition else {
        throw ToolFailure("Tool not found: \(name)")
    }
    guard enabledServiceIDs.contains(definition.serviceID) else {
        throw ToolFailure(
            "\(serviceDisplayName(forServiceID: definition.serviceID)) is off. Turn it on in the iMCP menu bar."
        )
    }
    return definition
}
```

2. In the `CallTool` handler, delete lines `:562-581` (from
   `let enabledServiceIDs = await self.enabledServiceIDs` through the closing
   brace of the second `guard`) and start the existing `do` block with:

```swift
            do {
                let found = try await self.toolDefinition(named: params.name)
                let enabledServiceIDs = await self.enabledServiceIDs
                let definition = try callableTool(
                    named: params.name,
                    definition: found,
                    enabledServiceIDs: enabledServiceIDs
                )
                let result = try await definition.localTool.callAsFunction(
                    params.arguments ?? [:]
                )
```

The existing `catch` logs the error and returns it through
`sanitizedToolErrorMessage(for:)` with `isError: true`, so the client sees the
same two strings as before. Leave the `isConnectionApproved` and
`isEnabledState` guards above it untouched.

**Verify**:
```console
git grep -n 'resolveToolDefinition\|callToolUnknownNameText\|callToolServiceDisabledText\|callToolUnavailableText' -- App ; echo "exit=$?"
git grep -c 'callableTool' -- App/Controllers/ServerNetworkManager.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ no matches and `exit=1`; `App/Controllers/ServerNetworkManager.swift:2`; `exit=0`.

### Step 5: Generic UI text and private logs

1. `App/Views/LocationWindow.swift:1166` (an `MKLocalSearch` failure; the raw
   text is "The operation couldn't be completed. (MKErrorDomain error 4.)"):

```swift
            searchError = sanitizedToolErrorMessage(
                for: error,
                fallback: "Search failed. Check your connection and try again."
            )
```

2. `App/Views/SettingsView.swift:744-748` — collapse the two `catch` arms into
   one:

```swift
            } catch {
                message = sanitizedToolErrorMessage(
                    for: error,
                    fallback: "The Find My People setup action could not be completed."
                )
            }
```

3. `App/Services/Shortcuts.swift` — delete every `, privacy: .public` in the
   file (the shortcut name at five log lines and the stderr text). Do not
   change the log messages otherwise.
4. `App/Services/Calendar.swift:478` and `:514` — delete `, privacy: .public`
   from `datetimeStr` and `alarmType`.
5. `App/Controllers/ICloudSession.swift:799` — publish only the sanitised
   form, keep the raw text private:

```swift
        Logger.service("location").error(
            "iCloud sign-in failed: \(Self.detail(for: error), privacy: .public) \(error.localizedDescription)"
        )
```

6. `App/Services/Location/LocationSampler.swift:200` — same idea. Do NOT touch
   the `status.lastFailure = error.localizedDescription` line above it (plan
   040 owns it):

```swift
            let reason = sanitizedToolErrorMessage(for: error, fallback: String(describing: type(of: error)))
            log.error("Location sampling failed: \(reason, privacy: .public) \(error.localizedDescription)")
```

**Verify**:
```console
git grep -n 'privacy: .public' -- App/Services/Shortcuts.swift ; echo "exit=$?"
git grep -n 'datetimeStr, privacy\|alarmType, privacy' -- App/Services/Calendar.swift ; echo "exit=$?"
git grep -n 'localizedDescription, privacy: .public' -- App/Controllers/ICloudSession.swift App/Services/Location/LocationSampler.swift ; echo "exit=$?"
git grep -c 'catch let error as ClientFacingError' -- App/Views/SettingsView.swift ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ the first four print no matches and `exit=1`; the build prints `exit=0`.

### Step 6: Update and add tests

1. `iMCPTests/AppModelTests.swift:31-35` — replace the three `nsError` lines
   inside the `catch` with:

```swift
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Camera capture already in progress")
```

2. `iMCPTests/AppModelTests.swift:398-402` — replace the three `nsError` lines
   inside the closure with:

```swift
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Reminders fetch failed")
```

3. `iMCPTests/PhotoServiceTests.swift:31-46` — `received` and `missingError`
   are now `any Error`:

```swift
        XCTAssertEqual((received as NSError).domain, "PhotoService")
        XCTAssertEqual((received as NSError).code, 99)
        ...
        XCTAssertEqual(sanitizedToolErrorMessage(for: missingError), "Failed to load image data for asset")
```

4. `iMCPTests/CallToolDispatchTests.swift` — in `CallToolDispatchTests`, change
   the doc comment on `testUniqueToolNamesAcrossRegistry` from
   "`resolveToolDefinition` matches by name" to "Tools are looked up by name".
   Delete `testResolveReturnsNilForUnknownName` and
   `testResolveReturnsDefinitionForKnownName`. Replace
   `testEnabledToolLookupSucceeds` and
   `testUnknownNameAndDisabledServiceUseDifferentErrorTexts` with:

```swift
    private func beep() throws -> ToolDefinition {
        let definitions = try makeToolDefinitions(from: ServiceRegistry.services)
        return try XCTUnwrap(definitions.first { $0.localTool.name == "utilities_beep" })
    }

    func testEnabledToolIsCallable() throws {
        let definition = try beep()
        let callable = try callableTool(
            named: "utilities_beep",
            definition: definition,
            enabledServiceIDs: [definition.serviceID]
        )
        XCTAssertEqual(callable.localTool.name, "utilities_beep")
        let encoded = callToolJSONText(from: Data("{\"ok\":true}".utf8))
        XCTAssertEqual(encoded.text, "{\"ok\":true}")
        XCTAssertFalse(encoded.isError)
    }

    func testUnknownNameAndDisabledServiceUseDifferentErrorTexts() throws {
        let definition = try beep()
        XCTAssertThrowsError(
            try callableTool(named: "unknown_tool", definition: nil, enabledServiceIDs: [definition.serviceID])
        ) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Tool not found: unknown_tool")
        }
        XCTAssertThrowsError(
            try callableTool(named: "utilities_beep", definition: definition, enabledServiceIDs: [])
        ) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "Utilities is off. Turn it on in the iMCP menu bar."
            )
        }
        XCTAssertEqual(serviceDisplayName(forServiceID: definition.serviceID), "Utilities")
    }
```

   Leave `testNonUTF8JSONIsError` and the whole `ToolSchemaHygieneTests` class
   alone.

5. `iMCPTests/ToolErrorSanitizationTests.swift` — add to the existing
   `ClientFacingToolErrorTests` class:

```swift
    func testToolFailureReachesTheCaller() {
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: ToolFailure("Display not found")),
            "Display not found"
        )
    }

    func testFallbackReplacesOnlyTheGenericText() {
        let hidden = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "/Users/test/chat.db"])
        XCTAssertEqual(sanitizedToolErrorMessage(for: hidden, fallback: "Search failed."), "Search failed.")
        XCTAssertEqual(
            sanitizedToolErrorMessage(for: ToolFailure("Display not found"), fallback: "Search failed."),
            "Display not found"
        )
    }

    /// Tool handlers no longer open the database dialog, so this text is what
    /// a client sees when iMCP has no access.
    func testMissingDatabaseAccessSaysWhatToDo() {
        let message = sanitizedToolErrorMessage(for: BookmarkedSQLiteStore.AccessError.noBookmarkFound)
        XCTAssertTrue(message.contains("Full Disk Access"))
        XCTAssertTrue(message.contains("iMCP menu"))
    }
```

**Verify**:
```console
git grep -n 'nsError.domain\|resolveToolDefinition\|callToolUnavailableText' -- iMCPTests ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/CallToolDispatchTests --only iMCPTests/ClientFacingToolErrorTests --only iMCPTests/ToolErrorSanitizationTests --only iMCPTests/PhotoServiceTests
```
→ no matches and `exit=1`; all selected tests pass.

### Step 7: Full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh
git diff --shortstat 8165d29..HEAD -- App
```

**Verify**: `exit=0`, `exit=0`, all tests pass, and the shortstat shows more
deletions than insertions (expect roughly 150 or more net lines removed under
`App/`). If `swift format -i` changed files outside the in-scope list, revert
those files (`git checkout -- <file>`) before committing.

## Test plan

- **Updated**: `AppModelTests` (2 assertions), `PhotoServiceTests` (1 test),
  `CallToolDispatchTests` (2 tests deleted, 2 rewritten).
- **New**, in `ClientFacingToolErrorTests` inside
  `iMCPTests/ToolErrorSanitizationTests.swift`: `ToolFailure` passes the
  sanitizer; `fallback:` replaces only the generic text and never hides an
  authored one; the missing-database-access text names Full Disk Access and
  the menu.
- **Structural pattern**: the existing tests in `ClientFacingToolErrorTests`
  (`iMCPTests/ToolErrorSanitizationTests.swift:169-212`).
- **Not automatable** (TCC state cannot be set from a test): the permission
  messages themselves, and that a tool call no longer opens the dialog. Step 2
  proves the second by grep. Say in your report that these were not exercised
  live.
- Verification: `Scripts/test.sh` → all pass, including 3 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `git grep -c 'NSError(' -- App/Services` prints exactly `App/Services/BrowserHistory.swift:3`
- [ ] `git grep -n 'self.activate()' -- App/Services/Messages.swift App/Services/CallHistory.swift App/Services/ScreenTime.swift` prints nothing
- [ ] `git grep -c 'NSApp.activate(ignoringOtherApps: true)' -- App/Services/BookmarkedSQLiteStore.swift` prints `...:2`
- [ ] `git grep -n 'resolveToolDefinition\|callToolUnavailableText\|callToolServiceDisabledText\|callToolUnknownNameText' -- App iMCPTests` prints nothing
- [ ] `git grep -c 'struct ToolFailure' -- App` prints `App/Controllers/ToolErrorResponse.swift:1`
- [ ] `git grep -c 'Tool execution failed. See iMCP logs for details.' -- App` prints `App/Controllers/ToolErrorResponse.swift:1`
- [ ] `git grep -n 'privacy: .public' -- App/Services/Shortcuts.swift` prints nothing
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` passes; `testToolFailureReachesTheCaller`, `testFallbackReplacesOnlyTheGenericText`, `testMissingDatabaseAccessSaysWhatToDo` exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row for 042 updated

## STOP conditions

Stop and report back (do not improvise) if:

- An `NSError(` site in `App/Services` (other than BrowserHistory) builds its
  message from another error's `localizedDescription`, from stderr, from
  `sqlite3_errmsg`, or from a file path, and it is not one of the sites this
  plan names (`Shortcuts.swift:176, 192, 297`). Do not make such text
  client-facing; report the site.
- After Step 2, any tool handler closure in `Messages.swift`, `CallHistory.swift`
  or `ScreenTime.swift` still reaches `BookmarkedSQLiteStore.activate()` by
  another route.
- Step 2 or any later step would require editing `showDatabaseAccessAlert()`,
  `showPicker()`, `ServiceToggleView.swift` or `ServiceRegistry.swift`.
- After Step 3, `git grep` finds a remaining reader of an `NSError` domain or
  code for one of the converted errors (`ShortcutsError`, `CaptureServiceError`,
  `PhotoService`, `MapsServiceError`, `ContactsService`, `CalendarService`,
  `RemindersService`, `RemindersError`, `WeatherServiceError`) anywhere in
  `App/`, `CLI/` or the tests, other than the three test sites Step 6 rewrites.
- The Step 4 handler change makes any test in
  `ServerNetworkManagerGatingTests` or `ServerNetworkManagerAuthTests` fail.
- A step's verification fails twice after a reasonable fix attempt.
- You conclude a new test file is needed (it would silently never run).
- The build fails under Xcode 27 with `ImplicitStrongCapture` or
  `NoUseUnstructuredThrowingTask` on a line you did not edit — that is
  pre-existing; report it rather than fixing it here.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **Do not install.** After tests, the usual local step is
  `Scripts/install-local.sh run`; do not run it unless the operator asks.
- **Rule for new errors**: an argument the caller can correct throws
  `ToolInputError`; anything else the caller or the user can act on throws
  `ToolFailure`; anything carrying system text stays a plain error and is
  logged. Do not add another `NSError(domain:code:userInfo:)` in a service.
- **A reviewer should scrutinise**: that every string passed to `ToolFailure`
  is authored (no interpolated error, stderr, or path); that the three
  collapsed permission functions still request access when the status is
  `.notDetermined`; and that the CallTool handler still returns the two
  distinct strings for unknown and switched-off tools.
- **Behaviour change to announce**: with a database service on but no access,
  `messages_fetch`, `calls_fetch` and the three Screen Time tools now return
  the Full Disk Access message instead of opening a dialog on the Mac. The
  dialog still opens from the menu toggle.
- **Deliberate, reversible choice**: `shortcuts_run` no longer returns the
  `shortcuts` command's stderr to the client (it never did in practice; the
  `NSError` was masked). The stderr can contain temp-file paths. If the owner
  wants it surfaced, that is a one-line change at the `Shortcuts.swift`
  "failed" throw and should be decided on its own.
- **Deferred**: tool calls for Contacts, Calendar, Reminders, Photos, Camera,
  Microphone and Notes still trigger the macOS permission prompt when the user
  has never decided. Making handlers check status without requesting would
  mirror Step 2, but it changes first-run behaviour and needs the owner's call.
- **Interactions**: plan 040 should use
  `sanitizedToolErrorMessage(for:fallback:)` with a type-name fallback (the
  form at `LocationSampler.swift`) for `status.lastFailure` and
  `Location.swift:1257`. Plan 049 replaces the Maps continuation blocks and
  deletes three of the `ToolFailure` sites converted here; it also deletes
  parts of `PhotoServiceTests.swift`. Plan 038 edits argument parsing in the
  same service files.
- **Not done, on purpose**: `BrowserHistory.swift` keeps 3 `NSError` throws;
  `LocationHistoryStore` keeps two public `sqlite3_errmsg` log lines; the
  launch-at-login and location-history UI strings are unchanged. Reasons are in
  the Out of scope list.
