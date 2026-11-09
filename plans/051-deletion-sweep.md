# Plan 051: Delete Sparkle residue, sandbox-only entitlements, iOS build settings, unused links, orphan scripts, and one test-only function

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Info.plist App/App.entitlements App/App.Debug.entitlements App/App.CI.entitlements iMCP.xcodeproj Scripts/verify-app-signing.sh Scripts/measure-runtime-efficiency.py Scripts/measure-mcp-client.sh Scripts/bench-mcp-client.mjs Scripts/find-my-people-key.py docs/solutions/performance/tool-payload-context-cost.md App/Models/AlwaysOnService.swift iMCPTests/AlwaysOnServiceTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. Line numbers in
> `iMCP.xcodeproj/project.pbxproj` WILL shift as soon as any other plan adds a
> test file; always locate pbxproj lines by the object IDs and strings quoted
> below, never by line number alone.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — every change is a deletion, but two groups touch code
  signing (entitlements) and the hand-edited Xcode project file
- **Depends on**: plans/037-isolate-tests-from-real-state.md (the test gate
  used here must not touch real state)
- **Category**: tech-debt
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

The repo carries configuration for things the app does not do: an update
framework that is not linked (Sparkle), App Sandbox entitlements on an app that
is not sandboxed, iOS and visionOS build settings on a macOS-only target, the
same package product linked four times, two linked products nothing imports,
three other people's Xcode user-state files, four scripts nothing calls (one of
which silently reports a perfect score because the code it greps for is gone),
and one Swift function that only tests call. Each item misleads the next reader
about what the app needs and what is verified. This plan removes them and adds
nothing. Expected net change: about 600 lines deleted, 1 line reworded.

## Current state

Repo facts you need:

- macOS menu-bar MCP server. Targets: app `iMCP` (`App/`), CLI `imcp-server`
  (`CLI/`), watchdog `iMCPAlwaysOn` (`AlwaysOnHelper/`), tests in `iMCPTests/`
  (app) and `CLITests/` (CLI). Swift 6, warnings are errors, deployment target
  macOS 15.1. The app is **not sandboxed**: `ENABLE_APP_SANDBOX = NO` in both
  app configurations, and `Scripts/verify-app-signing.sh` asserts the sandbox
  entitlement is false or missing.
- Start from an up-to-date `main`. (`origin/main` has one commit beyond
  `8165d29`; it touches only `CLI/` and `CLITests/`, none of this plan's files.)
- `iMCP.xcodeproj/project.pbxproj` is edited by hand in this plan. It is an
  old-style property list: every deleted line must be removed whole, and
  nothing else on neighbouring lines may change (tabs, trailing commas and
  semicolons included).

### Group A — tracked Xcode user state

`.gitignore:6` already ignores `xcuserdata/`, but three files were committed
before that rule and are still tracked:

```console
$ git ls-files | grep xcuserdata
iMCP.xcodeproj/xcuserdata/carlpeaslee.xcuserdatad/xcschemes/xcschememanagement.plist
iMCP.xcodeproj/xcuserdata/mattt.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist
iMCP.xcodeproj/xcuserdata/mattt.xcuserdatad/xcschemes/xcschememanagement.plist
```

They belong to two other developers' Xcode sessions (82 lines total).

### Group B — orphan scripts

Four files in `Scripts/` (353 lines total):

- `Scripts/measure-runtime-efficiency.py` (60 lines). It greps Swift source for
  an anchor that no longer exists:

  ```python
  # Scripts/measure-runtime-efficiency.py:15-19
  def watchdog_wakeups_per_hour() -> float:
      start = NETWORK.find("listenerWatchdogTask = Task")
      end = NETWORK.find("private func handleListenerStateChange", start)
      if start < 0 or end < 0:
          return 0
  ```

  `grep -rn listenerWatchdogTask App CLI AlwaysOnHelper` returns nothing, so it
  always reports 0 wakeups: a measurement that cannot fail.
- `Scripts/measure-mcp-client.sh` (44 lines) — wrapper whose last line is
  `exec node "${ROOT_DIR}/Scripts/bench-mcp-client.mjs" ...`. Nothing calls it.
- `Scripts/bench-mcp-client.mjs` (237 lines) — default binary path at `:17-20`
  hardcodes one machine's DerivedData directory name. Superseded by
  `Scripts/measure-full-stack-performance.sh` /
  `Scripts/bench-full-stack-performance.mjs`, which report the same
  `tools/list` payload size (`tools_list_bytes`) and are the ones documented in
  `AGENTS.md:39-42`.
- `Scripts/find-my-people-key.py` (12 lines) — a shim that only prints the
  filename of the real module, `Scripts/find_my_people_key.py` (underscores).
  `Scripts/find-my-people-bootstrap.sh:75` calls the underscore file directly.
  **Do not confuse the two: `find_my_people_key.py` (underscores) is live and
  must stay.**

All references to these four names in the repo, outside `plans/`:

```console
$ git grep -n 'measure-runtime-efficiency\|measure-mcp-client\|bench-mcp-client\|find-my-people-key' -- . ':!plans'
Scripts/measure-mcp-client.sh:44:exec node "${ROOT_DIR}/Scripts/bench-mcp-client.mjs" --binary "${BINARY}" --runs "${RUNS}" --warmup "${BENCH_WARMUP:-1}"
docs/plans/2026-08-24-0109-feat-find-my-people-plan.md:259:- **Files:** ... `Scripts/find-my-people-key.py`, ...
docs/solutions/performance/tool-payload-context-cost.md:59:`Scripts/bench-mcp-client.mjs` and direct tool calls:
```

The `docs/solutions/...:58-59` sentence reads:

```markdown
Installed app, same enabled services, measured with
`Scripts/bench-mcp-client.mjs` and direct tool calls:
```

The `docs/plans/2026-08-24-...` line is a historical file list in a dated plan;
it is left alone (see Out of scope).

### Group C — Sparkle residue in `App/Info.plist`

`App/Info.plist` is 18 lines. Lines 11-16 are three Sparkle keys:
`SUEnableInstallerLauncherService` (`<true/>`), `SUFeedURL` (an appcast URL),
and `SUPublicEDKey` (an update-signing public key string). The other two keys,
`LSMultipleInstancesProhibited` (`:5-6`) and `NSBonjourServices` (`:7-10`), are
live and stay.

Proof Sparkle is not used (the only hits are the residue itself):

```console
$ git grep -n -i 'sparkle\|SUFeed\|SUPublicEDKey\|SUEnableInstaller\|appcast\|-spks\|-spki' -- . ':!plans' ':!docs'
App/App.CI.entitlements:27:		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
App/App.CI.entitlements:28:		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
App/App.Debug.entitlements:31:		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
App/App.Debug.entitlements:32:		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
App/App.entitlements:33:		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
App/App.entitlements:34:		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
App/Info.plist:11:	<key>SUEnableInstallerLauncherService</key>
App/Info.plist:13:	<key>SUFeedURL</key>
App/Info.plist:14:	<string>https://downloads.imcp.app/appcast.xml</string>
App/Info.plist:15:	<key>SUPublicEDKey</key>
```

No Swift file imports Sparkle and no package reference for it exists in
`project.pbxproj` (the seven remote packages are madrid, swift-service-lifecycle,
Ontology, MenuBarExtraAccess, swift-log, swift-sdk, JSONSchema).

### Group D — sandbox-only and unused entitlements

Three entitlements files, used as follows:

- `App/App.Debug.entitlements` — app Debug config (`CODE_SIGN_ENTITLEMENTS`,
  pbxproj near line 925). This is what the owner's installed build is signed
  with.
- `App/App.entitlements` — app Release config (pbxproj near line 989).
- `App/App.CI.entitlements` — substituted by `.github/workflows/ci.yml:34`.

`App/App.entitlements` in full (the other two are the same minus the keys
noted below):

```xml
<!-- App/App.entitlements:5-35 -->
	<key>com.apple.developer.weatherkit</key>                 <!-- KEEP (Release file only) -->
	<true/>
	<key>keychain-access-groups</key>                         <!-- KEEP (absent from the CI file) -->
	<array>
		<string>$(AppIdentifierPrefix)co.dododo.iMCP</string>
	</array>
	<key>com.apple.security.automation.apple-events</key>     <!-- KEEP -->
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>   <!-- DELETE: sandbox-only -->
	<true/>
	<key>com.apple.security.inherit</key>                          <!-- DELETE: sandbox-only -->
	<true/>
	<key>com.apple.security.personal-information.health</key>      <!-- DELETE: no HealthKit use -->
	<true/>
	<key>com.apple.security.personal-information.photos-library</key>  <!-- KEEP -->
	<true/>
	<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>  <!-- DELETE: sandbox-only -->
	<array>
		<string>/Users/*/Library/Messages/</string>
		<string>/Users/*/Library/Application Support/CallHistoryDB/</string>
		<string>/Users/*/Library/Application Support/Knowledge/</string>
		<string>/Users/*/Library/Group Containers/group.com.apple.usernoted/</string>
		<string>/Users/*/Library/Safari/</string>
		<string>/Users/*/Library/Application Support/Google/Chrome/</string>
		<string>/Users/*/Library/Application Support/Arc/</string>
	</array>
	<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>         <!-- DELETE: Sparkle XPC names -->
	<array>
		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
	</array>
```

(The `<!-- ... -->` annotations above are this plan's; the files have no
comments.) Per file, the five keys to delete sit at:

| File | user-selected | inherit | health | files.absolute-path (key + 9-line array) | mach-lookup (key + 4-line array) |
|---|---|---|---|---|---|
| `App/App.entitlements` | 13-14 | 15-16 | 17-18 | 21-30 | 31-35 |
| `App/App.Debug.entitlements` | 11-12 | 13-14 | 15-16 | 19-28 | 29-33 |
| `App/App.CI.entitlements` | 7-8 | 9-10 | 11-12 | 15-24 | 25-29 |

That is 21 lines per file, 63 in total.

Why each is dead:

- `files.user-selected.read-write`, `inherit`, and both `temporary-exception.*`
  keys are App Sandbox entitlements. They only modify a sandbox, and this app
  has none. The app reads `~/Library/Messages` and the other six paths through
  Full Disk Access, a user-granted TCC permission, not through these keys.
- `personal-information.health`: `git grep -n -i 'healthkit\|HKHealthStore' -- '*.swift'`
  returns nothing.
- `-spks` / `-spki` are Sparkle's XPC service names (Group C).

A build setting also asks Xcode for the user-selected-files entitlement, once
in each app configuration (Debug near pbxproj line 941, Release near 1009):

```
				ENABLE_USER_SELECTED_FILES = readwrite;
```

`Scripts/verify-app-signing.sh` asserts one of the keys being deleted:

```bash
# Scripts/verify-app-signing.sh:56-58
assert_true_entitlement "com.apple.security.automation.apple-events"
assert_true_entitlement "com.apple.security.files.user-selected.read-write"
assert_true_entitlement "com.apple.security.personal-information.photos-library"
```

`Scripts/install-local.sh` calls that script, so the entitlement and the
assertion must go in the same commit or the next local install fails.

What keeps permissions working after this change, and why this is still a
human-verified step: macOS identifies the app for privacy (TCC) grants by its
designated requirement (bundle identifier + signing team), which entitlements
are not part of; Keychain access rides on `keychain-access-groups`, which is
kept. So grants and the stored iCloud session should survive. "Should" is not
proof, and an agent must not run the installer or change privacy settings, so
the owner confirms it on the installed build (HUMAN STEP after Step 4).

### Group E — iOS and visionOS settings on a macOS-only target

Both app configurations declare `SUPPORTED_PLATFORMS = macosx;` and
`SUPPORTS_MACCATALYST = NO;`, yet each also carries this block (Debug near
pbxproj lines 956-966 and 979; Release near 1024-1034 and 1048):

```
				"INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UIStatusBarStyle[sdk=iphoneos*]" = UIStatusBarStyleDefault;
				"INFOPLIST_KEY_UIStatusBarStyle[sdk=iphonesimulator*]" = UIStatusBarStyleDefault;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				IPHONEOS_DEPLOYMENT_TARGET = 18.2;
```

and, a few lines further down in the same configuration:

```
				XROS_DEPLOYMENT_TARGET = 2.2;
```

12 lines per configuration, 24 in total. Confirm the count before editing:

```console
$ grep -c 'INFOPLIST_KEY_UI\|IPHONEOS_DEPLOYMENT_TARGET\|XROS_DEPLOYMENT_TARGET' iMCP.xcodeproj/project.pbxproj
24
```

### Group F — duplicate and never-imported linked products

**MCP linked four times in the app.** The app target's Frameworks phase
(`F8F44E6A2D59038D0075D79C`):

```
// iMCP.xcodeproj/project.pbxproj, near lines 246-261
			files = (
				B0SRP0030000000000000003 /* SRP in Frameworks */,
				F809556E2D7888920055B911 /* TypedStream in Frameworks */,
				F87796FC2E0764AE00328CC6 /* MenuBarExtraAccess in Frameworks */,
				F873F48D2D712BCF0035CD0A /* Ontology in Frameworks */,
				F8D7C31A2DCBD32100A4775F /* MCP in Frameworks */,
				F8A7DE3E2DCB76F700530587 /* MCP in Frameworks */,
				F8F1D2F82D6F9E0C00F6323D /* MCP in Frameworks */,
				F8D7C3172DCBD30500A4775F /* MCP in Frameworks */,
				F80955702D7888920055B911 /* iMessage in Frameworks */,
				F8D8C48E2DCE0E6800369E5C /* JSONSchema in Frameworks */,
			);
```

Only one of the four product dependencies is bound to the `swift-sdk` package;
the other three are leftovers with no `package =` line:

```
		F8D7C3192DCBD32100A4775F /* MCP */ = {          <- KEEP (and its build file F8D7C31A...)
			isa = XCSwiftPackageProductDependency;
			package = F8D7C3182DCBD32100A4775F /* XCRemoteSwiftPackageReference "swift-sdk" */;
			productName = MCP;
		};
		F8A7DE3D2DCB76F700530587 /* MCP */ = {          <- DELETE (build file F8A7DE3E...)
			isa = XCSwiftPackageProductDependency;
			productName = MCP;
		};
		F8D7C3162DCBD30500A4775F /* MCP */ = {          <- DELETE (build file F8D7C317...)
			isa = XCSwiftPackageProductDependency;
			productName = MCP;
		};
		F8F44E9C2D5903F70075D79C /* MCP */ = {          <- DELETE (build file F8F1D2F8...)
			isa = XCSwiftPackageProductDependency;
			productName = MCP;
		};
```

Two other MCP product dependencies exist and are **not** part of this plan:
`F8CE997A2D591CF200C61CA2` (the `imcp-server` CLI's only MCP link) and
`B0CAFE060000000000000006` (the `imcp-serverTests` target's).

**`TypedStream` on the app, `UnixSignals` on the CLI: linked, never imported.**

```console
$ git grep -n -i 'import TypedStream\|import UnixSignals' -- '*.swift'
$                       # no output
```

The app imports `iMessage` (one file), which comes from the same `madrid`
package and brings `TypedStream` in as its own dependency. The CLI imports
`ServiceLifecycle`, which brings `UnixSignals` in the same way. Removing the
direct links changes nothing that is compiled.

Every pbxproj line that mentions an object to delete (10 IDs, 12 single lines
plus 5 blocks):

```console
$ grep -n 'F8A7DE3D\|F8D7C316\|F8F44E9C\|F8A7DE3E\|F8D7C317\|F8F1D2F8\|F809556D\|F809556E\|F825BDC0\|F825BDC1' iMCP.xcodeproj/project.pbxproj
62:   F809556E... /* TypedStream in Frameworks */ = {isa = PBXBuildFile; productRef = F809556D... };
65:   F825BDC1... /* UnixSignals in Frameworks */ = {isa = PBXBuildFile; productRef = F825BDC0... };
70:   F8A7DE3E... /* MCP in Frameworks */ = {isa = PBXBuildFile; productRef = F8A7DE3D... };
72:   F8D7C317... /* MCP in Frameworks */ = {isa = PBXBuildFile; productRef = F8D7C316... };
75:   F8F1D2F8... /* MCP in Frameworks */ = {isa = PBXBuildFile; productRef = F8F44E9C... };
251:  F809556E... /* TypedStream in Frameworks */,          (app Frameworks phase)
255:  F8A7DE3E... /* MCP in Frameworks */,                  (app Frameworks phase)
256:  F8F1D2F8... /* MCP in Frameworks */,                  (app Frameworks phase)
257:  F8D7C317... /* MCP in Frameworks */,                  (app Frameworks phase)
270:  F825BDC1... /* UnixSignals in Frameworks */,          (CLI Frameworks phase)
467:  F8F44E9C... /* MCP */,                                (app packageProductDependencies)
469:  F809556D... /* TypedStream */,                        (app packageProductDependencies)
471:  F8A7DE3D... /* MCP */,                                (app packageProductDependencies)
472:  F8D7C316... /* MCP */,                                (app packageProductDependencies)
502:  F825BDC0... /* UnixSignals */,                        (CLI packageProductDependencies)
1231: F809556D... /* TypedStream */ = {    5-line block: isa, package, productName, };
1246: F825BDC0... /* UnixSignals */ = {    5-line block: isa, package, productName, };
1266: F8A7DE3D... /* MCP */ = {            4-line block: isa, productName, };
1274: F8D7C316... /* MCP */ = {            4-line block: isa, productName, };
1293: F8F44E9C... /* MCP */ = {            4-line block: isa, productName, };
```

(IDs abbreviated above for width; the real output shows full 24-character IDs.
The `grep` currently prints exactly 20 lines.)

### Group G — a Swift function only tests call

`App/Models/AlwaysOnService.swift` has the real logic in `setEnabled` (`:33-51`)
and, separately, a pure function that describes the same decisions as data:

```swift
// App/Models/AlwaysOnService.swift:3-7
enum AlwaysOnRegistrationAction: Equatable {
    case unregisterMainApp
    case registerAgent
    case unregisterAgent
}
```

```swift
// App/Models/AlwaysOnService.swift:53-63
    static func registrationActions(
        enabled: Bool,
        mainAppEnabled: Bool,
        agentEnabled: Bool
    ) -> [AlwaysOnRegistrationAction] {
        if enabled {
            guard !agentEnabled else { return [] }
            return (mainAppEnabled ? [.unregisterMainApp] : []) + [.registerAgent]
        }
        return agentEnabled ? [.unregisterAgent] : []
    }
```

`setEnabled` does not call it. Nothing in production does:

```console
$ git grep -n 'registrationActions\|AlwaysOnRegistrationAction' -- App CLI AlwaysOnHelper
App/Models/AlwaysOnService.swift:3:enum AlwaysOnRegistrationAction: Equatable {
App/Models/AlwaysOnService.swift:53:    static func registrationActions(
App/Models/AlwaysOnService.swift:57:    ) -> [AlwaysOnRegistrationAction] {
```

Its only callers are three tests in `iMCPTests/AlwaysOnServiceTests.swift:15-38`
(`testEnablingReplacesLaunchAtLoginBeforeRegisteringAgent`,
`testEnablingWithoutLaunchAtLoginOnlyRegistersAgent`,
`testDisablingOnlyUnregistersEnabledAgent`). Those tests pass no matter what
`setEnabled` does, so they verify a model the app never consults. The first
test in that class, `testAlwaysOnReportsLaunchAtLoginAsEnabled` (`:6-13`),
exercises `effectiveLaunchAtLogin`, which `App/Views/SettingsView.swift:386`
does call; it stays. The second class in the file, `AlwaysOnCommandLineTests`
(`:41-66`), is untouched.

### What the fresh dead-code pass found (so nobody repeats it)

A scan of every `func`/`var`/`let`/type declaration in `App/`, `CLI/`, and
`AlwaysOnHelper/` for names that occur nowhere else in production code turned
up, besides Group G, only items that another plan owns or that are live:

- Owned elsewhere, do not touch here: `ICloudSession.invalidate` (plan 045);
  `Logger.integration` and `readLibraryArchive` (plan 049);
  `LocationSampler.reconciledGeneration` (plan 047);
  `testRegisterConnectionForTesting`, `testSetPreAuthenticatedForTesting`,
  `isPreAuthenticated` (plan 037); `resolveToolDefinition`,
  `callToolUnavailableText` (plan 042); `FindMyPeopleBootstrap.encodePayload`
  (plan 046's area).
- Live although the name appears once (called by a framework, not by name):
  `applicationDidFinishLaunching`, `applicationShouldHandleReopen`
  (`App/App.swift`), `buildBlock` (result builder, `App/Models/Service.swift`),
  `urlSession` (URLSession delegate, `App/Services/Location/ICloudHTTP.swift`),
  `makeBody` (ButtonStyle, `App/Views/ContentView.swift`).

### Conventions

- `swift format`: 4-space indent, 120-column limit; lint must pass strict.
- Tests are plain `XCTest`. This plan adds no test file and no pbxproj test
  entries.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 (`-quiet` prints nothing on success) |
| Plist syntax | `plutil -lint <file>` | `<file>: OK` |
| All tests | `Scripts/test.sh` | all pass, exit 0 |
| App tests only | `Scripts/test.sh --app-only` | all pass, exit 0 |
| One test class | `Scripts/test.sh --only iMCPTests/AlwaysOnServiceTests` | all pass, exit 0 |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`Scripts/test.sh --only SPEC` passes `-only-testing:SPEC` to xcodebuild and
implies the app suite only. `Scripts/test.sh` stops the installed app and its
watchdog for the duration and restores both on exit.

**Never** run `xcodebuild test -scheme iMCP` directly (the always-on watchdog
relaunches the installed app and breaks the test host). **Never**
`launchctl bootout` the always-on agent. **Never** run `Scripts/install-local.sh`,
`Scripts/ship.sh`, or `Scripts/release.sh` in this plan.

## Scope

**In scope** (the only files you should modify or delete):
- `iMCP.xcodeproj/xcuserdata/**` (3 tracked files — untrack)
- `Scripts/measure-runtime-efficiency.py` (delete)
- `Scripts/measure-mcp-client.sh` (delete)
- `Scripts/bench-mcp-client.mjs` (delete)
- `Scripts/find-my-people-key.py` (delete — the **dashed** name)
- `docs/solutions/performance/tool-payload-context-cost.md` (one sentence)
- `App/Info.plist`
- `App/App.entitlements`, `App/App.Debug.entitlements`, `App/App.CI.entitlements`
- `Scripts/verify-app-signing.sh` (one line removed)
- `iMCP.xcodeproj/project.pbxproj`
- `App/Models/AlwaysOnService.swift`
- `iMCPTests/AlwaysOnServiceTests.swift`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `Scripts/find_my_people_key.py` (underscores) — live LLDB module.
- Entitlements to KEEP: `com.apple.security.automation.apple-events`,
  `com.apple.security.personal-information.photos-library`,
  `com.apple.developer.weatherkit`, `keychain-access-groups`. Removing any of
  them breaks Notes automation, Photos, Weather, or the stored iCloud session.
- Any other build setting, including `AUTOMATION_APPLE_EVENTS`,
  `ENABLE_RESOURCE_ACCESS_*`, `ENABLE_HARDENED_RUNTIME`, `SDKROOT = auto`,
  `LD_RUNPATH_SEARCH_PATHS`, and the `WEATHERKIT_AVAILABLE` flag.
- The CLI's MCP link (`F8CE997A2D591CF200C61CA2`) and the CLI test target's
  (`B0CAFE060000000000000006`).
- The empty `ListPrompts` / `ListResources` handlers in
  `App/Controllers/ServerNetworkManager.swift` — clients may call them.
- The UserDefaults-to-Keychain pairing migration and the Debug iCloud
  credential migration — deleting either risks the owner's pairing or session.
- Every dead declaration listed under "Owned elsewhere" above.
- `docs/plans/2026-08-24-0109-feat-find-my-people-plan.md:259` — a dated
  historical file list; plan 053 owns doc accuracy.
- Other edits to `Scripts/verify-app-signing.sh` (plan 050 refactors it) and
  anything in `.github/workflows/` (plan 052).

## Git workflow

- Branch from an up-to-date `main`: `advisor/051-deletion-sweep`.
- One commit per step that changes files (Steps 1-7), conventional-commit
  style as used in this repo (`fix: bring Settings forward from the menu; stay
  quiet on relaunch`). Suggested subjects are given in each step.
- Do NOT push or open a PR unless the operator says so. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream` (`mattt/iMCP`)
  must never receive pushes or PRs.

## Steps

Ordered lowest risk first. Build after every group that can affect the build.

### Step 1: Untrack the three `xcuserdata` files

```console
git rm --cached -r iMCP.xcodeproj/xcuserdata
```

`--cached` removes them from the index and leaves the working copies on disk,
where `.gitignore:6` already hides them. Do not edit `.gitignore`.

**Verify**:
```console
git ls-files | grep -c xcuserdata
git status --short | grep -c '^D  iMCP.xcodeproj/xcuserdata'
```
→ `0`, then `3`.

Commit: `chore: stop tracking Xcode user data`.

### Step 2: Delete the four orphan scripts and fix the one doc reference

```console
git rm Scripts/measure-runtime-efficiency.py Scripts/measure-mcp-client.sh Scripts/bench-mcp-client.mjs Scripts/find-my-people-key.py
```

Then in `docs/solutions/performance/tool-payload-context-cost.md:58-59`,
replace

```markdown
Installed app, same enabled services, measured with
`Scripts/bench-mcp-client.mjs` and direct tool calls:
```

with

```markdown
Installed app, same enabled services, measured with a since-removed client
benchmark (use `Scripts/measure-full-stack-performance.sh` now) and direct tool calls:
```

Change nothing else in that document; the table below it is a historical
record.

**Verify**:
```console
git grep -n 'measure-runtime-efficiency\|measure-mcp-client\|bench-mcp-client\|find-my-people-key' -- . ':!plans' ':!docs/plans'
ls Scripts/find_my_people_key.py Scripts/measure-full-stack-performance.sh Scripts/bench-full-stack-performance.mjs
```
→ first command prints nothing (exit 1); second lists all three files.

Commit: `chore: delete orphaned measurement scripts and the find-my-people-key shim`.

### Step 3: Remove the three Sparkle keys from `App/Info.plist`

Delete lines 11-16 (the `SUEnableInstallerLauncherService`, `SUFeedURL`, and
`SUPublicEDKey` keys, each with its value line). The `<dict>` must end up
containing exactly `LSMultipleInstancesProhibited` and `NSBonjourServices`.

**Verify**:
```console
plutil -lint App/Info.plist
grep -c '<key>' App/Info.plist
grep -c 'SU' App/Info.plist
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `App/Info.plist: OK`, `2`, `0`, `exit=0`.

Commit: `chore: remove Sparkle keys from Info.plist`.

### Step 4: Remove dead entitlements, the matching build setting, and the script assertion

All in one commit — they must land together.

1. In each of `App/App.entitlements`, `App/App.Debug.entitlements`, and
   `App/App.CI.entitlements`, delete the five keys with their values (21 lines
   per file; positions in the table under Group D):
   - `com.apple.security.files.user-selected.read-write` + `<true/>`
   - `com.apple.security.inherit` + `<true/>`
   - `com.apple.security.personal-information.health` + `<true/>`
   - `com.apple.security.temporary-exception.files.absolute-path.read-only` +
     its whole `<array>…</array>` (7 strings)
   - `com.apple.security.temporary-exception.mach-lookup.global-name` + its
     whole `<array>…</array>` (2 strings)

   Target content of `App/App.Debug.entitlements` `<dict>` afterwards (the
   Release file additionally starts with the `com.apple.developer.weatherkit`
   key; the CI file has no `keychain-access-groups` key):

   ```xml
   <dict>
   	<key>keychain-access-groups</key>
   	<array>
   		<string>$(AppIdentifierPrefix)co.dododo.iMCP</string>
   	</array>
   	<key>com.apple.security.automation.apple-events</key>
   	<true/>
   	<key>com.apple.security.personal-information.photos-library</key>
   	<true/>
   </dict>
   ```

2. In `iMCP.xcodeproj/project.pbxproj`, delete both lines that read exactly
   `ENABLE_USER_SELECTED_FILES = readwrite;` (one in the app Debug
   configuration, one in the app Release configuration).

3. In `Scripts/verify-app-signing.sh`, delete the single line
   `assert_true_entitlement "com.apple.security.files.user-selected.read-write"`.
   Find it with `grep -n 'user-selected' Scripts/verify-app-signing.sh` (plan
   050 may have moved it). Leave the `apple-events` and `photos-library`
   assertions on either side of it. Do not run the script.

**Verify (files)**:
```console
for f in App/App.entitlements App/App.Debug.entitlements App/App.CI.entitlements; do plutil -lint "$f"; grep -c '<key>' "$f"; done
git grep -n 'user-selected\|security\.inherit\|personal-information\.health\|temporary-exception\|USER_SELECTED' -- App Scripts iMCP.xcodeproj .github
plutil -lint iMCP.xcodeproj/project.pbxproj
bash -n Scripts/verify-app-signing.sh ; echo "syntax=$?"
```
→ each file `OK`; key counts `4` (`App.entitlements`), `3`
(`App.Debug.entitlements`), `2` (`App.CI.entitlements`); the `git grep` prints
nothing; `project.pbxproj: OK`; `syntax=0`. (`bash -n` only parses the script;
it executes nothing.)

**Verify (signed build product — read-only inspection of the build output, not
of `/Applications`)**:
```console
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
BUILT="$(xcodebuild -scheme iMCP -configuration Debug -destination "platform=macOS" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
ENT="$(codesign -d --entitlements - --xml "$BUILT/iMCP.app" 2>/dev/null | plutil -p -)"
echo "$ENT" | grep -c 'security\.inherit\|personal-information\.health\|temporary-exception'
echo "$ENT" | grep -c 'automation\.apple-events\|photos-library\|keychain-access-groups'
echo "$ENT" | grep -c 'user-selected'
```
→ `exit=0`; first count `0`; second count `3`; third count `0`. (`plutil -p`
prints one entitlement key per line; if `$ENT` is empty, the build product was
not found — STOP.)

If the third count is `1` (Xcode still synthesises the user-selected
entitlement from some other setting), do **not** go looking for the setting:
record that fact in your report and continue. The key is a no-op without a
sandbox and nothing asserts it any more. Any other mismatch is a STOP
condition.

Commit: `chore: drop sandbox-only and unused entitlements`.

**HUMAN STEP (not for the executor)**: after this plan is merged and the owner
next installs a build, the owner confirms on the installed app that (a) the
iCloud session is still signed in without re-entering the password, (b) a
paired client still connects without a new approval prompt, and (c) one tool
from each permission family still returns data: Messages or Safari history
(Full Disk Access), Notes (Automation), Photos, Contacts, Calendar. Say so in
your final report. Do not attempt this yourself, do not run
`Scripts/install-local.sh`, and do not open System Settings.

### Step 5: Remove the iOS and visionOS build settings from the app target

In `iMCP.xcodeproj/project.pbxproj`, in **both** app configurations
(`F8F44E932D59038E0075D79C /* Debug */` and `F8F44E942D59038E0075D79C /* Release */`),
delete the 12 lines quoted under Group E: the eight
`"INFOPLIST_KEY_UI…[sdk=iphone…]"` lines, the two
`INFOPLIST_KEY_UISupportedInterfaceOrientations_…` lines,
`IPHONEOS_DEPLOYMENT_TARGET = 18.2;`, and `XROS_DEPLOYMENT_TARGET = 2.2;`.
Leave `MACOSX_DEPLOYMENT_TARGET`, `SDKROOT`, `SUPPORTED_PLATFORMS`,
`SUPPORTS_MACCATALYST`, and both `LD_RUNPATH_SEARCH_PATHS` lines as they are.

**Verify**:
```console
grep -c 'INFOPLIST_KEY_UI\|IPHONEOS_DEPLOYMENT_TARGET\|XROS_DEPLOYMENT_TARGET' iMCP.xcodeproj/project.pbxproj
grep -c 'MACOSX_DEPLOYMENT_TARGET = 15.1;' iMCP.xcodeproj/project.pbxproj
plutil -lint iMCP.xcodeproj/project.pbxproj
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `0`; the second count is unchanged from before the edit (run it once before
editing and note the number); `project.pbxproj: OK`; `exit=0`.

Commit: `chore: remove iOS and visionOS build settings from the macOS app target`.

### Step 6: Remove the duplicate MCP links and the two never-imported products

In `iMCP.xcodeproj/project.pbxproj`, delete every line and block listed in the
`grep` output under Group F — and nothing else:

- 5 `PBXBuildFile` lines: `F809556E…` (TypedStream), `F825BDC1…` (UnixSignals),
  `F8A7DE3E…`, `F8D7C317…`, `F8F1D2F8…` (MCP ×3).
- 4 entries in the app Frameworks phase `F8F44E6A2D59038D0075D79C`
  (TypedStream + MCP ×3) and 1 in the CLI Frameworks phase
  `F8F44EB32D5908D00075D79C` (UnixSignals).
- 4 entries in the app target's `packageProductDependencies` (`F8F44E9C…`,
  `F809556D…`, `F8A7DE3D…`, `F8D7C316…`) and 1 in the CLI target's
  (`F825BDC0…`).
- 5 `XCSwiftPackageProductDependency` blocks: `F809556D…` (TypedStream, 5
  lines), `F825BDC0…` (UnixSignals, 5 lines), `F8A7DE3D…`, `F8D7C316…`,
  `F8F44E9C…` (MCP, 4 lines each).

After the edit the app Frameworks phase must read exactly:

```
			files = (
				B0SRP0030000000000000003 /* SRP in Frameworks */,
				F87796FC2E0764AE00328CC6 /* MenuBarExtraAccess in Frameworks */,
				F873F48D2D712BCF0035CD0A /* Ontology in Frameworks */,
				F8D7C31A2DCBD32100A4775F /* MCP in Frameworks */,
				F80955702D7888920055B911 /* iMessage in Frameworks */,
				F8D8C48E2DCE0E6800369E5C /* JSONSchema in Frameworks */,
			);
```

and the CLI Frameworks phase:

```
			files = (
				F88358372D64A085000317CD /* Logging in Frameworks */,
				F825BDBF2D9AD00E0063ADD7 /* ServiceLifecycle in Frameworks */,
				F8CE997B2D591CF200C61CA2 /* MCP in Frameworks */,
			);
```

Do not delete any `XCRemoteSwiftPackageReference` (the `madrid` and
`swift-service-lifecycle` packages are still used via `iMessage` and
`ServiceLifecycle`).

**Verify**:
```console
grep -c 'F8A7DE3D\|F8D7C316\|F8F44E9C\|F8A7DE3E\|F8D7C317\|F8F1D2F8\|F809556D\|F809556E\|F825BDC0\|F825BDC1' iMCP.xcodeproj/project.pbxproj
grep -c 'TypedStream\|UnixSignals' iMCP.xcodeproj/project.pbxproj
grep -c '/\* MCP in Frameworks \*/ = ' iMCP.xcodeproj/project.pbxproj
grep -c 'F8D7C319\|F8D7C31A\|F8CE997A\|F8CE997B\|B0CAFE05\|B0CAFE06' iMCP.xcodeproj/project.pbxproj
plutil -lint iMCP.xcodeproj/project.pbxproj
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
git status --short
```
→ `0`; `0`; `3` (app, CLI, CLI tests); the fourth count is unchanged from
before the edit (run it once before editing and note the number);
`project.pbxproj: OK`; `exit=0`; and `git status --short` shows
`project.pbxproj` as the only modified file — in particular **no** change to
any `Package.resolved`.

Commit: `chore: unlink duplicate MCP products and unused TypedStream/UnixSignals`.

### Step 7: Delete the test-only `registrationActions` and its three tests

1. `App/Models/AlwaysOnService.swift`: delete the
   `enum AlwaysOnRegistrationAction` declaration (`:3-7`) and the blank line
   after it, and delete `static func registrationActions(...)` (`:53-63`) and
   the blank line before it. The file then starts with
   `import ServiceManagement`, a blank line, `enum AlwaysOnService {`, and ends
   with `setEnabled`'s closing brace followed by the enum's closing brace.
   `agentPlistName`, `agent`, `isEnabled`, `effectiveLaunchAtLogin`, and
   `setEnabled` are unchanged.
2. `iMCPTests/AlwaysOnServiceTests.swift`: in `AlwaysOnServiceTests`, delete
   `testEnablingReplacesLaunchAtLoginBeforeRegisteringAgent`,
   `testEnablingWithoutLaunchAtLoginOnlyRegistersAgent`, and
   `testDisablingOnlyUnregistersEnabledAgent` (`:15-38`). Keep
   `testAlwaysOnReportsLaunchAtLoginAsEnabled` and the whole
   `AlwaysOnCommandLineTests` class.

**Verify**:
```console
git grep -n 'registrationActions\|AlwaysOnRegistrationAction' -- '*.swift'
grep -c 'func test' iMCPTests/AlwaysOnServiceTests.swift
swift format -i -r . && swift format lint --strict --recursive . ; echo "lint=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/AlwaysOnServiceTests ; echo "tests=$?"
```
→ first command prints nothing; `5` (1 + 4); `lint=0`; `exit=0`; `tests=0`.
`swift format -i` must not have modified any file other than the two you
edited (`git status --short`); if it did, that is pre-existing drift — revert
those other files with `git checkout -- <file>` and continue.

Commit: `refactor: delete test-only AlwaysOnService.registrationActions`.

### Step 8: Full gate

```console
swift format lint --strict --recursive . ; echo "lint=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "build=$?"
Scripts/test.sh ; echo "tests=$?"
git diff --stat main..HEAD | tail -1
```

**Verify**: `lint=0`, `build=0`, `tests=0`; the last line reports deletions far
exceeding insertions (roughly 600 deletions, under 10 insertions).

## Test plan

- **No new tests.** This plan only deletes; nothing new exists to cover.
- **Tests removed**: three in `iMCPTests/AlwaysOnServiceTests.swift` that
  exercised only the deleted `registrationActions` (Step 7). Coverage of real
  behaviour is unchanged because production never called that function.
- **Regression gate**: the existing suites via `Scripts/test.sh` (app and CLI).
  The app suite going green after Steps 4-6 is the evidence that the
  re-signed test host still launches and links.
- **Not covered by automation**: TCC grants and Keychain access on the
  installed build after the entitlement change — the HUMAN STEP after Step 4.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `git ls-files | grep -c xcuserdata` → `0`
- [ ] `ls Scripts/measure-runtime-efficiency.py Scripts/measure-mcp-client.sh Scripts/bench-mcp-client.mjs Scripts/find-my-people-key.py 2>/dev/null | wc -l` → `0`
- [ ] `ls Scripts/find_my_people_key.py` succeeds
- [ ] `git grep -n -i 'sparkle\|SUFeed\|SUPublicEDKey\|SUEnableInstaller\|-spks\|-spki' -- . ':!plans' ':!docs'` prints nothing
- [ ] `git grep -n 'user-selected\|security\.inherit\|personal-information\.health\|temporary-exception\|USER_SELECTED' -- App Scripts iMCP.xcodeproj .github` prints nothing
- [ ] `grep -c 'automation.apple-events' App/App.entitlements App/App.Debug.entitlements App/App.CI.entitlements` → `1` for each file; same for `photos-library`
- [ ] `grep -c 'keychain-access-groups' App/App.entitlements App/App.Debug.entitlements` → `1` each; `grep -c weatherkit App/App.entitlements` → `1`
- [ ] `grep -c 'INFOPLIST_KEY_UI\|IPHONEOS_DEPLOYMENT_TARGET\|XROS_DEPLOYMENT_TARGET\|TypedStream\|UnixSignals' iMCP.xcodeproj/project.pbxproj` → `0`
- [ ] `grep -c '/\* MCP in Frameworks \*/ = ' iMCP.xcodeproj/project.pbxproj` → `3`
- [ ] `plutil -lint iMCP.xcodeproj/project.pbxproj App/Info.plist App/App.entitlements App/App.Debug.entitlements App/App.CI.entitlements` → five `OK` lines
- [ ] `git grep -n 'registrationActions\|AlwaysOnRegistrationAction' -- '*.swift'` prints nothing
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` exits 0
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git diff --name-only main..HEAD` lists only files in the In-scope list
- [ ] `plans/README.md` status row for 051 updated
- [ ] Final report states the HUMAN STEP is outstanding

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" `grep` in this plan returns something different from
  what is shown (other than shifted pbxproj line numbers) — for example a new
  caller of one of the four scripts, a Swift file that now imports
  `TypedStream`, `UnixSignals`, HealthKit, or Sparkle, or a production caller
  of `registrationActions`.
- `plutil -lint iMCP.xcodeproj/project.pbxproj` reports anything but `OK` and
  one careful re-check of your edit does not fix it. Restore the file with
  `git checkout -- iMCP.xcodeproj/project.pbxproj` and report; do not open the
  project in Xcode to "repair" it.
- After Step 6 the build fails with a missing-module or undefined-symbol
  error, or `git status` shows a `Package.resolved` change. Revert Step 6 and
  report which product was actually needed.
- After Step 4 the signed build product is missing `automation.apple-events`,
  `photos-library`, or `keychain-access-groups`, or still contains `inherit`,
  `personal-information.health`, or a `temporary-exception` key.
- After Steps 4-6 the app test suite fails to launch its test bundle (as
  opposed to an individual test failing) twice in a row through
  `Scripts/test.sh`.
- Any step seems to require running `Scripts/install-local.sh`,
  `Scripts/verify-app-signing.sh`, `Scripts/ship.sh`, touching
  `/Applications/iMCP.app`, the always-on LaunchAgent, System Settings, or any
  password prompt. Those are human-only.
- You find yourself wanting to delete a KEEP item (see Out of scope) or any
  dead declaration owned by another plan.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **Do not install as part of this plan.** `Scripts/install-local.sh run` is
  the normal final local-dev command, but the executor must not run it unless
  the operator asks. The first install after this lands is where the HUMAN
  STEP check happens. If a grant or the iCloud session is lost, revert the
  Step 4 commit alone; every step is its own commit for exactly this reason.
- **Reviewer focus**: (1) the three entitlements files still contain every
  KEEP key; (2) the pbxproj diff is deletions only, with the kept MCP product
  being the one that has `package = … "swift-sdk"`; (3) `find_my_people_key.py`
  (underscores) is untouched.
- **Plan 050** refactors `Scripts/verify-app-signing.sh` and **plan 052** adds
  script linting in CI and a Release build. Either order works with this plan,
  but 052 should run after it so CI lints only scripts that still exist and
  the Release build exercises the trimmed `App/App.entitlements`. Release is
  the only configuration that compiles Weather registration
  (`WEATHERKIT_AVAILABLE`), which is why that flag and the weatherkit
  entitlement are kept.
- **Rejected, recorded so they are not re-audited**: the empty
  `ListPrompts`/`ListResources` handlers (clients may call them); the
  UserDefaults-to-Keychain pairing migration and the Debug iCloud credential
  migration (deleting risks the owner's pairing or session);
  `WEATHERKIT_AVAILABLE`.
- **Deferred, not done here**: the app target still has `SDKROOT = auto` and an
  unconditional `LD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks"` next
  to the macOS-conditional one — also multi-platform template leftovers, left
  alone because changing a search path is not a pure deletion. The CLI's MCP
  product dependency (`F8CE997A…`) has no `package =` binding and resolves by
  name; it works, and rebinding it is an edit, not a deletion.
  `AUTOMATION_APPLE_EVENTS = YES` duplicates the `automation.apple-events`
  entitlement key; left alone because that entitlement is load-bearing for
  Notes.
- **If auto-update is ever added**, the Sparkle keys and the `-spks`/`-spki`
  mach-lookup names only matter for a sandboxed app; an unsandboxed app needs
  just `SUFeedURL` and `SUPublicEDKey` in `Info.plist` plus the package.
