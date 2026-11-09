# Plan 016: Disable name-only persistent client auto-trust

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report - do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b84f266..HEAD -- App/Controllers/ServerController.swift App/Views/ConnectionApprovalView.swift App/Views/SettingsView.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `b84f266`, 2026-07-03

## Why this matters

iMCP exposes personal-data and capture tools to local MCP clients after the user
approves a connection. The current "Always trust this client" feature persists
trust by `clientInfo.name`, a string supplied by the MCP client during
`initialize`. A different local process can present the same name and inherit
auto-approval without a new user prompt. Until plan 015 produces a stronger
identity/pairing design, the safe short-term behavior is to require approval for
each connection and remove name-only auto-trust from the UI.

## Current state

- `App/Controllers/ServerController.swift` - owns connection approval and
  trusted-client persistence.
- `App/Views/ConnectionApprovalView.swift` - approval window with "Always trust"
  checkbox.
- `App/Views/SettingsView.swift` - settings UI for stored trusted clients.

Current trusted-client storage, `App/Controllers/ServerController.swift:207-224`:

```swift
private var trustedClients: Set<String> {
    get {
        (try? JSONDecoder().decode(Set<String>.self, from: trustedClientsData)) ?? []
    }
    set {
        trustedClientsData = (try? JSONEncoder().encode(newValue)) ?? Data()
    }
}

private func isClientTrusted(_ clientName: String) -> Bool {
    trustedClients.contains(clientName)
}

private func addTrustedClient(_ clientName: String) {
    var clients = trustedClients
    clients.insert(clientName)
    trustedClients = clients
}
```

The MCP client name enters the approval path at
`App/Controllers/ServerController.swift:287-296`:

```swift
self.showConnectionApprovalAlert(
    clientID: clientInfo.name,
    approve: {
        Task { await resumeOnce(true) }
    },
    deny: {
        Task { await resumeOnce(false) }
    }
)
```

The auto-approve branch, `App/Controllers/ServerController.swift:356-364`:

```swift
// Trusted clients auto-approve without showing the dialog.
if isClientTrusted(clientID) {
    log.notice("Client \(clientID) is already trusted, auto-approving")
    approve()

    // Notify the user on auto-approved connections.
    sendClientConnectionNotification(clientName: clientID)

    return
}
```

The checkbox, `App/Views/ConnectionApprovalView.swift:4-10` and `:35-40`:

```swift
struct ConnectionApprovalView: View {
    let clientName: String
    let onApprove: (Bool) -> Void  // Bool parameter is for "always trust"
    let onDeny: () -> Void

    @State private var alwaysTrust = false
```

```swift
// Always trust checkbox
HStack(alignment: .firstTextBaseline) {
    Toggle("Always trust this client", isOn: $alwaysTrust)
        .toggleStyle(CheckboxToggleStyle())
    Spacer()
}
```

Settings still advertises automatic trust at
`App/Views/SettingsView.swift:81-94`:

```swift
Text("Trusted Clients")
    .font(.headline)
...
Text("Clients that automatically connect without approval.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Format (write) | `swift format -i -r .` | exit 0 |
| Format lint | `swift format lint --strict --recursive .` | exit 0, no output |
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| CLI tests | `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `App/Controllers/ServerController.swift`
- `App/Views/ConnectionApprovalView.swift`
- `App/Views/SettingsView.swift`

**Out of scope**:
- Implementing cryptographic identity, pairing, TLS, Keychain storage, or
  code-signing checks. Those belong to plan 015 and future build plans.
- Changing service enablement, tool registration, or individual services.
- Deleting existing `UserDefaults` data from user machines. It can remain
  inert until a future migration decides what to do with it.

## Git workflow

- Branch: `advisor/016-disable-name-only-auto-trust`
- Single commit; short imperative message, e.g. "Disable name-only client auto-trust".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Remove automatic approval by stored client name

In `ServerController.showConnectionApprovalAlert`, delete the `if
isClientTrusted(clientID)` branch so every new connection reaches the approval
window. Leave `sendClientConnectionNotification(clientName:)` available if it is
still used elsewhere; do not remove notification code just because this branch
stops using it.

Then remove now-unused private helpers if the compiler reports they are unused:
`isClientTrusted(_:)` and `addTrustedClient(_:)`. Keep `removeTrustedClient`,
`getTrustedClients`, and `resetTrustedClients` only if `SettingsView` still uses
them after Step 3.

Also remove same-name approval coalescing as an implicit trust path. The current
`activeApprovalDialogs` / `pendingApprovals` logic keys by `clientInfo.name`; if
two same-name clients connect while a prompt is open, approving one approves the
pending same-name connection too. Replace that with per-connection approval
state keyed by the `UUID connectionID` already available in the approval handler,
or present/queue one prompt per connection. Keep `clientInfo.name` only as
display text.

**Verify**:
`grep -n "already trusted\\|auto-approving\\|isClientTrusted\\|addTrustedClient" App/Controllers/ServerController.swift`
-> no matches, unless only harmless comments remain that accurately say
auto-trust is disabled.

### Step 2: Remove the "Always trust" checkbox from the approval view

In `ConnectionApprovalView`, remove `@State private var alwaysTrust = false`,
the `Toggle("Always trust this client", ...)` block, and the custom
`CheckboxToggleStyle` if nothing else uses it. Simplest target shape:

```swift
struct ConnectionApprovalView: View {
    let clientName: String
    let onApprove: () -> Void
    let onDeny: () -> Void
    ...
    Button("Allow") {
        onApprove()
    }
```

Update `ConnectionApprovalWindowController.showApprovalWindow` so `onApprove`
takes no Bool and the call site in `ServerController` no longer receives an
`alwaysTrust` value. The approval callback should approve only the current
connection, then clean up that connection's approval state.

**Verify**:
`grep -n "Always trust\\|alwaysTrust\\|CheckboxToggleStyle" App/Views/ConnectionApprovalView.swift App/Controllers/ServerController.swift`
-> no matches.

### Step 3: Make Settings stop advertising automatic trust

Because name-only trust is disabled, the Settings view must not tell users that
clients can connect automatically. Use the smallest clear UI change:

- Replace the "Trusted Clients" section with a static note that persistent
  client trust is disabled until iMCP has stronger client identity, OR
- Remove the section entirely if it has no remaining useful controls.

If you keep old stored-client management as a cleanup affordance, the text must
make clear the entries are inactive legacy entries, not active auto-approval.

**Verify**:
`grep -n "automatically connect without approval\\|Trusted Clients" App/Views/SettingsView.swift`
-> either no matches, or any remaining copy clearly says persistent trust is
disabled/inactive.

### Step 4: Format, build, and test

Run:

```console
swift format -i -r .
swift format lint --strict --recursive .
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build
xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"
```

**Verify**: format lint exits 0; build exits 0; tests print `** TEST SUCCEEDED **`.

## Test plan

- No App UI test target currently covers approval dialogs. Verify by build plus
  manual reasoning:
  - A first connection still opens the approval dialog.
  - Clicking Allow approves the current connection.
  - There is no checkbox or path that persists name-only trust.
  - A second connection with the same client name opens the dialog again.
  - A concurrent same-name connection is not approved by the first connection's
    Allow action unless it has its own prompt/result.

## Done criteria

ALL must hold:

- [ ] `showConnectionApprovalAlert` has no auto-approve branch based on
      `clientInfo.name` or `clientID`
- [ ] Approval UI no longer shows "Always trust this client"
- [ ] Settings no longer states that clients automatically connect without
      approval, unless it clearly labels old entries inactive
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] Same-name approval coalescing is removed or keyed by per-connection UUID,
      not by `clientInfo.name`
- [ ] `xcodebuild ... build` exits 0
- [ ] `xcodebuild test -scheme imcp-serverTests -destination "platform=macOS"` prints `** TEST SUCCEEDED **`
- [ ] Only in-scope files are modified, plus `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report if:

- Product direction requires preserving "Always trust" UX in this patch. In that
  case, do not keep name-only trust; split to a robust identity plan first.
- Removing the checkbox requires broad UI redesign outside the three in-scope
  files.
- The code has already gained a stronger, non-spoofable trust key; if so, this
  plan is stale and should be replaced by a targeted review of that mechanism.

## Maintenance notes

- This is an immediate mitigation, not the final trust model. Plan 015 should
  still produce a durable design for client identity, endpoint authentication,
  and migration.
- Reviewer should scrutinize that no path still calls `approve()` before showing
  the approval UI solely because a client supplied a previously seen name.
