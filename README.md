<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/hero-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/hero-light.svg">
  <img alt="iMCP">
</picture>

iMCP is a macOS app that gives an AI client access to your calendar, contacts,
messages, and other local data, one service at a time, only when you say so.
It works with any client that speaks the
[Model Context Protocol (MCP)][mcp]: coding agents, chat apps,
and the [growing list of others][mcp-clients].
iMCP has no server of its own and no analytics. What it keeps on your Mac is
listed under [Activate services](#activate-services).

## Capabilities

<table>
  <tr>
    <th></th>
    <td><strong>Browser History</strong></td>
    <td>Search recent browsing history from Safari, Chrome, and Arc with filters for browser, date range, and URL/title search.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/calendar.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Calendar</strong></td>
    <td>List calendars, view events, create and update events with recurrence, alarms, and availability status, and delete events.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Call History</strong></td>
    <td>Fetch recent phone and FaceTime calls with direction, date range, and contact or address filters after granting database access.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Capture</strong></td>
    <td>Take photos with the camera, record short audio clips with the microphone, and capture screenshots of the screen, windows, or applications after granting the required system permissions.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/contacts.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Contacts</strong></td>
    <td>Look up your own contact card, search contacts by name, phone number, or email address, and create or update contacts.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Location</strong></td>
    <td>See where the people and devices in your life are, through iCloud Find My: device-derived family data uses the iCloud web provider; the default-off Find My People expert preview reads consented People shares locally after a one-time human-gated setup. Also reads the location history iMCP records for your phone (stays, visits, and gaps), manages named places, and plays a sound on one of your own devices, at most once every 30 seconds per device. See the <a href="docs/find-my-people-setup.md">security and setup guide</a>.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/maps.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Maps</strong></td>
    <td>Search for places, get directions and travel time estimates by car, foot, transit, or bike, look up points of interest, convert between addresses and geographic coordinates, and generate static map images.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/messages.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Messages</strong></td>
    <td>Access message history with specific participants within customizable date ranges, including which conversation each message belongs to and a listing of its attachments.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Notes</strong></td>
    <td>List Notes folders, search notes by title or content, optionally scoped to a folder, and read a note in full.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Notifications</strong></td>
    <td>Search local Mac and forwarded iPhone notifications by app, text, source, and date range. Results identify their source and coverage. iPhone results cover only notifications that reached this Mac, and the two sources are not deduplicated. Notification text is untrusted third-party content, and Full Disk Access may be required.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Photos</strong></td>
    <td>Search the photo library by date, media type, favorite status, and album, with the place name where each photo was taken, list albums, and fetch an image.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/reminders.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Reminders</strong></td>
    <td>View, create, edit, complete, and delete reminders with customizable due dates, priorities, and alerts across different reminder lists. Deleting a repeating reminder deletes the whole series.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Screen Time</strong></td>
    <td>Query Screen Time and device usage insights, including app usage, web activity, and device pickups.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Shortcuts</strong></td>
    <td>List and run Shortcuts on your Mac, optionally passing text input.</td>
  </tr>
  <tr>
    <th></th>
    <td><strong>Utilities</strong></td>
    <td>Play system sounds from connected MCP clients.</td>
  </tr>
  <tr>
    <th>
      <img src="Assets/weather.svg" width="48" height="48" alt="" role="presentation"/>
    </th>
    <td><strong>Weather</strong></td>
    <td>Current conditions plus hourly, daily, and minute-by-minute forecasts for any location. Release builds only; a Debug build from source has no Weather service.</td>
  </tr>
</table>

## Getting started

> [!NOTE]
> The download link and Homebrew cask below install the **upstream**
> `mattt/iMCP` build. Pairing, permissions, and local-signing features
> documented later exist only in this fork; build from source to get them.
> See [Building from source](#building-from-source).

### Download and open the app

First, [download the iMCP app](https://iMCP.app/download).

Or, if you have [Homebrew](https://brew.sh) installed,
you can run the following command:

```console
brew install --cask mattt/tap/iMCP
```

<img align="right" width="344" src="/Assets/imcp-screenshot-first-launch.png" alt="Screenshot of iMCP on first launch" />

When you open the app,
you'll see a
<img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
icon in your menu bar.
There's no Dock icon. Everything starts from that menu.

Click the icon to open the iMCP menu, which lists every service.
They all start out gray, which means they're off.

The blue toggle at the top means the MCP server is running
and will accept connections from MCP clients.

<br clear="all">

<img align="right" width="372" src="/Assets/imcp-screenshot-grant-permission.png" alt="Screenshot of macOS permission dialog" />

### Activate services

Click a service icon to turn it on, and macOS asks for permission.
Turning on Calendar, for example, brings up a dialog that reads `"iMCP" Would Like Full Access to Your Calendar`.
Click <kbd>Allow Full Access</kbd> to continue.

> [!IMPORTANT]
> iMCP sends your data to two places only: the MCP client you connect, which
> _does_ send it off device as part of tool calls, and the Apple services a
> tool calls (iCloud Find My, Maps, Weather).
> It keeps a few things on this Mac: your settings, the fingerprints of
> paired clients, and, once you sign in for Location, your Apple ID password
> and iCloud session in the Keychain plus up to 90 days of location history.
> See [iCloud sign-in and location history](#icloud-sign-in-and-location-history).

<br clear="all">

<img align="right" width="344" src="/Assets/imcp-screenshot-all-services-active.png" alt="Screenshot of iMCP with all services enabled" />

Once a service is on, its icon picks up a color:
red for Calendar, green for Messages, purple for Maps, and so on.

Repeat for every capability you want.
These are the standard macOS permission prompts, so anything you grant here
you can take back later in System Settings under Privacy & Security.

<!-- <br clear="all"> -->

<br clear="all">

### Connect a client

Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" />
\> "Connect a Client…".
The window shows the server command, a ready-made snippet for your client,
and a pairing code if you want to skip the approval prompt.

Every MCP client takes the same thing: the path to the `imcp-server`
executable inside the app bundle.

```console
/Applications/iMCP.app/Contents/MacOS/imcp-server
```

For a client configured by file, add it under `mcpServers`:

```json
{
  "mcpServers": {
    "iMCP": {
      "command": "/Applications/iMCP.app/Contents/MacOS/imcp-server"
    }
  }
}
```

For a client with a CLI:

| Client | Command |
| --- | --- |
| [Claude Code][claude-code] | `claude mcp add --scope user iMCP -- /Applications/iMCP.app/Contents/MacOS/imcp-server` |
| [Codex CLI][codex] | `codex mcp add iMCP -- /Applications/iMCP.app/Contents/MacOS/imcp-server` |
| [Amp][amp] | `amp mcp add iMCP -- /Applications/iMCP.app/Contents/MacOS/imcp-server` |
| [Cursor][cursor] | Paste the JSON above into `~/.cursor/mcp.json`, or use the [install link][cursor-install]. |
| [Claude Desktop][claude-app] | Paste the JSON above into `~/Library/Application Support/Claude/claude_desktop_config.json` (Settings › Developer › Edit Config). |

<img align="right" width="372" src="/Assets/imcp-screenshot-approve-connection.png" />

### First connection

Restart the client. When it connects, iMCP asks you to approve it.
Tick **Always allow this client** and it never asks again; see
[Pairing](#pairing) for the details.

<br clear="all">

Once connected, the client lists iMCP's tools. The exact number depends on
which services you've enabled. Ask something that needs your data:

> "How's the weather where I am?"

The client picks the tools it needs and answers from what it finds,
so you never have to paste the data in yourself.

### At a glance

The menu bar window shows a status line for each thing that can quietly
stop working: Full Disk Access, the iCloud session behind Location, and
paired clients. Green means fine. Orange or red means click it, and the click
does the fix. Settings has the same information with more detail.

## Security

Pairing stops other processes running as you from quietly using the macOS
permissions you granted iMCP. That's the threat it's built for. It does nothing
against root, or against a user account that is already compromised.

See [Pairing](#pairing) for how to approve a client once. To start over,
choose **Unpair All** on the Clients page of Settings. That drops every stored
fingerprint, and each client goes back to asking for approval on every
connection.

> **Release note:** we removed the legacy name-based trusted-client storage.
> Pairing uses public-key fingerprints only, and old `trustedClients` entries
> in UserDefaults are ignored.

## Pairing

Pairing is optional. Turn it on for a client you trust and it reconnects
without an approval prompt every time.

The easy path is the approval dialog. When a client proves it holds a signing
key during the auth preamble but isn't paired yet, the dialog shows the
verified key fingerprint along with an **Always allow this client (pair)**
checkbox. Approve with the box checked and iMCP remembers that key.

The other path is a one-time code. Choose **Connect a Client…** from the menu
bar and generate a single-use code that expires in five minutes. Clients that
support the auth preamble can include the code in their `AUTH-RESPONSE`:

```console
imcp-server --pair YOURCODE
```

Spawned clients can also read `IMCP_PAIR_CODE`. Given a valid code and
signature, iMCP adds the client fingerprint on its own, with no prompt.

Clients that talk directly over TCP, skipping the bundled `imcp-server` CLI,
never run the preamble. They can implement the same challenge/response frames
plus an optional pairing code, or live with the manual approval prompt each
time.

On first run, `imcp-server` creates a P-256 signing key in the Keychain, or at
`IMCP_KEY_FILE` in debug builds. Print the public-key fingerprint with:

```console
imcp-server --fingerprint
```

Rotate the signing key (requires re-pairing):

```console
imcp-server --rotate-key
```

## Technical details

### App & CLI

iMCP is a macOS app that bundles a command-line executable, `imcp-server`.

- [`iMCP.app`](/App/) is the UI for configuring services, and, more to the
  point, the process macOS grants system permissions to. That's what lets it
  read Contacts, Calendar, and the rest.
- [`imcp-server`](/CLI/) is an MCP server that
  uses standard input/output for communication
  ([stdio transport][mcp-transports]).

The app and CLI talk to each other over the local network.
The CLI first tries a direct `127.0.0.1` connection to the port the app
publishes in a listener-endpoint file. If that file is missing or stale, it
falls back to [Bonjour][bonjour] discovery ("\_mcp.\_tcp", domain "local").
Loopback is the reliable path, and the reason is annoying. macOS gates Bonjour
resolution behind the Local Network privacy permission, and a background daemon
like the CLI never gets prompted for it.
The CLI reads requests from MCP clients on `stdin` and relays them to the app.
Responses come back from the app and go out on `stdout`.
See [`StdioProxy`](CLI/StdioProxy.swift)
for implementation details.

For this project, we created what became
[the official Swift SDK][swift-sdk]
for Model Context Protocol servers and clients.
The app uses this package to handle proxied requests from MCP clients.

### Building from source

CI builds and tests with Xcode 26 on macOS 26 for every pull request.
Twice a week it runs the same build and tests on GitHub's Xcode 27 preview
image, which reports problems without being part of a merge.
Debug builds sign automatically with the development team's managed
provisioning profile, which the keychain access group needs; build and run
them with `Scripts/install-local.sh build` and `run` (below), and keep Xcode
for editing and debugging. The app requires macOS 15.1 or later.

From Terminal:

```console
Scripts/install-local.sh build
Scripts/test.sh
Scripts/lint.sh
```

`Scripts/install-local.sh build` compiles the app and the bundled CLI into
`.build/DerivedData`, the build tree `Scripts/test.sh` reuses, and leaves the
installed app alone. A plain `xcodebuild` build compiles everything again into
Xcode's default DerivedData and registers one more `iMCP.app` with Launch
Services.

`Scripts/test.sh` runs both test suites, the same way CI does. It pauses the
installed app's always-on watchdog and `imcp-server` processes, stops
`/Applications/iMCP.app`, and restores them afterwards; running the `iMCP`
scheme's tests directly fails while the installed app is running.
A test that runs for more than one minute fails as hung, and the run goes on
with the next test.
`--app-only`, `--cli-only`, and `--only iMCPTests/<TestClass>` narrow the run.
`Scripts/lint.sh` is the CI format check (`--fix` formats first, `--scripts`
checks the shell, Python, and Node scripts).

To exercise a local build, run the app, enable at least one service from the
menu bar, and point the MCP Inspector or another MCP client at the built
`imcp-server` executable. See the Debugging section below for MCP Inspector and
Companion setup.

### Local development install

A plain Xcode Debug build has an unstable development signature that changes
on every rebuild. macOS ties TCC grants (Full Disk Access, Screen Recording)
and Keychain access to the signing identity, so a rebuild silently breaks
previously-granted permissions and makes the Keychain-stored CLI signing key
unreachable.

`Scripts/install-local.sh` fixes this. It builds the `iMCP` scheme (Debug),
re-signs the app with a stable local identity, and installs it to
`/Applications/iMCP.app`, keeping a zip of the previous install in
`~/Library/Application Support/iMCP/Local Install Backups/`
(`IMCP_KEEP_BACKUPS`, default 1).
`Scripts/verify-app-signing.sh` checks the signature and required
entitlements. Run it as `Scripts/verify-app-signing.sh /path/to/iMCP.app`.

The installer reuses the installed app's Apple Development or local signing
identity when available; otherwise it uses this Mac's first Apple Development
identity. `IMCP_SIGN_IDENTITY` overrides this choice. Before replacement, the
installer compares designated code requirements and stops if the new signature
would invalidate macOS privacy grants. `IMCP_ALLOW_PERMISSION_RESET=1` is the
explicit escape hatch for an intentional one-time identity change.

For day-to-day development, `Scripts/install-local.sh run` installs and
(re)launches the app. Other optional commands: `build` (compiles only and
leaves the installed app alone), `debug` (pauses the watchdog and runs the
installed binary under `lldb` instead of opening it), `logs` (opens the app and
streams the installed bundle's logs via `log stream`), `telemetry` (opens the
app and streams the installed bundle's logs, filtered to its bundle
identifier). `run` waits until the new app has published its listener endpoint.
`install` (the default) stops after the verified install. Do not launch
Xcode's Debug build directly.

When the always-on watchdog is running, a relaunch restarts it too, so the
new watchdog code is live and the watchdog brings up the new app. After a
relaunch the script runs `Scripts/post-install.local.sh` if it exists and is
executable. That file is gitignored, for per-Mac steps such as reconnecting an
MCP client.

To finish a change without manually managing Git, GitHub, CI, installation, or
cleanup, run:

```console
Scripts/ship.sh -m "fix: describe the change"
```

The command creates a `ship/*` branch when run on `main`, formats, lints, and
builds the checkout, commits tracked changes, pushes, opens a PR, waits for CI
(which runs both test suites), merges it, updates the `main` worktree to the
exact merge commit, installs and verifies `/Applications/iMCP.app`, then
removes the merged branch, any temporary worktree, and other local branches
whose PRs already merged. Untracked files stop the run; `git add` the ones
that belong. `-b` sets the PR body and `--local-tests` also runs
`Scripts/test.sh` before pushing. The run stops if the change deletes
planning records under `plans/`, `docs/plans/`, or `docs/ideation/` (see the
Records table in `AGENTS.md`); `--allow-record-deletes` overrides it. If CI fails, fix it and re-run the same
command; it reuses the open PR.

For a notarized public release, set the existing `notarytool` Keychain profile
and include a version:

```console
KEYCHAIN_PROFILE=iMCP Scripts/ship.sh --release 1.2.3 -m "release: 1.2.3"
```

The version bump goes through the same PR and CI gates. Only its merged `main`
commit is tagged, notarized, published, and installed.

### iMessage database access

Apple doesn't provide public APIs for accessing your messages.
However, the Messages app on macOS stores data in a SQLite database located at
`~/Library/Messages/chat.db`.

iMCP is a hardened, signed direct-distribution app, but it does not enable
[App Sandbox][app-sandbox]. Several services read databases protected by
macOS Full Disk Access, and App Sandbox is a separate boundary that would
continue to reject those paths even after Full Disk Access was granted.
macOS still controls access through its normal privacy permissions.

If Messages cannot read `chat.db` after Full Disk Access is granted, enabling
the service opens the standard file picker so you can authorize that database
directly through [`NSOpenPanel`][nsopenpanel].

But opening the iMessage database is just half the battle.
Over the past few years,
Apple has moved away from storing messages in plain text
and instead toward a proprietary `typedstream` format.

For this project, we created [Madrid][madrid]:
a Swift package for reading your iMessage database.
It includes a Swift implementation for decoding Apple's `typedstream` format,
adapted from Christopher Sardegna's [imessage-exporter] project
and [blog post about reverse-engineering `typedstream`][typedstream-blog-post].

### iCloud sign-in and location history

The Location service answers questions about people and devices, not about
this Mac. Its source is Apple's Find My web service, the same one
`icloud.com` uses, so it needs your iCloud account.

Sign in from the Location row in the menu bar. The sheet asks for your Apple
ID, password, and a two-factor code, exactly as Apple's own web sign-in does.
The password and the session and trust tokens Apple returns are kept in the
data-protection Keychain on this Mac only. Apple discards web sessions on its
own schedule; when that happens iMCP signs in again with the saved password
and trust token, with no code needed while the trust token is honored. Nothing
is logged or shown, and **Sign Out** removes all of it.

Find My has a second, service-specific authorization on top of that browser
session. If the browser session still validates but Find My rejects it, iMCP
runs Apple's own Find My web challenge once with the saved password. A failed
challenge is not retried after a relaunch: the menu asks for a manual sign-in
instead of risking repeated Apple account emails or a password lockout.

If you use [Advanced Data Protection][adp], turn on **Access iCloud Data on
the Web** in your iCloud settings first. Without it Apple withholds the
device list and the service will say so.

Apple exposes no location history through Find My, only the latest fix. So
iMCP records its own: while Location is enabled and the app is running it
asks Find My for your iPhone's position every ten minutes (this does ask the
phone for a fresh fix) and appends it to
`~/Library/Application Support/iMCP/location-history.sqlite`. Nothing in that
file leaves the Mac. Samples older than 90 days are deleted automatically.

History starts the first time you sign in with Location on. There is nothing
to read for the days before that. Turning Location off, or quitting the app,
stops the recording. Named places you typed are kept; only the sampled
positions age out.

To see what has been recorded, click the map button at the foot of the menu,
or **Open** on the Location page of Settings. The window
draws the day on a map: the phone's track as a solid line, each place stayed at
as one pin sized by the time spent there, each hole in the record as a dashed span labelled
with how long there was no data, and the latest fix with its accuracy circle.
The track follows the streets: each walk or drive between two recorded
positions is routed through Apple Maps, the same service that looks up
addresses, and the answers (routes, and the addresses and businesses near each
stop) are kept in the history file and deleted with it.
Anything faster than a car, or a hole in the record no car could cover, is
drawn as a flight's arc. **Day**, **Week**, **Month** and **All** set how much
history is shown, and the flame at the right of the toolbar swaps the timed
line for a heat map: colour where the most time was spent, and every journey
as a thin line that brightens where it repeats.
The panel beside the map lists the same stays and gaps in order, each ending in plain
words ("left between 4:10 and 4:20", "signal lost after 4:10, nothing
since", "still there"). Click **Name this place…** on a stay to name it; the
name goes into the same place store the tools read, so `location_now` and
`location_timeline` use it from then on. **Add Place…** names a place by
search instead, for somewhere the phone has not been yet or a place you want
on the map from day one; it keeps the exact Apple Maps result you selected.
**Places** lists everything you have named. Its edit button changes a place's
name, searched address, or radius in place; its trash button deletes it. A stay that is not inside a
named place but within a kilometre of one reports that place and the
distance (`nearPlace`, `nearPlaceMeters`; the label reads "near 45 Main St,
280 m from Office"), which is what lets an agent say "next door to work"
instead of reciting an address. An unnamed stay also carries `nearbyVenues`,
the businesses Apple Maps lists within reach of the fix, closest first. They
are candidates, never a name: one fix sits within its own accuracy of several
storefronts, so the tools say "probably" with a venue and "at" only with a
place you named. The window makes the same offer in the sidebar ("Maybe
Juniper Tavern?") only when the closest venue is within 40 m and clearly
closer than the next, and one click accepts it. The app never names a place
on its own.

Naming a stay asks whether the spot is one of your places or just a label.
**One of my places** (Home, Office, your bar) is drawn on the map, listed
under "My places", and reported to agents with `kind: "notable"`. **Just
label this stop** names stays there without adding the spot to the map: a
deli you stopped at once gets its name, not a place in your world. Labels
report as `kind: "label"` in `location_places` and `placeKind: "label"` on a
stay, so an agent can tell a spot you identified from a place that matters
to you. Accepting a "Maybe…" guess makes a label; **Add Place…** makes one
of your places; either can be changed later by renaming. A stay at a spot you have not named
but keep returning to is marked "Seen N times". The strip along the bottom
shows the sign-in, whether recording is on, and how old the last fix is. The
window reads the history the tools read and runs the same rules, so it cannot
show a stay the tools would not report.

These tools answer the everyday questions, and they describe what was not
recorded as carefully as what was:

- `location_now`: the tracked phone's latest fix, with the device name, the
  fix time and age, Apple's accuracy radius, whether it is stale, and the
  health of the sign-in and the recorder. When Find My cannot answer it
  returns the last recorded position and says so.
- `location_timeline`: one device's stays over a period, with every hole in
  the record longer than 30 minutes listed as a gap. A stay has an `arrival`
  and a `lastObserved` time and an `endedBy` reason: `movement` (the next
  fix was somewhere else, so it left before `departedBefore`), `coverageGap`
  (the record stopped), `queryBoundary` (the period ended first), or
  `ongoing`. A `departure` time is only given for `movement`.
- `location_places`: the places you have named. Only a named place is
  reported as a place; anything else is `near` a reverse-geocoded address,
  which is the nearest street address, not a confirmed destination.
- `location_place_set` and `location_place_delete`: name a place, or
  remove a name. Deleting a place never deletes recorded positions.
- `location_history`: the raw recorded positions for a date range, as
  `{samples, truncated}`. When the range holds more than `limit` samples
  (500 at most), the newest are returned and `truncated` is true.
- `location_ring`: play a sound on one of your own devices. A second request
  for the same device within 30 seconds is refused.

`location_visits` keeps its array shape and gains the same fields; callers
that read `departure` should read `lastObserved` instead, because a stay that
ended in a gap has no known departure. Fixes with an accuracy radius wider
than 300 m are counted but not placed, a stay needs at least two fixes, and
a silence longer than three sampling intervals splits a stay rather than
bridging it.

The sign-in stores the client id the session was issued to, so a quit,
relaunch, or reboot presents the same id to Apple. If Apple rejects either the
browser session or Find My's narrower authorization, the menu says what needs
manual attention instead of repeatedly trying the password in the background.

### JSON-LD for tool results

iMCP tools return their results as
[JSON-LD][json-ld] documents.
For example,
the `contacts_search` tool uses the [Contacts framework][contacts-framework],
which represents people and organizations with the [`CNContact`][cncontact] type.
Here's how an object of that type is encoded as JSON-LD:

```json
{
  "@context": "https://schema.org",
  "@type": "Person",
  "name": "Mattt",
  "url": "https://mat.tt"
}
```

[Schema.org][schema.org] already has vocabularies for
people, postal addresses, events, and most of the other things we need to
represent, so we didn't have to invent our own.
JSON-LD is easy to read whether you're a person, a model, or a parser.

For this project, we created [Ontology][ontology]:
a Swift package for working with structured data.
It includes convenience initializers for types from Apple frameworks,
such as those returned by iMCP tools.

## Debugging

### Using the MCP Inspector

To debug interactions between iMCP and clients,
you can use the [inspector tool](https://github.com/modelcontextprotocol/inspector)
(requires Node.js):

1. Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" /> > "Connect a Client…", then click **Copy** next to the server command
2. Open a terminal and run the following commands:

   ```console
   # Download and run inspector package on imcp-server
   npx @modelcontextprotocol/inspector [paste-copied-command]

   # Open inspector web app running locally
   open http://127.0.0.1:6274
   ```

Inspector shows every request and response between the client and the iMCP
server. It's the fastest way to find out what the protocol is actually doing.

### Using Companion

<img align="right" width="284" src="/Assets/companion-screenshot-add-server.png" />

[Companion][companion] is a utility for testing and debugging MCP servers
(requires macOS 15 or later).
You can browse and call a server's prompts, resources, and tools from it.
Here's how to connect it to iMCP:

1. Click <img style="display: inline" width="20" height="16" src="/Assets/icon.svg" /> > "Connect a Client…", then click **Copy** next to the server command
2. [Download][companion-download] and open the Companion app
3. Click the <kbd>+</kbd> button in the toolbar to add an MCP server
4. Fill out the form:
   - Enter "iMCP" as the name
   - Select "STDIO" as the transport
   - Paste the copied iMCP server command
   - Click "Add Server"

<br clear="all">

## Acknowledgments

- [Justin Spahr-Summers](https://jspahrsummers.com/)
  ([@jspahrsummers](https://github.com/jspahrsummers)),
  David Soria Parra
  ([@dsp-ant](https://github.com/dsp-ant)), and
  Ashwin Bhat
  ([@ashwin-ant](https://github.com/ashwin-ant))
  for their work on MCP.
- [Christopher Sardegna](https://chrissardegna.com)
  ([@ReagentX](https://github.com/ReagentX))
  for reverse-engineering the `typedstream` format
  used by the Messages app.

## License

This project is available under the MIT license.
See [LICENSE.md](LICENSE.md) for more info.

## Legal

iMessage® is a registered trademark of Apple Inc.
This project is not affiliated with, endorsed, or sponsored by Apple Inc.

[adp]: https://support.apple.com/en-us/108756
[amp]: https://ampcode.com
[app-sandbox]: https://developer.apple.com/documentation/security/app-sandbox
[bonjour]: https://developer.apple.com/bonjour/
[claude-app]: https://claude.ai/download
[claude-code]: https://claude.com/product/claude-code
[codex]: https://github.com/openai/codex
[companion]: https://github.com/mattt/Companion
[companion-download]: https://github.com/mattt/Companion/releases/latest/download/Companion.zip
[contacts-framework]: https://developer.apple.com/documentation/contacts
[cncontact]: https://developer.apple.com/documentation/contacts/cncontact
[cursor-install]: https://cursor.com/en-US/install-mcp?name=iMCP&config=eyJjb21tYW5kIjoiL0FwcGxpY2F0aW9ucy9pTUNQLmFwcC9Db250ZW50cy9NYWNPUy9pbWNwLXNlcnZlciAifQ%3D%3D
[cursor]: https://cursor.com
[imessage-exporter]: https://github.com/ReagentX/imessage-exporter
[json-ld]: https://json-ld.org
[madrid]: https://github.com/mattt/Madrid
[mcp]: https://modelcontextprotocol.io/introduction
[mcp-clients]: https://modelcontextprotocol.io/clients
[mcp-transports]: https://modelcontextprotocol.io/docs/concepts/architecture#transport-layer
[nsopenpanel]: https://developer.apple.com/documentation/appkit/nsopenpanel
[ontology]: https://github.com/mattt/Ontology
[schema.org]: https://schema.org
[swift-sdk]: https://github.com/modelcontextprotocol/swift-sdk
[typedstream-blog-post]: https://chrissardegna.com/blog/reverse-engineering-apples-typedstream-format/
