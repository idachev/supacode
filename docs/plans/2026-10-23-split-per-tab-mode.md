# Split per tab layout mode: implementation plan

Spec: [2026-10-23-split-per-tab-mode-design.md](2026-10-23-split-per-tab-mode-design.md).
**The spec is the contract.** Names, signatures, action payloads, persisted
keys and wire formats come from it verbatim. A writer who finds the spec
wrong stops and reports; changes go through the spec review loop, never into
code alone.

## Branch flow

1. The feature branch is `captain/20261023-split-per-tab`.
2. Each task works on its own branch off the feature branch, in its own
   worktree, and commits only the files it owns, by path.
3. Each task branch gets a Codex review. After its fixes it is merged into
   the feature branch.
4. After the last merge, one runner runs `make test` and `make build-app` on
   the merged head in a clean worktree, logging to `./tmp/claude-logs/`.
5. Then self-review of the whole diff, merge into `idachev-supacode`, and
   `git push origin idachev-supacode`. No pull request.

## Tasks

All eight tasks start in parallel against the spec. "Depends on" in the
spec's Task split means "needs the other task's types to compile after the
merge", not "waits for it". Writers do not build or run tests. The runner in
step 4 is the first compile of the merged whole.

| Run ID | Spec task | Writer | Tests groups it adds |
|---|---|---|---|
| ЗД6 | T1 Setting | Sonnet light coder | 1 |
| ЗД7 | T2 Model | Opus, effort high | 2, model part of 3 |
| ЗД8 | T3 Persistence | Opus | 3 |
| ЗД9 | T4 Reducer | Opus, effort high | 4, switch rows of 8 |
| ЗД10 | T5 TerminalsFeature | Opus | 5 |
| ЗД11 | T6 Plumbing | Opus | 6, quit-save row of 7 |
| ЗД12 | T7 Manager semantics | Sonnet light coder | 7, 8 |
| ЗД13 | T8 Views | Opus | 9, pane-window shortcut rows |

## Shared files

| File | Owner split |
|---|---|
| `TerminalsFeature.swift` | T4: the new rows in `canAffectVisibility` only. T5: everything else (`layoutModeChanged`, `attachLayout`, `layoutsHydrated`, `uuid` dependency). |
| `WorktreeTerminalManager.swift` | T6: `handleSearchCommand` / `handleBindingActionCommand` lists, `handleManagementCommand`, `saveAllLayoutSnapshots`, `cancelPendingLayoutSaves`. T7: `selectTab(atIndex:in:)`, `selectRelativeTab`, `listTabs`, `listPanes`, `canMoveTabToNewSplit`. |
| `AppFeature.swift` | T6: `lastKnownTerminalLayoutMode` (state, seed, diff, effect). T7: the `.tabMove` message. |
| `RecentTerminals.swift` | T4 only (switch rows). |
| `AppFeatureRecentTerminalsTests` | T4 and T7 add separate tests; neither edits the other's. |
| `LayoutPersistenceTests` | T2 (fold / unfold model tests) and T3 (record, writer, decode tests) add separate tests. |

Overlapping files merge function by function; the second merge rebases.

## Steps per task

1. Read the whole spec, then your Task split row, the Tests group(s) above,
   and every section your row names.
2. Write the listed tests first: Swift Testing, TCA `TestStore`, `TestClock`
   driven with `advance`, `withDependencies { $0.uuid = .incrementing }`,
   never `Task.sleep`. Existing suites stay unchanged (default mode = v2).
3. Implement exactly the symbols your row names. `SupaLogger` only, no free
   functions, system colours, tooltips with hotkeys.
4. Self-review the diff against the spec (revalidate each finding before
   fixing it).
5. Commit only your owned files, by path, on your task branch. Report the
   sha, the files, and anything in the spec you found wrong.

## Done when

The spec's **Done when** list holds on the merged head, and `make test` and
`make build-app` pass there (step 4).
