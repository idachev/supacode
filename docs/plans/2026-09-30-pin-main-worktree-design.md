# Pin the main checkout

Implement this spec in `/Users/idachev/develop/github/supabitapp/supacode`.
Read the whole file before editing.
Change only the pin path it names.
Do not open a GitHub issue, pull request, or push.
Follow the repository AGENTS.md commit policy. Commit only this task’s changes
on one working branch.

Inspect the current checkout and toolchain before verification. The repository
declares Ghostty, git-wt, and zmx submodules in `.gitmodules`; their local
initialization state can vary. Fetch build dependencies only when required.

## Goal

A git repository's main checkout can be pinned like any other worktree.

The main checkout is the worktree whose working directory is the repository
root (`WorktreeLocation.isMainWorktree`). In the sidebar that row is the
repository directory, on whatever branch is checked out there. Its terminal
tabs, splits, and scrollback already belong to that row. This change does not
add a separate pin for tabs.

After the user pins that row, and **View → Group Relevant Sidebar Rows →
Group Pinned Rows** is on (the default, `sidebarGroupPinnedRows`), the row
leaves the repository section and sits in the global **Pinned** section at
the top of the sidebar. That is the same hoist a linked worktree gets.
Unpin removes it from **Pinned**. It returns to the repository’s main slot
unless the existing **Active** grouping hoists it.

`supacode worktree pin` and `supacode://worktree/<id>/pin` start working for
that row with no CLI or deeplink change. Both already dispatch
`RepositoriesFeature.Action.pinWorktree`.

## Non-goals

- Do not allow archive or delete of the main checkout. Those alerts stay.
- Do not add per-row **Customize Appearance** for the main checkout. It stays
  a repository-level customization.
- Do not pin individual terminal tabs.
- Do not change folder pin. A folder is already pinnable even though its
  synthetic row is `isMainWorktree` by geometry.
- Do not force a pinned main row to position 0 inside **Pinned**. It sorts
  with the other pinned rows.
- Do not change the yellow main accent to the orange pinned accent.
- Do not open an upstream pull request. `CONTRIBUTING.md` requires an issue
  with the `ready` label first.

## How pin works today

User pin is membership of the persisted `sidebar.json` `.pinned` bucket.
`SidebarState.pin` moves the item there. `isWorktreePinned` reads that
bucket. It is not the same thing as the synthetic grouping bucket.

`rebuildSidebarGrouping` always prepends the main worktree onto the
synthetic pinned grouping, then appends `orderedPinnedWorktreeIDs`. That
helper drops `mainID`. The prepend is why the main row renders in the main
slot. It is not a user pin.

Four paths currently prevent a durable user pin of that row:

1. `RepositoriesFeature.worktreeNotificationReducer` handles
   `.pinWorktree`. For a git repository it returns `.none` when
   `isMainWorktree` is true. Comment: the main row renders in the main
   slot, never the pinned list. Folder rows are excluded from this skip.
2. `SidebarItemsView.pinActions` hides **Pin Worktree** unless
   `!isMainWorktree || isFolder`.
3. `orderedHighlightPinnedIDs` walks the persisted `.pinned` bucket and
   `continue`s when the id is a git main worktree. The global **Pinned**
   section is built from that list, and only when `groupPinned` is true.
   Pinned ids are added to `hoistedSet` before **Active** is built, so a
   hoisted row is not duplicated in **Active**.
4. `reconcileSidebarState` passes the git main id to `pruneCuratedBuckets`,
   which strips it from persisted curated buckets on repository reload.
   `mainWorktreeCustomization` then restores appearance into `.unpinned`.
   Removing only the three UI/action gates would lose the pin on reload.

`SidebarItemGroup.computeSlots` pulls any `isMainWorktree` row out of the
pinned grouping into the main slot, unless that id is already in
`hoistedRowIDs`. A hoisted main row therefore disappears from the
repository section automatically. Do not add a second removal.

`WorktreeAccent.derive` returns `.main` (yellow) whenever
`isMainWorktree` is true, before it looks at `isPinned`. The highlight
subtitle already uses the trail `Default` for that row. Leave both.

## Required behavior

1. Right-click the main checkout. The menu shows **Pin Worktree**.
   After a pin it shows **Unpin Worktree**. Bulk selection that includes
   the main checkout pins and unpins it with the other selected worktrees.
   The label stays **Worktree**, not **Folder**.
2. `.pinWorktree` on a git main checkout persists a user pin through
   `sidebar.pin` and runs the same analytics and `syncSidebar` path as a
   linked worktree. An archived row still cannot be pinned. Pending rows
   are unchanged. Do not add a new "already pinned" guard. A second pin of
   a linked worktree already re-inserts the item at the top of the bucket.
3. `.unpinWorktree` on that row uses the existing `sidebar.unpin` path.
   The row leaves **Pinned**. It returns to the main slot unless it qualifies
   for **Active** while `sidebarGroupActiveRows` is on.
4. With `sidebarGroupPinnedRows == true`, the pinned main row is in the
   global **Pinned** section and is absent from the repository's main
   slot. The repository section remains, including when that was its only
   row. The existing hoist summary (`+1 pinned`) covers it. Do not hide
   the section.
5. With `sidebarGroupPinnedRows == false`, no global **Pinned** section is
   rendered. An idle row stays in the main slot. A row qualifying for
   **Active** still hoists there when `sidebarGroupActiveRows` is on. The
   pin remains stored. Turning pinned grouping back on hoists it into
   **Pinned**. There is no extra pin glyph; the menu reflects stored state.
6. Inside **Pinned**, order stays `SidebarHighlightOrdering`: case-insensitive
   branch name, then id. Unread rows float first only when
   `moveNotifiedWorktreeToTop` is on. A pinned main row is not a special case.
7. With pinned grouping on, a pinned main row with an agent, unread
   notification, or running script
   stays in **Pinned** and is not copied into **Active**. Same rule as any
   other pinned row.
8. Local and remote git main checkouts both pin. Remote identity uses the
   same `isMainWorktree` string compare.
9. CLI status of the main checkout stays `main` after a pin.
   `SidebarState.status` returns `.main` before it looks at the bucket.
   `supacode worktree list --status main` still finds that row.
   `--status pinned` does not. Do not change `status(of:in:isMain:)`.
10. Archive, delete, and repository-level customize behavior of the main
    checkout stay as they are. `AppFeature` deeplink alerts
    "Archiving the main worktree is not allowed." and
    "Deleting the main worktree is not allowed." stay.
11. A main pin survives repository reload and persisted-state restoration,
    including remote reload/reconnection. Preserve any existing CLI-set
    title and color in the row’s current bucket. A never-pinned main row
    must not become pinned during reconciliation. No schema migration is needed.
12. The menu bar uses `menuBarForcedHoists`, independent of sidebar grouping
    toggles. A user-pinned main checkout appears in its **Pinned** group and
    is deduplicated from its **Active** and **Unread** groups as usual.

## Edits

Keep `orderedPinnedWorktreeIDs` and `orderedUnpinnedWorktreeIDs` dropping
`mainID`. `rebuildSidebarGrouping` prepends main itself. If those filters
start returning main, the synthetic pinned grouping lists it twice.

### 1. Allow the reducer action

File: `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift`

In `.pinWorktree`, delete the early return:

```swift
if repository.isGitRepository, state.isMainWorktree(worktree) {
  return .none
}
```

Remove the obsolete main-skip comments and replace newly unused `worktree`
and `repository` bindings with existence checks.

Leave the unresolvable-worktree guard, the archived-row guard, the pending
branch, and the `sidebar.pin` call. Unpin needs no new main-checkout branch.
It already moves whatever row it is given.

### 2. Show the menu

File: `supacode/Features/Repositories/Views/SidebarItemsView.swift`

In `pinActions`, stop filtering git main out. Every non-folder context row
in that menu is pinnable, including the main checkout. Keep the folder
noun (`Pin Folder` / `Unpin Folder`) and the pending-row behavior.

Do not touch `archiveAndDeleteActions`. It must keep
`!$0.isMainWorktree` for archive. Delete of the main checkout stays blocked
in the reducer and the deeplink, even if the menu still shows a delete item.

Do not touch the `Customize Appearance…` branch that requires
`!singleRow.isMainWorktree`.

### 3. Hoist a user-pinned main checkout

File: `supacode/Features/Repositories/BusinessLogic/SidebarStructure.swift`

In `orderedHighlightPinnedIDs`, delete the `isGit` / `isMainWorktree`
`continue`. The function already reads the persisted `.pinned` bucket, so
after the filter is gone only a real user pin is hoisted. Update the doc
comment that says git main worktrees are excluded.

Do not change `computeSlots`. Once the id is in `hoistedRowIDs`, the main
slot already drops it (`if !hoistedRowIDs.contains(rawMainID)`).

Do not change `WorktreeAccent.derive` or `SidebarItemView`.

### 4. Preserve the pin during reconciliation

File: `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift`

In `reconcileSidebarState` / `pruneCuratedBuckets`, preserve a live git main
item in its persisted `.pinned` or `.unpinned` bucket. Keep liveness pruning,
archived-state handling, and unresolved remote protection unchanged.
Remove the special appearance reprojection into `.unpinned`; preserving the
original item preserves its CLI-set title and color without losing its pin.
Remove `mainWorktreeCustomization` if it no longer has callers. Keep the
`seedLiveWorktrees` exclusion for an uncurated git main checkout; rendering
already supplies that row and does not require a synthetic persisted pin.

## Tests

Add tests next to the existing pin tests. Do not weaken archive, delete,
or folder-pin tests.

In `supacodeTests/RepositoriesFeatureTests.swift`:

- Pin a git main checkout. The action does not no-op.
  `isWorktreePinned` becomes true.
  `orderedHighlightPinnedIDs()` contains the id.
- Unpin it. `isWorktreePinned` is false.
  `orderedHighlightPinnedIDs()` does not contain the id.
- The synthetic grouping still has a single copy of that id
  (`orderedPinnedWorktreeIDs` still excludes it, and
  `rebuildSidebarGrouping` still prepends it once).
- `SidebarState.status(of:in:isMain:)` for that id stays `.main`.
- Pin, reload with `.repositoriesLoaded`, and confirm the pin and hoist remain.
  Cover a pin restored from persisted state and a remote main checkout.
- Preserve a pinned main item’s CLI-set title and color through reload. Keep
  the existing unpinned-main appearance regression coverage passing.
- Unpin, reload, and confirm it remains unpinned.

In `supacodeTests/SidebarStructureTests.swift`:

Replace `gitMainWorktreeNeverEntersPinnedHighlight`, which asserts the old
behavior. Retain the synthetic-grouping main-slot deduplication tests.

- `groupPinned: true`. A user-pinned main checkout is in the **Pinned**
  highlight and its repository main slot is empty of that id.
- `groupPinned: false`. With no Active classification (or `groupActive:
  false`), the row stays in the main slot. No **Pinned** highlight exists.
- `groupPinned: false`, `groupActive: true`. An active pinned main row appears
  once in **Active**, while its stored pin remains true.
- An idle main checkout that was never pinned stays in the main slot and out
  of **Pinned**, for both grouping values.
- With pinned grouping on, an active pinned main checkout appears once in
  **Pinned**, never also in **Active**.
- A repository with only its pinned main row retains its section and
  `+1 pinned` summary; the main row receives only one navigation slot.
- Forced menu-bar hoists include the pinned main even when sidebar grouping
  is off. Keep the shared ordering behavior for branch names and unread rows.
- A folder pin still hoists the folder and does not start failing the
  git-main tests.

Deeplink coverage: `pinWorktree` already reaches the repositories action
(`AppFeatureDeeplinkTests.pinWorktreeDeeplink`). No new deeplink parser
test. A repositories-level test is enough for the old no-op.

## Verification

From the repo root, if the toolchain is present:

```sh
make test
make build-app
```

If either command cannot run, report the exact blocker and checks not
executed. Do not claim they passed. Perform a context-menu check when the
app can run: main-only, mixed selection, pin, and unpin.

## Done when

- The context menu can pin and unpin the main checkout.
- With **Group Pinned Rows** on, that row lives only in **Pinned**.
- With the toggle off, the pin stays stored and normal Active grouping applies.
- Reload preserves the pin and any existing CLI-set appearance.
- Archive and delete of the main checkout still fail.
- Folder pin is unchanged.
- Tests cover pin/unpin, reload persistence, grouping interactions, and remote identity.
- Required tests and `make build-app` pass, or concrete environment blockers are reported.
