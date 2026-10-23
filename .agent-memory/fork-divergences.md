---
name: fork-divergences
description: Read before you change sidebar Pinned/Active ordering, license gating, the terminal layout mode or Makefile signing, or before an upstream merge.
paths:
  - "supacode/Features/Terminal/Models/PaneLayout.swift"
  - "supacode/Features/Terminal/Reducer/LayoutFeature.swift"
  - "supacode/Features/Terminal/BusinessLogic/LayoutsMigrator.swift"
  - "supacode/Features/Repositories/BusinessLogic/SidebarStructure.swift"
  - "supacode/Features/App/Models/MenuBarNotificationList.swift"
  - "supacode/Features/License/**"
  - "Configurations/Project.xcconfig"
  - "Makefile"
  - "docs/fork.md"
  - "README.md"
---

# Fork divergences

This repository is a fork. `docs/fork.md` lists every place where it differs from upstream on
purpose, with what to keep on an upstream merge. Read it before you change these files.

Settled sidebar decision (2026-10-22): **Active** is above **Pinned**, and a pinned row with an
agent or a script moves into Active. Rows inside Active stay alphabetical (upstream #678).
A newest-activity order was built and reverted (`02e78b0c`): the owner did not want rows to jump
on every agent or notification event. Do not bring back a recency order in Active.

Settled terminal layout decisions (2026-10-23): the "Terminal Layout" setting is one global
choice (not per worktree), `tabsPerSplit` (upstream) stays the default, a mode switch converts
open layouts live and closes no terminal, and there is no separate "close the whole top-level
tab" command. Details and merge rules: the "Terminal Layout" section of `docs/fork.md` and
[[split-per-tab-invariants]].

How to diverge (owner's decision): put a fork switch behind a build setting and keep upstream's
code, so merges stay clean; do not delete upstream code. Document fork-only behaviour in
`docs/fork.md`, never in `README.md`, because any `README.md` edit conflicts on the next merge.
