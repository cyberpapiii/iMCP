---
title: The app icon is an Icon Composer document; menu glyphs are plain-path SVGs
date: 2026-11-07
category: conventions
module: app
problem_type: convention
component: assets
severity: low
applies_when:
  - Changing the app icon or a menu bar glyph
  - A menu bar glyph renders blank or wrong after an SVG edit
  - The icon looks right in Icon Composer but wrong in the built app
tags:
  - app-icon
  - liquid-glass
  - menu-bar
  - svg
---

# The app icon is an Icon Composer document; menu glyphs are plain-path SVGs

## The mark

The mark is the ⌘ key with a face: four loops around a square body with two
straight, equal eyes. The eyes are the character, and they change with state:

| State | Asset | Face |
| --- | --- | --- |
| Off | `MenuIcon-Off` (Light and Dark files, 25% opacity) | The bare ⌘ outline, no body |
| On | `MenuIcon-On` | Body with two upright eyes |
| Needs you | `MenuIcon-Attention`, plus the dot `MenuBarIcon` adds | Eyes a little wider and taller |

The app icon is the On face in white Liquid Glass over a blueprint: Apple's
developer-app blue ruled into quarters, like the Developer and Xcode icons.

## App icon

`App/AppIcon.icon` is an Icon Composer document (Xcode 26 and later).
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` resolves to it, and Xcode
builds the Liquid Glass icon plus flat fallbacks for older macOS from it.
There is no `AppIcon.appiconset`; adding one back makes two icons with one name.

Edit it in Icon Composer (inside Xcode.app). It has two groups. The front
group is the glass face; the back group is the flat blueprint (`glass: false`),
so the glass bends the grid lines behind it.

The icon looks the same in light and dark mode on purpose: one background,
no dark variant. Left to itself, macOS tints the face with the background's
blue in dark mode, and the ⌘ almost disappears. So the face has one
`fill-specializations` entry for `dark` that keeps it white. That is the only
appearance rule.

The loops and the face are one layer on purpose. As two glass layers, the
loops show through the translucent body and look like a mistake. To check a change without building, render it
with Apple's own renderer:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  App/AppIcon.icon --export-image --output-file /tmp/icon.png \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

`--rendition` also takes `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and
`TintedDark`. The tinted ones default to a purple tint; pass `--tint-color`
to preview another.

### An installed build can keep showing the old icon

Finder, the Dock and Launchpad cache each app's icon against its bundle's
modification date. A build only changes files inside `Contents`, and `ditto`
keeps the bundle's own date, so after the first new-icon install those places
kept the old knot while `NSWorkspace.icon(forFile:)` already returned the new
one. `Scripts/install-local.sh` now touches the installed bundle. To refresh
by hand:

```sh
touch /Applications/iMCP.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/iMCP.app
killall Dock Finder
```

## Menu glyphs

The glyphs are 16 by 16 template SVGs. Use only plain paths: strokes for the
loops, and one even-odd filled path for the body with the eyes as holes. Do
not use `<mask>` or `<clipPath>`. The asset catalog's renderer is not a browser,
and a glyph that looks right in a browser can come out wrong in the menu bar.

The loops stop inside the body, at 2.9 pt from the centre, so their strokes
never cross the eye holes. The top trailing loop sits where `MenuBarIcon` cuts
the clear ring for the attention dot (centre 12.5, 12.5 in AppKit's y-up
space, ring radius 5). That is intended: in Needs you, the dot replaces that
loop.

`Assets/icon.svg` is the same On glyph, padded to 20 by 16, for `README.md`.
Update it when the On glyph changes.
