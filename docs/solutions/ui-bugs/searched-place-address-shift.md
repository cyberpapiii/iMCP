---
title: Searched places must keep the selected Maps coordinate
date: 2026-11-05
category: ui-bugs
module: location-history
problem_type: ui_bug
component: add-place-sheet
severity: medium
applies_when:
  - A searched place saves as a neighboring street number
  - Recorded phone fixes exist near a selected Maps result
  - Reverse geocoding disagrees with the address the user selected
tags:
  - mapkit
  - location-history
  - reverse-geocoding
  - named-places
---

# Searched places must keep the selected Maps coordinate

## Problem

Searching for `6 Orchard St` returned the correct Maps coordinate, but saving
the place moved it to the center of nearby recorded phone fixes. That point was
about 12 meters away and reverse-geocoded as `8 Orchard St`.

The snap was intentional: it tried to represent where the phone usually landed
inside a building. It broke the stronger user contract that choosing an address
saves that address.

## Solution

Search-created places now save the selected `MKMapItem` coordinate unchanged.
Recorded fixes still drive visits and history, but they never move a place the
user created from an address search.

The Places sheet also edits the existing row by id. Name, selected Maps
coordinate, and radius change together without a delete-and-recreate cycle;
the cached reverse-geocoded address is discarded when the coordinate changes.

Keep search-created places separate from visit-created places. Naming a visit
should use the visit center; naming a Maps result should use the result.
"Rename…" on a stop that already has a place renames that row by id
(`LocationHistoryStore.updatePlace`): its center, source, and creation date
stay. Before that fix it saved by name, which either added a second place or
moved the searched place to the visit center and reset its source to
`manual`.

## Verification

- Reproduce with multiple usable phone fixes 60 meters from a search result.
- Save the result and assert the stored latitude and longitude equal the search
  coordinate, not the fix center.
- Reverse-geocode both coordinates when diagnosing neighboring-address reports;
  a small distance can cross Apple's street-number boundary.
