---
name: tca-store-cancel-scope
description: Read before acting on a review finding that two windows' (two root stores') TCA effects cancel each other.
paths:
  - supacode/Features/RemoteClient/*.swift
---

# One TCA root `Store` per window does not share cancel ids

`Store.init` (TCA 1.23.3, `Store.swift:138`) adds a fresh `NavigationID` to each root store's
path and cancellation matches on id and path, so plain `CancelID` cases of two windows' stores do
not cancel each other. A review finding "two windows cancel each other's effects" was a false
positive (`anotherWindowOpeningSwitchingAndClosingLeavesThisWindowsEffects` pins it).

**Why:** on 2026-11-19 the finding nearly started a rewrite of the remote window's cancel ids.
