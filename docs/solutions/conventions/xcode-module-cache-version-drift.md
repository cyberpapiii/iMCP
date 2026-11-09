---
title: Never restore Clang module caches across Xcode patch versions
date: 2026-11-05
category: conventions
module: ci
problem_type: build_failure
component: github-actions-cache
severity: medium
applies_when:
  - GitHub replaces an Xcode patch release without changing the workflow label
  - Clang says module.modulemap changed since a cached pcm was built
  - Source and Debug tests pass while a cached Release build fails
tags:
  - github-actions
  - xcode
  - clang
  - cache
---

# Never restore Clang module caches across Xcode patch versions

## Problem

GitHub's `macos-26` image replaced Xcode 26.0 with 26.0.1 while the workflow's
cache key still said `xcode-26.0`. Restoring `DerivedData/ModuleCache.noindex`
then made Clang reject its own `.pcm` files because the toolchain
`module.modulemap` timestamp changed.

## Solution

Keep reusable DerivedData build products, but exclude
`DerivedData/ModuleCache.noindex` from every cache path
(`!…/ModuleCache.noindex`). Compiler modules are toolchain internals;
rebuilding them is cheap and avoids coupling cache correctness to GitHub's
mutable runner images.

Keying the cache on the exact Xcode build is not enough: on 2026-11-06 the
runner image refreshed the macOS SDK under the same Xcode 26.0.1 build and
Clang rejected cached modules because `AvailabilityVersions.h` "has been
modified since the module file was built".

## Recognition

The first error says a toolchain file "has been modified since the module file
was built" and asks to rebuild a `.pcm`. This is cache poisoning, not a source
or signing failure.
