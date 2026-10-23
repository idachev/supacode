---
name: layouts-persistence
description: Read before touching terminal layout persistence: layouts live in UserDefaults `layoutsFile`, and a partial decode gets zmx sessions reaped at launch.
paths:
  - supacode/Features/Terminal/BusinessLogic/Layouts*.swift
  - supacode/Features/Terminal/BusinessLogic/LayoutPersistence.swift
  - supacode/Features/Terminal/Models/PaneLayout.swift
---

# Layout persistence lives in UserDefaults, not layouts.json

Since 01831462 (#791) the per-worktree pane layouts (`LayoutsFile`, schemaVersion 2) are a JSON blob in
UserDefaults under `LayoutsFile.userDefaultsKey` = `"layoutsFile"`; a corrupt blob is stashed under
`layoutsFile.corrupt`. `~/.supacode/layouts.json` is only the legacy source that `readPersisted` falls
back to before the store is seeded and that `SettingsRelocationMigrator` moves to a backup. "layouts.json
v2" in docs and commit messages means this blob.

Rules the code depends on:

- `LayoutsFile.readPersisted` treats `schemaVersion > current` and any tolerant-decode loss as
  `.unreadable`. The launch orphan reaper (`AppFeature`, `reapOrphanSessions(layouts.allKnownSurfaceIDs)`)
  kills every zmx session whose content id is missing from a `.file` read. A new persisted shape that an
  older build decodes partially (an ignored extra key that hides contents) gets sessions reaped.
- `LayoutsIncrementalWriter` is the only runtime writer (`SettingsRelocationMigrator` writes the key once
  when it seeds from the legacy file); it refuses to write into a newer schema and aborts on a lossy blob.
- Split-per-tab mode does not change the schema: a record's `layout` is always the consistent v2
  projection that holds every content, and the grouping rides in the optional `LayoutRecord.splitPerTab`
  sidecar. An older build reads the v2 layout and kills nothing. Keep it that way; do not bump to a
  schema v3 for a new layout shape. See [[split-per-tab-invariants]].
</content>
