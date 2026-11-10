# Remote delete worktree and refresh worktrees (ЗД9) — design

Status: draft, checked against the code on 2026-11-10 (base `28d7b272`, after the `worktree.new` merge).
Contract for the Mac host, the protocol doc, the web client and the Android client. ОВ5–ОВ11 are
open for the owner. Builds on `docs/plans/2026-11-10-remote-new-worktree-design.md` (`worktree.new`)
and reuses its patterns: lenient fields, an AppFeature outcome bridge read through `withState`,
router waits through `RemoteHostRouter.poll` with an injected clock, `worktree_*` error codes, ids on
every error, per-connection waits cancelled on disconnect.

## Goal

Owner: „да добавим и триене на worktree и командата която рефрешва worktree ако сме изтрили от
cli/terminal“.

1. `worktree.delete`: the client deletes one worktree the way Supacode's own "Delete Worktree…"
   does on the Mac.
2. `worktrees.refresh`: the client asks the Mac to do what its own "Refresh Worktrees" does, so a
   worktree deleted from a terminal (`git worktree remove`, `supacode` CLI, another tool) disappears
   from the Mac and from the client's `list` without touching the Mac.

Out of scope (ГР1): archive / unarchive from the client, deleting several worktrees at once,
removing a folder entry or a whole repository, cancelling a pending (being created) worktree.

## What Supacode does today: delete

Line numbers are `supacode/Features/...` unless the path says otherwise.

- Entry points, all ending in `.requestDeleteSidebarItems([DeleteWorktreeTarget])`:
  sidebar context menu "Delete Worktree…" (`Repositories/Views/SidebarItemsView.swift:807-815`,
  role destructive, shortcut `deleteShortcut`), the worktree menu "Delete Worktree…"
  (`supacode/Commands/WorktreeCommands.swift:129-134`, enabled by the focused `deleteWorktreeAction`),
  the command palette (`App/Reducer/AppFeature.swift:1980-1985`, `.removeWorktree` →
  `requestDeleteSidebarItems`), the worktree detail view (`Repositories/Views/WorktreeDetailView.swift:302`)
  and the archived list (`Repositories/Views/ArchivedWorktreesDetailView.swift:57`). Default shortcut
  ⇧⌘⌫ (`SupacodeSettingsShared/App/AppShortcuts.swift:543-546`).
- `.requestDeleteSidebarItems` (`Repositories/Reducer/RepositoriesFeature.swift:1107-1236`):
  per target it skips duplicates, a repository being removed (`removingRepositoryIDs`), an unknown
  repository or worktree (`:1118-1122`), a row whose lifecycle is not `.idle` (`:1123-1124`), and in
  a git repository the main worktree (`:1125-1129`). A single rejected main worktree gets the alert
  "Delete not allowed" / "Deleting the main worktree is not allowed." (`:1141-1146`); every other
  rejection is silent. A folder entry gets the 3-button "Remove folder?" alert (`:1150`), not a
  worktree delete.
- The git-worktree confirmation (`:1205-1239`): title "Delete worktree?", button "Delete worktree"
  (destructive) and "Cancel". Message by the global setting `deleteBranchOnDeleteWorktree` and by
  whether the worktree is an orphan (`isMissing`):
  - orphan: "Removes the orphan worktree entry from this repository."
  - setting on: "This deletes the worktree directory and its local branch."
  - setting off: "This deletes the worktree directory but keeps the local branch."
- The setting: `deleteBranchOnDeleteWorktree`, default **true**
  (`SupacodeSettingsShared/Models/GlobalSettings.swift:232` in `static let default`), shown in
  Settings as "Delete local branch with worktree" with the red note "Uncommitted changes will be
  lost." (`SupacodeSettingsFeature/Views/WorktreeSettingsView.swift:73-76`).
- **No dirty or unpushed check exists.** Nothing in the request, confirm or apply arms looks at
  uncommitted changes or unpushed commits. Git removes with `git worktree remove --force --force`
  (`Clients/Git/GitClient.swift:1535-1553`, overrides "dirty" and "locked") and deletes the branch
  with `git branch -D` (`GitClient.swift:1350-1358`, force, also for an unmerged branch). A local
  worktree's directory is first moved aside and trashed after (`GitClient.swift:1328-1330`,
  `:1361-1363`).
- Confirm → `.confirmDeleteSidebarItems` (`RepositoriesFeature.swift:1241-1305`) → one
  `.deleteSidebarItemConfirmed(worktreeID, repositoryID)` per target (`:1300-1302`).
- `.deleteSidebarItemConfirmed` (`RepositoriesFeature.swift:1316-1406`): no-op when the row is
  already `.archiving`, `.deleting` or `.deletingScript` (`:1327-1334`). **It has no main-worktree
  guard**; that guard lives only in `requestDeleteSidebarItems` and in the CLI path. Delete script:
  the repository setting `deleteScript` (`:1362-1364`; edited in
  `SupacodeSettingsFeature/Views/RepositoryScriptsSettingsView.swift:40`). Empty script or orphan
  worktree → `.deleteWorktreeApply` at once (`:1378-1396`). Otherwise the row becomes
  `.deletingScript` and `.delegate(.runBlockingScript(…, kind: .delete, focusing: !background))`
  runs the script in a terminal tab of that worktree (`:1398-1406`; AppFeature `:848-857` hands it
  to the terminal manager).
- `.deleteScriptCompleted` (`RepositoriesFeature.swift:1408-1496`): exit 0 → `.deleteWorktreeApply`
  (`:1459`); exit 0 but the repository is gone → alert "Delete failed" and **no further action**
  (`:1471-1480`); tab closed (`nil`) → nothing more (`:1482-1486`); other exit code → the blocking
  script failure alert (`:1487-1492`).
- `.deleteWorktreeApply` (`:1498-1541`): worktree gone → alert "Delete failed" / "The worktree could
  not be found. It may have already been removed." and **no further action** (`:1499-1509`). Else the
  row becomes `.deleting`, `gitClient(for: worktree).removeWorktree(worktree, deleteBranch)` runs
  (host-aware: an ssh worktree is removed over ssh, `:1518-1520`, `GitClient.swift:1316-1348`), then
  `.worktreeDeleted` or `.deleteWorktreeFailed(localizedDescription, worktreeID:)`.
- `.worktreeDeleted` (`:1543-1590`): removes the row from the sidebar and the repository, moves the
  Mac selection to the next worktree if the deleted one was selected (`:1561-1565`), sends
  `.repositoriesChanged`, then `.reloadRepositories(animated: true)` (`:1583-1585`).
- `.deleteWorktreeFailed` (`:1680-1683`): alert "Unable to delete worktree" with the message, row
  back to `.idle`.
- Terminals: AppFeature's `.repositories(.worktreeDeleted)` arm (`App/Reducer/AppFeature.swift:1764-1778`)
  sends `terminalClient.send(.removeWorktreeLayout(worktreeID:remoteHost:))`, which ends the
  worktree's tabs, sessions and persisted layout. A phone attached to one of those terminals gets
  `{"t":"detached","contentId":…,"reason":…}` when its stream closes (`RemoteAccess/RemoteHostRouter.swift:447-450`,
  protocol doc `### attach / detach`).
- CLI / deeplink delete (`AppFeature.swift:3790-3889`, `deeplinkDeleteWorktreeEffect`): refuses the
  main worktree ("Delete not allowed", `:3812-3826`), routes a folder to the 3-button alert
  (`:3830-3860`), refuses a row whose lifecycle `isTerminating` ("Delete unavailable", `:3861-3874`),
  shows its own confirmation unless `bypassConfirmation` (`:3875-3885`), and otherwise sends
  `.deleteSidebarItemConfirmed(worktreeID, repositoryID, background:)` directly with an ack matched
  on `.worktreeRemoved(worktreeID:)` (`:3886-3889`). The ack resolves in AppFeature core:
  `.worktreeDeleted` → ok (`:1764-1773`), `.deleteWorktreeFailed` → error with the message
  (`:1864-1868`), `.deleteScriptCompleted` with exit ≠ 0 → "Delete script failed (exit code N)." or
  "Delete cancelled." (`:1870-1879`). Its default timeout is 180 s (`AppFeature.swift:35`).
- Pending rows (`pending:…` ids, a worktree being created) are not in `repository.worktrees`; the Mac
  cancels them with `.cancelPendingWorktree` (`RepositoriesFeature.swift:462`, `:4612-4613`), not
  with delete.
- Archived worktrees can be deleted on the Mac from the archived list, but `list` leaves them out
  (protocol doc `### list`).

## What Supacode does today: refresh

- "Refresh Worktrees" menu item (`supacode/Commands/WorktreeCommands.swift:94-98`, shortcut ⇧⌘R,
  `SupacodeSettingsShared/App/AppShortcuts.swift:531`) and the command palette entry
  (`AppFeature.swift:2006-2007`) send AppFeature `.refreshWorktreesRequested`
  (`AppFeature.swift:571-577`): `.repositories(.refreshWorktrees)` plus
  `worktreeInfoWatcher.send(.refresh)` (branch, line counts, PRs;
  `Repositories/BusinessLogic/WorktreeInfoWatcherManager.swift:208-209`).
- `.refreshWorktrees` sets `isRefreshingWorktrees = true` and sends `.reloadRepositories(animated: false)`
  (`RepositoriesFeature.swift:3806-3808`). `.reloadRepositories` reloads every local root with
  `git worktree list` (`loadRepositories`, `:5104-5124`, cancellable with `cancelInFlight: true`)
  or clears the flag when there is nothing to load (`:3827-3833`). `.repositoriesLoaded` clears the
  flag (`:3843`), applies the roster (worktrees gone from git disappear), sends
  `.repositoriesChanged` when something changed (`:3878-3880`) and, when any ssh repository exists,
  `.resolveRemoteRepositories` (`:3892-3894`). `.loadPersistedRepositories` also clears the flag
  (`:3788`).
- ssh repositories: a refresh keeps an already resolved ssh repository's existing worktrees
  (`RepositoriesFeature.swift:5176-5178`, not put back into `resolvingIDs`), and the re-probe lands
  later as one `.remoteRepositoryResolved` per repository (`:3928-3958`). No state marks when a
  re-probe finishes.
- Terminals of a worktree that left the roster are pruned by AppFeature's `.repositoriesChanged`
  arm (`AppFeature.swift:748-763`), unless ssh repositories are still resolving.
- Automatic refresh: on becoming active, and every 30 s while the app is foreground-active
  (`AppFeature.swift:579-605`). The loop is cancelled when the app goes inactive or to the background
  (`:613`, `:625`, `:630`). **This is why a remote refresh is needed**: when the owner controls the Mac
  from the phone, Supacode is usually not the active app, so a worktree removed from a terminal stays
  in the Mac sidebar and in `list` until someone refreshes on the Mac.
- `rm -rf <worktree>` without `git worktree remove` does not remove the worktree from git: the next
  load keeps it as an orphan with `isMissing = true` (`Clients/Git/GitClient.swift:129-130`). Refresh
  does not drop it; `worktree.delete` does (the Mac skips the delete script for an orphan,
  `RepositoriesFeature.swift:1378`).

## Protocol contract

### worktree.delete (client → host)

`{"t":"worktree.delete","id":8,"worktreeId":"<worktree id from list>"}`

- `worktreeId` (string, required): `repos[].worktrees[].id` from `list`. Reuses the existing
  `RemoteInboundMessage.worktreeId` (`RemoteAccess/RemoteProtocol.swift:44`, plain `String?`, as
  `tab.new` uses it). A non-string `worktreeId` fails the decode and the message is dropped with no
  reply, as for `tab.new` today; making it lenient would change `tab.new` too, so not in v1.
- `id` (optional integer): echoed in the reply or error (`null` when omitted).
- No `repositoryId` (the worktree id is unique across repositories: a local worktree's id is its
  path, an ssh one's is `host.authority + path`) and no `deleteBranch` override: the Mac's setting
  decides (ОВ6).

### worktree.delete (host → client, success)

`{"t":"worktree.delete","id":8,"worktreeId":"…","repositoryId":"…","branchDeleted":true}`

- Sent once the worktree has left the Mac's roster (`.worktreeDeleted` processed, or the worktree no
  longer in `repositories` while the delete was running). Any `list` sent after this reply no longer
  has the worktree.
- `branchDeleted`: the value of `deleteBranchOnDeleteWorktree` when the delete started (the Mac does
  `git branch -D` only when the branch exists, and ignores its failure, `GitClient.swift:1350-1358`;
  so `true` means "asked to delete", not proven). Clients use it only for the toast text.

### worktrees.refresh

- client → host `{"t":"worktrees.refresh","id":9}`
- host → client: a full `list` frame with the same `id`: `{"t":"list","id":9,"repos":[…],"sections":[…]}`,
  built after the Mac's reload finished (Host behaviour R3). Justification: the client already
  renders `list`; one round trip gives the fresh roster; the client needs no second request.
  Clients correlate by `id`, and a `list` frame they did not ask for is rendered like any other.

### Errors

`{"t":"error","id":8,"message":"…","code":"<code>"}`

| code | message | when |
|---|---|---|
| `worktree_invalid` | `worktree.delete needs a worktreeId`, `no such worktree` | `worktreeId` missing or empty; unknown, archived, or a pending (`pending:…`) id |
| `worktree_unsupported` | `the main worktree cannot be deleted`, `folders cannot be deleted from the remote`, `the repository is being removed` | main worktree; folder (non-git) entry; repository in `removingRepositoryIDs` |
| `worktree_busy` | `the worktree is busy (being created, archived or deleted)` | row lifecycle not `.idle` (setup script running, archiving, deleting, delete script running), or a remote delete of it is still in flight |
| `worktree_failed` | `Delete script failed (exit code N).`, `Delete cancelled.`, `Unable to delete worktree: <git message>` | the app reported a failure |
| `worktree_timeout` | `the delete is still running on the Mac; the worktree may disappear from the list later` | no outcome within `worktreeDeleteTimeout` (300 s) |
| `refresh_timeout` | `the refresh is still running on the Mac; send list again later` | `worktrees.refresh` reload not finished within 60 s |

- `worktree_invalid`, `worktree_unsupported`, `worktree_busy` are decided by the router/source and
  never reach the app: the Mac shows no alert for them. App failures show the Mac's normal alert as
  well (same code path).
- Old hosts answer `{"t":"error","id":8,"message":"unknown message type: worktree.delete"}` (and the
  same for `worktrees.refresh`) with no `code` (`RemoteHostRouter.swift:296-297`). Clients do not show
  the buttons for an old host anyway (see `list` below); if they get this error, they hide the
  feature for that host.

### list

- `repos[].worktrees[]` gains `"canDeleteWorktree": true|false`: true when the worktree is in a git
  repository (local or ssh) not being removed, is not the main worktree, and its row lifecycle is
  `.idle`. Absent (old host) means false: no delete button.
- The top-level `list` object gains `"canRefreshWorktrees": true`. Absent (old host) means false: no
  refresh button. A per-host flag is needed because refresh has no per-row anchor; `hello` is not
  used, because `list` is where the client already reads capabilities (`canCreateWorktree`).

### Client contract

- К6 Request id: every reply and every error carries the request's `id` (explicit `null` when none);
  the decoder rule (non-integer `id`, non-string `worktreeId`, not an object with a string `t`) drops
  the message with no reply.
- К7 Lost connection: a wait belongs to its connection id; `conn.close`, a LAN socket closing and the
  relay socket dropping cancel it (as `worktree.new`). The delete or refresh itself goes on. The
  client shows "Connection lost; the worktree may still disappear from the list", does not retry,
  and sends `list` after reconnecting.
- К8 Reply time: `worktree.delete` within 300 s of receipt plus main-actor slack; client timeout
  310 s from sending. `worktrees.refresh` within 60 s; client timeout 70 s. Router-side errors are
  immediate. After a timeout the client behaves as in К7.
- К9 Late outcome: after a timeout or lost connection the client cannot learn a late failure (only the
  Mac's alert shows it). A retry of `worktree.delete` while the first still runs gets `worktree_busy`;
  once it has succeeded, `no such worktree`; once it has failed, the retry deletes normally.
- К10 Attached terminals: the deleted worktree's terminals end; an attached phone gets `detached` for
  each before or after the `worktree.delete` reply (no order is promised).

## Host behaviour

### Delete

D1. Protocol types (`RemoteProtocol.swift`): `RemoteWorktreeDeleteMessage` (`t`, `id` encoded as
  explicit null like `RemoteErrorMessage`, `worktreeId`, `repositoryId`, `branchDeleted`);
  `RemoteWorktree` gains `canDeleteWorktree: Bool` (through `RemoteSnapshotBuilder.WorktreeInput`);
  `RemoteListMessage` gains `canRefreshWorktrees = true`. New file `RemoteWorktreeDelete.swift` next
  to `RemoteWorktreeNew.swift`: error codes (reusing `RemoteWorktreeNewErrorCode` values plus
  `refresh_timeout`), `RemoteWorktreeDeleteRejection` with `code`/`message` and one static
  `check(found:isArchived:isGitRepository:isBeingRemoved:isMain:lifecycleIsIdle:inFlight:)` that both
  the request and `canDeleteWorktree` use, so `list` never offers what the router refuses.
D2. Router: `case "worktree.delete"` in `receiveDirect` (`RemoteHostRouter.swift:261-298`) →
  `deleteWorktree(connID:message:)`: resolves `worktreeId`, calls
  `source.requestDeleteWorktree(worktreeID:) -> Result<RemoteWorktreeDeleteStart, RemoteWorktreeDeleteRejection>`.
D3. Source (`RemoteSnapshotSource`), reading with `store.withState(\.repositories)` (as
  `requestNewWorktree`, `RemoteSnapshotSource.swift:227`): finds the repository containing the id;
  applies the D1 check: unknown or archived (`sidebar.status(…).isArchived`, as `requestNewTab` does,
  `:171`) → `worktree_invalid`; folder, main (`state.isMainWorktree`), repository being removed →
  `worktree_unsupported`; lifecycle not `.idle` (`sidebarItems[id:]?.lifecycle ?? .idle`, the same
  rule as `requestDeleteSidebarItems`, `RepositoriesFeature.swift:1124-1125`) or an entry in
  `remoteWorktreeDeletions` → `worktree_busy`. On pass it reads `deleteBranchOnDeleteWorktree`
  (`@Shared(.settingsFile)`) and sends one AppFeature action
  `.remoteWorktreeDeleteRequested(worktreeID:, repositoryID:)`.
D4. AppFeature (core, next to the `worktree.new` arms; core runs before the repositories `Scope`,
  `AppFeature.swift:2344`, `:2351`): new state
  `remoteWorktreeDeletions: [Worktree.ID: RemoteWorktreeDeletion]`, keyed by the real worktree id
  (it is stable; no pending id needed), with
  `enum RemoteWorktreeDeletion: Equatable { case deleting(abandoned: Bool); case deleted; case failed(message: String) }`.
  - `.remoteWorktreeDeleteRequested`: inserts `.deleting(abandoned: false)`, then sends
    `.repositories(.deleteSidebarItemConfirmed(worktreeID, repositoryID, background: <ОВ8>))`, exactly
    as the CLI does with `bypassConfirmation` (`AppFeature.swift:3886-3887`). The Mac shows no
    confirmation alert: the client confirmed. No new git or script logic.
  - Existing arms move an entry only from `.deleting` (the CLI ack arms are the model):
    `.repositories(.worktreeDeleted(id, …))` (`:1764`) → `.deleted`;
    `.repositories(.deleteWorktreeFailed(message, id))` (`:1864`) → `.failed("Unable to delete worktree: <message>")`
    (the Mac alert's title + message);
    `.repositories(.deleteScriptCompleted(id, exitCode, _))` with `exitCode != 0` (`:1870`) →
    `.failed("Delete script failed (exit code N).")` or `.failed("Delete cancelled.")` (the CLI's texts).
  - `.remoteWorktreeDeleteConsumed(worktreeID)` removes a settled entry;
    `.remoteWorktreeDeleteAbandoned(worktreeID)` marks a `.deleting` one abandoned, and an arm that
    would settle an abandoned entry removes it instead (same leak rule as `remoteWorktreeCreations`).
D5. Router wait (one `Task` per request in `worktreeDeleteWaits[connID]`, cancelled from the same
  three places as `cancelWorktreeNewWaits`, `RemoteHostRouter.swift:265-266` and the LAN/relay drop
  paths; poll 100 ms; `worktreeDeleteTimeout` = 300 s local and ssh). The probe ends on:
  - entry `.deleted`, **or** the worktree no longer in `repositories` → success reply. The second
    covers the two exits that send no action (`deleteWorktreeApply` not-found,
    `RepositoriesFeature.swift:1499-1509`; script exit 0 with the repository gone, `:1471-1480`) and
    a concurrent refresh that dropped it;
  - entry `.failed(message)` → `worktree_failed`;
  - timeout → `worktree_timeout`.
  Every exit sends `.remoteWorktreeDeleteConsumed` or, while still `.deleting`,
  `.remoteWorktreeDeleteAbandoned` first (`awaitWorktreeNew` pattern,
  `RemoteWorktreeNew.swift:175-189`). The reply checks `clients[connID] != nil`.
D6. Busy guard: the `.deleting` entry blocks a second remote delete of the same worktree until the
  outcome settles, even after the first phone left. A Mac-side delete of the same row is already
  blocked by the lifecycle (`.deletingScript`/`.deleting`), which D3 also reads.
D7. ssh repositories: supported as on the Mac (ОВ9). The app's path is host-aware
  (`gitClient(for:)`), the delete script runs in the worktree's (remote) terminal. Not confirmed:
  whether `branch -D` reaches the ssh host — `removeWorktree` looks up branches with
  `localBranchNames(for: worktree.repositoryRootURL)` (`GitClient.swift:1352`) and the router does not
  change that; T1 checks it and the reply's `branchDeleted` stays "asked", not "done".
D8. No read-only rule: any authenticated client may delete (as `worktree.new`, `tab.new`).

### Refresh

R1. Router: `case "worktrees.refresh"` → `refreshWorktrees(connID:message:)`.
R2. Source: `requestRefreshWorktrees() -> RemoteRefreshStart` reads the load counter (R4) with
  `withState`, then sends `.refreshWorktreesRequested` (`AppFeature.swift:571`), the same action as
  the menu, shortcut and palette. Not `.loadPersistedRepositories`: it also clears `state.alert`
  (`RepositoriesFeature.swift:3787`), which the Mac's own refresh does not.
R3. Wait (per connection, cancelled like D5, poll 100 ms, `worktreesRefreshTimeout` = 60 s): until
  `repositoriesLoadCount > start` (R4), or `isRefreshingWorktrees == false` with the counter unchanged
  (the nothing-to-load path, `RepositoriesFeature.swift:3827-3833`). Then reply
  `source.listMessage(id:)` (`RemoteHostRouter.swift:279-280`). Timeout → `refresh_timeout`. Because
  loads are `cancelInFlight` (`:5124`), a load started by someone else after ours still increments the
  counter and its result is at least as fresh, so waiting for "any load after start" is correct.
R4. AppFeature: `repositoriesLoadCount: Int`, incremented in core on
  `.repositories(.repositoriesLoaded)`. A counter, not `isRefreshingWorktrees` alone, because
  `.loadPersistedRepositories` clears that flag before its load finishes (`:3788`). T1 confirms with
  a test that `store.send(.refreshWorktreesRequested)` has set `isRefreshingWorktrees` by the time it
  returns (the `.send` effect runs in the same send; not confirmed by reading TCA here).
R5. ssh: the reply reflects local repositories only. ssh rosters update through the re-probe that the
  reload starts (`RepositoriesFeature.swift:3892-3894`) and appear in a later `list` (ОВ10).
R6. Concurrency: several phones may refresh at once; each waits for the same kind of event. No busy
  guard: a refresh while one runs restarts the load (`cancelInFlight`), as pressing ⇧⌘R twice does.

## Client UI (web + Android)

- Delete: a trash icon on each worktree row (or in its overflow menu), shown only when
  `canDeleteWorktree` is true; tooltip / content description "Delete worktree". Tap opens a
  confirmation dialog (ОВ5):
  - title "Delete worktree?"
  - message "This deletes the worktree directory \"<name>\" on <host name> and, if the Mac's setting
    says so, its local branch. Uncommitted changes and unpushed commits in it are lost. Its
    terminals close."
  - buttons "Delete worktree" (destructive) and "Cancel".
  While waiting: the row shows a spinner and "Deleting…", the button is disabled. Success: toast
  "Deleted <name>" (+ " and its local branch" when `branchDeleted`), send `list` (or drop the row
  locally and then `list`); if the phone was attached to one of its terminals, go back to the list.
  Error: keep the row, show `message`; `worktree_timeout` / client timeout / lost connection: "Still
  deleting on the Mac, or the connection was lost. The worktree may disappear from the list later."
- Refresh: a refresh icon in the list header (next to the host name), shown only when
  `canRefreshWorktrees` is true; tooltip "Refresh worktrees on the Mac". Pull-to-refresh on Android
  and the web list send `worktrees.refresh` instead of `list` when supported. While waiting: spinner.
  Reply: render the `list` frame. `refresh_timeout`: "The Mac is still refreshing; try again later."

## Task split

- T1 Mac host (one worker): `RemoteProtocol.swift` (`RemoteWorktreeDeleteMessage`,
  `canDeleteWorktree`, `canRefreshWorktrees`), new `RemoteWorktreeDelete.swift` (codes, rejection +
  shared check, wait/outcome/reply helpers as in `RemoteWorktreeNew.swift`), `RemoteSnapshotBuilder`
  (`WorktreeInput.canDeleteWorktree`), `RemoteSnapshotSource` (`requestDeleteWorktree`,
  `worktreeDeletion(_:)`, consume/abandon, `requestRefreshWorktrees`, load counter read, all via
  `withState`), `RemoteHostRouter` (two cases, waits, cancel on disconnect), `AppFeature`
  (`remoteWorktreeDeletions`, `repositoriesLoadCount`, the request/consume/abandon actions, outcome
  updates in the existing arms). Tests with `TestClock`, no `Task.sleep`: success via `.worktreeDeleted`;
  success via "left the roster" without an event; `deleteWorktreeFailed` and script exit ≠ 0 / nil
  messages; timeout; disconnect while deleting abandons and the busy guard holds until settled; every
  rejection (unknown, archived, pending id, main, folder, removing, lifecycle, in flight); the shared
  check drives `canDeleteWorktree`; refresh replies after the counter moves, on the nothing-to-load
  path, and on timeout. `AppFeature` `TestStore` tests for each arm, unknown ids ignored, abandoned
  removal. Then `make test` and `make build-app`.
- T2 protocol doc (`docs/remote-access-protocol.md`): `### worktree.delete` and
  `### worktrees.refresh` after `### worktree.new` (with К6–К10), `canDeleteWorktree` and
  `canRefreshWorktrees` in `### list`, the new codes in `### errors`. Same worker as T1.
- T3 web client, T4 Android client: another session, against this contract only.

## Not confirmed

- Whether `focusing` of the delete script tab (`runBlockingScript`, `WorktreeTerminalManager.swift:384-385`)
  changes the Mac's selected worktree or only the tab inside it; not read further (ОВ8).
- Whether `git branch -D` runs on the ssh host for an ssh worktree (D7).
- That `.refreshWorktreesRequested` sets `isRefreshingWorktrees` synchronously within `store.send` (R4).

## Open questions

- ОВ5 Confirmation wording. Options: (a) the generic text above; (b) the Mac's exact three texts,
  which needs `list` to send `deleteBranchOnDelete` (host-level) and `missing` (per worktree);
  (c) (b) plus the worktree's dirty / unpushed state, which the host does not compute today.
  Recommendation: (a) in v1; it is honest for every case and needs no new fields.
- ОВ6 Delete the local branch. Options: (a) follow the Mac's setting `deleteBranchOnDeleteWorktree`
  (default on), report it as `branchDeleted`; (b) a per-request `deleteBranch` field;
  (c) never delete the branch from the remote. Recommendation: (a), it is exactly what the Mac does.
- ОВ7 Dirty worktree / unpushed commits. The Mac does not check (force remove, `branch -D`). Options:
  (a) mirror: no check, the dialog warns; (b) refuse with `worktree_dirty` when `git status` shows
  changes or the branch has unpushed commits, with a `force` field to override; (c) report the state
  in the dialog only. Recommendation: (a) for v1, mirroring the Mac; (b) as a later feature for both
  the Mac and the remote.
- ОВ8 Mac focus during the delete script. Options: (a) `background: false`, as the Mac's own delete
  (the script tab gets focus on the Mac); (b) `background: true`, as a background CLI delete (the
  Mac's focus is not touched). Recommendation: (b): the remote user is not at the Mac, and the
  worktree goes away anyway; the outcome and alerts are the same.
- ОВ9 ssh repositories. Options: (a) supported, as on the Mac (host-aware delete); (b)
  `worktree_unsupported` in v1. Recommendation: (a), consistent with ОВ3 for `worktree.new`.
- ОВ10 Refresh scope for ssh. Options: (a) reply after the local reload; ssh results come in a later
  `list`; (b) also wait for each ssh repository's `.remoteRepositoryResolved` (a per-repository
  counter, bounded by the 60 s budget). Recommendation: (a) in v1, (b) if the owner uses ssh
  repositories from the phone.
- ОВ11 Refresh as a message or automatic. Options: (a) a separate `worktrees.refresh` that answers
  with a `list` frame (this design); (b) a flag on `list` (`{"t":"list","refresh":true}`): an old host
  ignores it and answers at once with a stale list, so the client cannot tell; (c) refresh on every
  `list`: `list` is a synchronous reply today (`RemoteHostRouter.swift:279-280`), a git reload per
  `list` is slow and each one cancels the previous load (`cancelInFlight`); (d) (a) plus the host
  starting a refresh by itself when a phone connects. Recommendation: (a); (d) can follow later.
