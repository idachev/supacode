---
name: sidebar-filter
description: Read before changing the sidebar filter, sidebarStructure, hotkey slots or anything RemoteSnapshotSource builds the phone's list from.
paths:
  - "supacode/Features/Repositories/**"
  - "supacode/Features/RemoteAccess/RemoteSnapshotSource.swift"
---

# Sidebar filter

- **`sidebarStructure` stays unfiltered.** `RemoteSnapshotSource` builds the remote clients'
  repository list from it, so filtering it would hide rows on the phone and in the web app too.
  The filter result lives in a separate `filteredSidebarStructure`; views and keyboard navigation
  (⌃1..⌃9, next/previous worktree) read `visibleSidebarStructure`.
- **The rules match Supacode Remote** (Android `FuzzyMatch`): trim, lowercase, substring or up to
  two typos by query length; repo name, row title, name and branch. Change them in both places.
- **While filtering, collapse state is shown expanded but never written:** group and branch-folder
  toggles do nothing and worktree rows cannot be reordered, so the saved state survives the filter.

**Why:** on 2026-11-10 the first version filtered the shared structure path, and review rounds
found hotkeys and collapse toggles acting on hidden or force-expanded rows.
