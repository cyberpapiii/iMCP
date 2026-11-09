---
title: A CI build without a provisioning profile cannot claim WeatherKit or a keychain group
date: 2026-11-06
category: conventions
module: ci
problem_type: build_failure
component: github-actions
severity: low
applies_when:
  - A CI job signs ad hoc (CODE_SIGN_IDENTITY=-) with no provisioning profile
  - An entitlement is added to App/App.entitlements or App/App.Debug.entitlements
  - Xcode says "iMCP" requires a provisioning profile
tags:
  - github-actions
  - xcode
  - code-signing
  - entitlements
---

# A CI build without a provisioning profile cannot claim WeatherKit or a keychain group

## Problem

CI signs ad hoc and has no provisioning profile, so it swaps in its own
entitlements file (`.build/ci/App.CI.entitlements`). The Release job used to
derive that file from `App.Debug.entitlements`, not from `App.entitlements`,
which is what Release signs with. Deriving it from `App.entitlements` and
dropping only `keychain-access-groups` fails at once:

```
error: "iMCP" requires a provisioning profile. Enable development signing and
select a provisioning profile in the Signing & Capabilities editor.
```

`com.apple.developer.weatherkit` is the cause: Xcode will not sign ad hoc
with it, as it will not with the keychain access group.

## Solution

`.github/actions/prepare-xcode` takes the configuration's own entitlements
file and drops both keys when they are present. Both jobs then sign with
their configuration's entitlements minus what a profile-less build cannot
claim. Today that leaves the same file for both. A new entitlement that needs
a profile joins the list in that action.

Delete the keys with PlistBuddy (`Delete :com.apple.developer.weatherkit`).
`plutil -remove` reads the dots in a key as a key path, so it does not find
the key.
