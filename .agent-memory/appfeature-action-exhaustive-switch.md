---
name: appfeature-action-exhaustive-switch
description: Read before adding a case to AppFeature.Action or RepositoriesFeature.Action: other exhaustive switches over them break the build.
paths:
  - supacode/Features/App/Reducer/AppFeature.swift
  - supacode/Features/App/Models/WorktreeMenuSnapshot.swift
  - supacode/Features/Repositories/**
---

# A new Action case needs an arm in every exhaustive switch

`AppFeature`'s `core` reducer is not the only exhaustive switch over `AppFeature.Action`:
`WorktreeMenuSnapshot.swift` (`var affectsWorktreeMenuSnapshot`) lists every case with no `default`.
Classify the new case there (`return false` unless it writes a menu snapshot input), or
`make build-app` fails. A new `RepositoriesFeature.Action` case likewise needs an arm in the reducer's
`body` switch and in `SidebarStructure` when it lists actions. A new associated value on an existing
case (e.g. `createRandomWorktreeFailed`) changes every pattern match that names its values.

Find them with `command grep -rn '<an existing case name>' supacode supacodeTests` before you add the case.

**Why:** on 2026-11-10/11 the remote `worktree.new` and `worktree.delete` actions each broke the build
once on a missed switch; only `make build-app` showed it.
