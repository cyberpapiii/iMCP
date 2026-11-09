---
title: Service toggles in the menu did not redraw when clicked
date: 2026-10-09
category: ui-bugs
module: menu-bar-service-toggles
problem_type: ui_bug
component: swiftui-menu
severity: medium
applies_when:
  - Caching a value that SwiftUI views read during body evaluation
  - Storing a Binding anywhere that outlives one body evaluation
  - A ForEach over cached data does not refresh its rows
  - Publishing changes by hand with objectWillChange
tags:
  - swiftui
  - binding
  - foreach
  - observableobject
  - userdefaults
  - menubarextra
---

# Service toggles in the menu did not redraw when clicked

## Problem

Clicking a service icon in the menu-bar window changed the stored setting, but
the icon kept its old color until the app was restarted. The Status rows and
the server's set of enabled services read the same stale value, so they lagged
too.

## What was wrong

Three faults were stacked, and fixing any one alone changed nothing visible.

1. **A cached `Binding` reads stale inside a view update.** `ServiceConfig`
   held a `Binding<Bool>` built with `Binding(get:set:)`, and the configs are
   cached for the controller's lifetime. A `Binding` read while SwiftUI is
   evaluating bodies returns the value it held when the binding was created,
   not the result of calling `get` again. Read from a button action it is live;
   read from `body` it is frozen. Logging showed a click handler reading
   `false` and the parent body reading `true` one millisecond later.
2. **A `ForEach` whose closure captures nothing new is skipped.** The row
   closure only used its `config` argument. With cached data and an unchanged
   closure, the new `ForEach` value was identical to the old one, so SwiftUI
   never called the closure again and the rows kept their old inputs.
3. **The setter notified before it wrote.** `objectWillChange.send()` ran
   before `UserDefaults.standard.set`. A view that re-read promptly could see
   the old value.

## Fix

- `ServiceConfig.isEnabled` (now `ServiceSwitch.isEnabled`) reads and writes
  through plain closures over `UserDefaults` (`App/Server/ServiceSwitch.swift`).
  No `Binding` is
  stored.
- `ContentView` computes the set of enabled service ids in `body` and the
  `ForEach` closure captures it, so the `ForEach` changes when a toggle does
  (`App/Menu/ContentView.swift`).
- `ServiceToggleView` takes `isOn`, and whether the service can reach its
  data, as inputs from its parent instead of reading them itself
  (`App/Menu/ServiceToggleView.swift`).
- Settings' Service Permissions rows follow the same rule:
  `PermissionsSettingsView` computes the enabled ids in `body` and hands each
  `ServicePermissionRow` its status, made of the switch and
  `AppStatus.serviceAccess` (`App/Settings/SettingsView.swift`).
- The setter writes, then notifies (`App/Server/ServerController.swift`).

## How to recognise it next time

- The stored value is right (`defaults read ~/Library/Preferences/co.dododo.iMCP.plist <key>`)
  and the view is wrong.
- A temporary log line at the top of the parent `body` and the row `body`
  shows which of the two is not running, or is running with an old value.

## Verifying a fix like this

Check with the menu open, one screenshot per click, compared against the stored
value. Reopening the menu or restarting the app rebuilds everything and hides
the bug. Confirm the running process started after the installed binary was
written; the always-on watchdog can relaunch the old binary during a build.
