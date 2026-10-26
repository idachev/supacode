---
name: appfeature-reducer-order
description: Read before adding AppFeature logic that must see a child feature's state after the action (repositories, terminals, settings).
paths:
  - supacode/Features/App/Reducer/AppFeature.swift
---

# AppFeature `core` runs before the child scopes

`AppFeature.body` lists `core` first, then `Scope(\.terminals)`, `Scope(\.repositories)`, `Scope(\.settings)` and the
others, then trailing `Reduce`s ("After the scopes, so the layouts already reflect the action").

So inside `core`, a case like `.repositories(.repositoriesLoaded)` sees the state BEFORE the repositories child
handled it: `state.repositories.isInitialLoadComplete` is still false on the first load, and a closed tab is still
in `state.terminals.layouts`.

Logic that must react to the child's new state (derived state recomputed after a load, a once-after-launch
trigger, a fan-out from removed tabs) goes in a trailing `Reduce` after the scopes, gated on a narrow set of
actions, like `trackRecentTerminalAccess`, the `affectsWorktreeMenuSnapshot` gate and the agent resume
`affectsAgentResume` gate (it calls `refreshAgentResume`).

Also: `isInitialLoadComplete` is set by two actions, `.repositoriesLoaded` and `.openRepositoriesFinished`;
a gate that lists only one misses a launch path. **Why:** found while designing the agent resume picker
(2026-10-26); the first draft recomputed in `core` and saw stale state.
