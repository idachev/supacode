# Remote delete worktree and refresh worktrees (ЗД9) — design

Status: draft r2 (Codex r1 F1–F13 triaged), checked against the code on 2026-11-10 (base `28d7b272`).
Contract for the Mac host, the protocol doc, the web client and the Android client. ОВ5–ОВ12 are decided (ОВ12 came
from the Codex r1 review). Builds on `docs/plans/2026-11-10-remote-new-worktree-design.md` (`worktree.new`)
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
- Confirm → `.alert(.presented(.confirmDeleteSidebarItems(targets, disposition: .gitWorktreeDelete)))`
  (`RepositoriesFeature.swift:1241-1305`; an alert action, not a top-level one) → one
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
  `tab.new` uses it). Making it lenient would change `tab.new` too, so not in v1 (see К6 for the
  decoder rule).
- `id` (optional integer): echoed in the reply or error (`null` when omitted).
- No `repositoryId` (the worktree id is unique across repositories: a local worktree's id is its
  path, an ssh one's is `host.authority + path`), no `deleteBranch` and no `force` field (ОВ6, ОВ7
  decided).
- What the host does (owner decisions ОВ6, ОВ7): it first checks the worktree for uncommitted changes
  and untracked files and refuses with `worktree_dirty` if there are any; otherwise it deletes the
  worktree the way the Mac's own delete does (delete script, then `git worktree remove`), but
  **never deletes the local branch**, whatever `deleteBranchOnDeleteWorktree` says.

### worktree.delete (host → client, success)

`{"t":"worktree.delete","id":8,"worktreeId":"…","repositoryId":"…"}`

- Sent only after the app reported the delete done (`.worktreeDeleted`, Host behaviour D4). That arm
  removes the worktree from the roster in the same reducer pass (`RepositoriesFeature.swift:1543-1575`),
  so any `list` sent after this reply no longer has it. A worktree that merely left the roster
  without that action is **not** a success (D5).
- The local branch always stays (ОВ6), so the reply has no branch field.

### worktrees.refresh

- client → host `{"t":"worktrees.refresh","id":9}`
- host → client: a full `list` frame with the same `id`: `{"t":"list","id":9,"repos":[…],"sections":[…],"loadFailures":[…]}`,
  built after a git load that started after the request finished (Host behaviour R3). Justification:
  the client already renders `list`; one round trip gives the fresh roster. Clients correlate by
  `id`, and a `list` frame they did not ask for is rendered like any other.
- A repository whose load failed is not in `repos` (the app files it in `loadFailuresByID`,
  `RepositoriesFeature.swift:3866`, `:4028`; `list` reads only `repositories`,
  `RemoteSnapshotSource.swift:60-64`). So that a client can tell "worktree gone" from "repository
  could not be read", `list` (every `list`, not only the refresh reply) gains
  `"loadFailures":[{"repositoryId":"<id>","message":"<the app's failure text>"}]`, omitted when
  empty. Clients show these repositories as "cannot be read on the Mac: <message>" and keep no stale
  rows for them.

### Errors

`{"t":"error","id":8,"message":"…","code":"<code>"}`

| code | message | when |
|---|---|---|
| `worktree_invalid` | `worktree.delete needs a worktreeId`, `no such worktree` | `worktreeId` missing or empty; unknown, archived (ОВ12), or a pending (`pending:…`) id |
| `worktree_unsupported` | `the main worktree cannot be deleted`, `folders cannot be deleted from the remote`, `the repository is being removed` | main worktree; folder (non-git) entry; repository in `removingRepositoryIDs` |
| `worktree_busy` | `the worktree is busy (being created, archived or deleted)` | row lifecycle not `.idle` (setup script running, archiving, deleting, delete script running), or a remote delete of it is still in flight; also when the re-check after the dirty check finds this (D4) |
| `worktree_dirty` | `the worktree has uncommitted changes or untracked files (N): <up to 5 paths>; commit, stash or remove them on the Mac first` | the dirty check (D4) found at least one status entry, or commits on a detached HEAD that no branch, tag or remote ref holds (message then: `the worktree's detached HEAD has N commits that are on no branch; create a branch for them on the Mac first`) |
| `worktree_failed` | `Delete script failed (exit code N).`, `Delete cancelled.`, `Unable to delete worktree: <git message>`, `The worktree could not be found. It may have already been removed.`, `could not check the worktree for changes: <error>`, `the worktree left the list before it was deleted (removed outside Supacode, or its repository was removed)` | the app reported a failure, the check failed, or the worktree vanished without a delete result |
| `worktree_timeout` | `the delete is still running on the Mac; the worktree may disappear from the list later` | no outcome within `worktreeDeleteTimeout` (300 s) |
| `refresh_timeout` | `the refresh is still running on the Mac; send list again later` | `worktrees.refresh`: no load finished within 60 s |

- `worktree_invalid`, `worktree_unsupported`, `worktree_busy` and `worktree_dirty` are decided by the
  host before the app's delete runs: the Mac shows no alert for them. App failures show the Mac's
  normal alert as well (same code path).
- Old hosts answer `{"t":"error","id":8,"message":"unknown message type: worktree.delete"}` (and the
  same for `worktrees.refresh`) with no `code` (`RemoteHostRouter.swift:296-297`). Clients do not show
  the buttons for an old host anyway (see `list` below); if they get this error, they hide the
  feature for that host.

### list

- `repos[].worktrees[]` gains `"canDeleteWorktree": true|false`: true when the worktree is in a git
  repository (local or ssh) not being removed, is not the main worktree, its row lifecycle is
  `.idle` and no remote delete of it is in flight. Absent (old host) means false: no delete button.
  It does not reflect the dirty state (that is checked at delete time).
- The top-level `list` object gains `"canRefreshWorktrees": true`. Absent (old host) means false: no
  refresh button. A per-host flag is needed because refresh has no per-row anchor; `hello` is not
  used, because `list` is where the client already reads capabilities (`canCreateWorktree`).
- The top-level `list` object gains `loadFailures` (see `worktrees.refresh`).
- `id` is encoded as an explicit `null` when the request had none. Today `RemoteListMessage` uses the
  synthesized `Encodable` and omits a nil `id` (`RemoteProtocol.swift:368-371`); T1 gives it a custom
  `encode(to:)` like `RemoteErrorMessage` (`RemoteProtocol.swift:354-361`). Existing clients are not
  affected (they read `id` as optional).

### Client contract

- К6 Request id: every reply and every error carries the request's `id` (explicit `null` when none).
  Decoder rule (pre-existing, for every message): a frame that is not a JSON object with a string
  `t`, or in which any strictly typed field has the wrong type (e.g. `id` not an integer,
  `worktreeId`, `contentId` not strings, `sameNetwork` not a boolean, `scrollback`, `v` not
  integers), is dropped with no reply, even when the message type does not use that field. Only the
  lenient fields (`repositoryId`, `name`, `cols`, `rows`) never cause a drop.
- К7 Lost connection: a wait belongs to its connection id; `conn.close`, a LAN socket closing and the
  relay socket dropping cancel it (as `worktree.new`). The delete or refresh itself goes on. The
  client shows "Connection lost; the worktree may still disappear from the list", does not retry,
  and sends `list` after reconnecting.
- К8 Reply time: `worktree.delete` within 300 s of receipt plus main-actor slack (the dirty check
  included); client timeout 310 s from sending. `worktrees.refresh` within 60 s; client timeout
  70 s. Router-side errors are immediate. After a timeout the client behaves as in К7.
- К9 Late outcome: after a timeout or lost connection the client cannot learn a late failure (only the
  Mac's alert shows it). A retry of `worktree.delete` while the first still runs gets `worktree_busy`;
  once it has succeeded, `no such worktree`; once it has failed, the retry runs normally.
- К10 Attached terminals: the deleted worktree's terminals end; an attached phone gets `detached` for
  each before or after the `worktree.delete` reply (no order is promised).

## Host behaviour

### Delete

D1. Protocol types (`RemoteProtocol.swift`): `RemoteWorktreeDeleteMessage` (`t`, `id` encoded as
  explicit null like `RemoteErrorMessage`, `worktreeId`, `repositoryId`); `RemoteWorktree` gains
  `canDeleteWorktree: Bool` (through `RemoteSnapshotBuilder.WorktreeInput`); `RemoteListMessage`
  gains `canRefreshWorktrees = true`, `loadFailures`, and an explicit-null `id` encoding. New file
  `RemoteWorktreeDelete.swift` next to `RemoteWorktreeNew.swift`: error codes (reusing the
  `RemoteWorktreeNewErrorCode` values plus `worktree_dirty`, `refresh_timeout`),
  `RemoteWorktreeDeleteRejection` with `code`/`message` and one static
  `check(found:isArchived:isGitRepository:isBeingRemoved:isMain:lifecycleIsIdle:inFlight:)` that the
  request, the post-check re-check (D4) and `canDeleteWorktree` all use, so `list` never offers what
  the host refuses.
D2. Router: `case "worktree.delete"` in `receiveDirect` (`RemoteHostRouter.swift:261-298`) →
  `deleteWorktree(connID:message:)`: resolves `worktreeId`, calls
  `source.requestDeleteWorktree(worktreeID:) -> Result<RemoteWorktreeDeleteStart, RemoteWorktreeDeleteRejection>`.
D3. Source (`RemoteSnapshotSource`), reading with `store.withState(\.repositories)` (as
  `requestNewWorktree`, `RemoteSnapshotSource.swift:227`): finds the repository containing the id;
  applies the D1 check: unknown or archived (`sidebar.status(…).isArchived`, as `requestNewTab` does,
  `:171`) → `worktree_invalid`; folder, main (`state.isMainWorktree`), repository being removed →
  `worktree_unsupported`; lifecycle not `.idle` (`sidebarItems[id:]?.lifecycle ?? .idle`, the same
  rule as `requestDeleteSidebarItems`, `RepositoriesFeature.swift:1123-1124`) or an entry in
  `remoteWorktreeDeletions` (read with `withState`) → `worktree_busy`. On pass it sends one AppFeature
  action `.remoteWorktreeDeleteRequested(worktreeID:, repositoryID:)`.
D4. AppFeature (core, next to the `worktree.new` arms; core runs before the repositories `Scope`,
  `AppFeature.swift:2344`, `:2351`): new state
  `remoteWorktreeDeletions: [Worktree.ID: RemoteWorktreeDeletion]`, keyed by the real worktree id,
  with `enum RemoteWorktreeDeletion: Equatable { case checking(abandoned: Bool);
  case deleting(abandoned: Bool); case deleted; case failed(code: String, message: String) }`.
  - `.remoteWorktreeDeleteRequested`: inserts `.checking(abandoned: false)` and runs the **dirty
    check** (ОВ7, decided) as an effect, unless the worktree is an orphan (`isMissing`: no directory,
    nothing to lose; the Mac also skips the script for it, `RepositoriesFeature.swift:1378`), which
    goes straight to the delete step below.
    - Command: `git -C <worktree working directory> --no-optional-locks status --porcelain=v1 -z
      --untracked-files=all` (new `GitClient` method, e.g. `worktreeChanges(at:) async throws ->
      [String]`, next to `fileStatus(at:)`, `GitClient.swift:1168-1184`, which uses the same flags
      family). Every output entry counts: staged or unstaged changes to tracked files, conflicts,
      and untracked files. Ignored files (`.gitignore`) do not count (no `--ignored`), so build output
      does not block. Dirty = at least one entry.
    - Unpushed commits do **not** block: the branch is never deleted (ОВ6), so its commits stay
      reachable.
    - Detached HEAD (Codex r2 F3): commits reachable only from the worktree's HEAD would become
      unreachable once the worktree (and its reflog) is gone. The same check therefore also runs
      `git -C <path> rev-list --count HEAD --not --branches --tags --remotes`; a count above 0
      makes the worktree dirty. On an attached HEAD the branch itself is in `--branches`, so the count
      is 0 and unpushed commits still do not block. Same host-aware client as the status command.
    - ssh worktree: the same command through the host-aware client, as
      `RepositoriesFeature.gitClient(for:)` picks it (`RepositoriesFeature.swift:721-727`:
      `.ssh(host:)` for a worktree with a host). Its git commands run on the ssh host, the way
      `removeWorktree` runs `git worktree remove` there (`GitClient.swift:1318-1320`, `:1340`), with
      the worktree's remote path. AppFeature reaches the client through the same `GitClientDependency`
      (T1 wires it; not read further here).
    - Result `.remoteWorktreeDeleteChecked(worktreeID:, result:)`: status entries or detached commits →
      `.failed(worktree_dirty, "<message with the count and up to 5 paths, and/or the detached commit
      count>")`; error → `.failed(worktree_failed, "could not
      check the worktree for changes: <localizedDescription>")` (refuse, never delete unchecked);
      clean → re-run the D1 check on the current state (the Mac user may have started a delete,
      archived it, or the repository may be going away during the check), with `inFlight: false`:
      this request's own `.checking` entry must not count as another delete in flight (Codex r2 F1); refused →
      `.failed(<rejection code>, <rejection message>)`; passed → step "delete".
    - Delete step: entry `.deleting(abandoned: <kept>)`, then send
      `.repositories(.deleteSidebarItemConfirmed(worktreeID, repositoryID, background: true,
      keepBranch: true))`, as the CLI does with `bypassConfirmation` (`AppFeature.swift:3886-3887`).
      The Mac shows no confirmation alert: the client confirmed.
    - The check and the delete are not atomic: changes written after the check (by an agent, or by
      the delete script itself) are still removed by the forced `git worktree remove`. Accepted: the
      window is the delete script's run time, the same window the Mac has between its alert and
      the removal.
  - **Branch never deleted (ОВ6, decided).** The branch decision is taken late, in
    `.deleteWorktreeApply` (`RepositoriesFeature.swift:1516-1528`: it reads
    `settingsFile.global.deleteBranchOnDeleteWorktree` and passes it to
    `removeWorktree(worktree, deleteBranch)`), after the delete script, and the script completion
    (`.deleteScriptCompleted`) carries no flag. So the override is state, not a parameter:
    `RepositoriesFeature.State` gains `branchKeepingDeleteIDs: Set<Worktree.ID>`;
    `.deleteSidebarItemConfirmed` gains `keepBranch: Bool = false` (default keeps every existing
    caller unchanged) and inserts the id when true; `.deleteWorktreeApply` passes
    `deleteBranchOnDeleteWorktree && !branchKeepingDeleteIDs.contains(worktree.id)`; the id is
    removed on `.worktreeDeleted`, `.deleteWorktreeFailed`, `.deleteScriptCompleted` with exit ≠ 0
    or nil, and the not-found exits of `.deleteSidebarItemConfirmed` and `.deleteWorktreeApply`. A
    Mac-side delete of the same row cannot interleave (lifecycle guard,
    `RepositoriesFeature.swift:1327-1334`). Reducer tests in T1.
  - Outcome arms (move an entry only from `.deleting`; the CLI ack arms are the model):
    `.repositories(.worktreeDeleted(id, …))` (`AppFeature.swift:1764`) → `.deleted`;
    `.repositories(.deleteWorktreeFailed(message, id))` (`:1864`) →
    `.failed(worktree_failed, "Unable to delete worktree: <message>")`;
    `.repositories(.deleteScriptCompleted(id, exitCode, _))` with `exitCode != 0` (`:1870`) →
    `.failed(worktree_failed, "Delete script failed (exit code N).")` or `"Delete cancelled."`.
  - The two app exits that send no action get explicit outcomes here, read in core before the
    repositories scope runs (so core sees the same state as the reducer's guard):
    `.repositories(.deleteWorktreeApply(id, repositoryID))` when the worktree is not in that
    repository (`RepositoriesFeature.swift:1499-1509`) → `.failed(worktree_failed, "The worktree could
    not be found. It may have already been removed.")`;
    `.repositories(.deleteScriptCompleted(id, 0, _))` while the row is `.deletingScript` and
    `state.repositories.repositoryID(containing: id) == nil` (`:1471-1480`, `:6163`) →
    `.failed(worktree_failed, "The delete script completed, but the worktree could not be found.")`.
  - Backstop for every other way a worktree vanishes (a refresh after a CLI delete, the repository
    removed on the Mac, its load failing): on `.repositories(.delegate(.repositoriesChanged(repos)))`
    every `.checking`/`.deleting` entry whose id is in no repository → `.failed(worktree_failed,
    "the worktree left the list before it was deleted (removed outside Supacode, or its repository
    was removed)")`. `.worktreeDeleted` sets `.deleted` before its own `repositoriesChanged`
    (`RepositoriesFeature.swift:1576-1590`), so a real delete is never misreported.
  - `.remoteWorktreeDeleteConsumed(worktreeID)` removes a settled entry;
    `.remoteWorktreeDeleteAbandoned(worktreeID)` marks a `.checking`/`.deleting` one abandoned, and
    an arm that would settle an abandoned entry removes it instead (same rule as
    `remoteWorktreeCreations`). With the explicit outcomes and the backstop above, every entry
    settles once its delete ends, so it cannot block a later delete of the same path.
D5. Router wait (one `Task` per request in `worktreeDeleteWaits[connID]`, cancelled from the same
  three places as `cancelWorktreeNewWaits`, `RemoteHostRouter.swift:265-266` and the LAN/relay drop
  paths; poll 100 ms; `worktreeDeleteTimeout` = 300 s local and ssh). The probe ends on the entry:
  `.deleted` → success reply; `.failed(code, message)` → error with that code; timeout →
  `worktree_timeout`. Disappearance from the roster alone is never success (it settles as
  `.failed` through the D4 backstop). Every exit sends `.remoteWorktreeDeleteConsumed` or, while
  unsettled, `.remoteWorktreeDeleteAbandoned` first (`awaitWorktreeNew` pattern,
  `RemoteWorktreeNew.swift:175-189`). The reply checks `clients[connID] != nil`.
D6. Busy guard: an unsettled entry blocks a second remote delete of the same worktree until it
  settles, even after the first phone left. A Mac-side delete of the same row is blocked by the
  lifecycle (`.deletingScript`/`.deleting`) once the delete step started; during the dirty check the
  row is still `.idle`, which is why D4 re-checks after it.
D7. ssh repositories: supported as on the Mac (ОВ9, decided). The app's path
  is host-aware (`gitClient(for:)`); the delete script runs in the worktree's (remote) terminal; the
  dirty check runs on the host (D4). The branch is never deleted, so the ssh branch question does
  not arise.
D8. No read-only rule: any authenticated client may delete (as `worktree.new`, `tab.new`).
D9. Path reuse (pre-existing, accepted): the Mac's pipeline looks the worktree up by id (= path)
  again in `.deleteWorktreeApply` after the delete script. If, while the script runs, the worktree is
  removed outside Supacode, a new one is created at the same path and a refresh lists it, the apply
  removes the new one. This is the Mac's own behaviour for its own delete; the remote adds no new
  window (the row is `.deletingScript` throughout). Out of scope; reported as a Mac-side TODO.

### Refresh

R1. Router: `case "worktrees.refresh"` → `refreshWorktrees(connID:message:)`.
R2. Source: `requestRefreshWorktrees() -> RemoteRefreshStart` reads `loadGeneration.started` (R4)
  with `withState`, then sends `.refreshWorktreesRequested` (`AppFeature.swift:571`), the same action
  as the menu, shortcut and palette. Not `.loadPersistedRepositories`: it also clears `state.alert`
  (`RepositoriesFeature.swift:3787`), which the Mac's own refresh does not.
R3. Wait (per connection, cancelled like D5, poll 100 ms, `worktreesRefreshTimeout` = 60 s): until
  `loadGeneration.completed > start`, then reply `source.listMessage(id:)`
  (`RemoteHostRouter.swift:279-280`). Timeout → `refresh_timeout`. Because loads share
  `CancelID.load` with `cancelInFlight: true` (`RepositoriesFeature.swift:1732`, `:3804`, `:4008`,
  `:5124`), our load may be replaced by a later one; a later one also has a generation above
  `start`, and its result is at least as fresh, so "a load started after the request completed" is
  the right condition.
R4. `RepositoriesFeature.State.loadGeneration: (started: Int, completed: Int)` (T1 picks the shape):
  - every arm that starts a git load under `CancelID.load` (`.loadPersistedRepositories` `:3786`,
    `.reloadRepositories` via `loadRepositories` `:5104`, the repository-removal reload `:1712-1732`,
    `.openRepositories` `:4008`) increments `started` and passes the value into its effect; the
    result actions `.repositoriesLoaded` and `.openRepositoriesFinished` gain `loadGeneration: Int? =
    nil` and set `completed = max(completed, value)`;
  - `.repositoriesLoaded` sent **without** a git load (the in-memory removal at
    `RepositoriesFeature.swift:1930-1950`, which reuses the current roster) passes nil and does not
    move `completed`;
  - the nothing-to-load path of `.reloadRepositories` (`:3827-3833`) increments `started` and sets
    `completed = started` at once (explicit completion).
  Neither `isRefreshingWorktrees` (also cleared by `.loadPersistedRepositories` before its load ends,
  `:3788`, and by `.openRepositoriesFinished`, `:4011`) nor a count of `.repositoriesLoaded`
  (also sent without a load, above) proves a fresh load, so neither is used.
R5. ssh: the reply reflects the local load; ssh rosters update through the re-probe the load starts
  (`RepositoriesFeature.swift:3892-3894`, `.remoteRepositoryResolved` `:3928`) and land later; the client sees them in a later `list`
  (ОВ10, decided).
R6. Concurrency: several phones may refresh at once; each waits for its own generation. No busy
  guard: a refresh while one runs restarts the load (`cancelInFlight`), as pressing ⇧⌘R twice does.

## Client UI (web + Android)

- Delete: a trash icon on each worktree row (or in its overflow menu), shown only when
  `canDeleteWorktree` is true; tooltip / content description "Delete worktree". Tap opens a
  confirmation dialog with the owner's text (ОВ5, decided; no new `list` fields for it):
  - text: „Изтрий worktree <име> в <repo>? Папката и терминалите му се затварят; branch-ът остава.“
    (`<име>` = the worktree's `name`, `<repo>` = the repository's `name` from `list`)
  - buttons "Delete worktree" / „Изтрий“ (destructive) and "Cancel" / „Отказ“.
  While waiting: the row shows a spinner and "Deleting…", the button is disabled. Success: toast
  "Deleted <name>", send `list` (or drop the row locally and then `list`); if the phone was attached
  to one of its terminals, go back to the list. `worktree_dirty`: keep the row and show the message
  (it names the files); no force option (ОВ7). Other errors: keep the row, show `message`;
  `worktree_timeout` / client timeout / lost connection: "Still deleting on the Mac, or the
  connection was lost. The worktree may disappear from the list later."
- Refresh: a refresh icon in the list header (next to the host name), shown only when
  `canRefreshWorktrees` is true; tooltip "Refresh worktrees on the Mac". The button is labelled "Refresh" (ОВ11). Pull-to-refresh on Android
  and the web list send `worktrees.refresh` instead of `list` when supported. While waiting: spinner.
  Reply: render the `list` frame, including `loadFailures`. `refresh_timeout`: "The Mac is still
  refreshing; try again later."

## Task split

- T1 Mac host (one worker): `RemoteProtocol.swift` (`RemoteWorktreeDeleteMessage`,
  `canDeleteWorktree`, `canRefreshWorktrees`, `loadFailures`, explicit-null `id` on
  `RemoteListMessage`), new `RemoteWorktreeDelete.swift` (codes, rejection + shared check,
  wait/outcome/reply helpers as in `RemoteWorktreeNew.swift`), `RemoteSnapshotBuilder`
  (`WorktreeInput.canDeleteWorktree`, load failures), `RemoteSnapshotSource` (`requestDeleteWorktree`,
  `worktreeDeletion(_:)`, consume/abandon, `requestRefreshWorktrees`, generation read, all via
  `withState`), `RemoteHostRouter` (two cases, waits, cancel on disconnect), `GitClient`
  (`worktreeChanges(at:)`, local and ssh), `RepositoriesFeature` (`branchKeepingDeleteIDs`,
  `keepBranch` on `.deleteSidebarItemConfirmed`, `loadGeneration` and the generation parameters),
  `AppFeature` (`remoteWorktreeDeletions`, request/checked/consume/abandon actions, the dirty-check
  effect, outcome updates in the existing arms, the two explicit early-exit outcomes, the
  `repositoriesChanged` backstop). Tests with `TestClock`, no `Task.sleep`: success only via
  `.worktreeDeleted`; dirty (tracked change, untracked file) → `worktree_dirty`, ignored file only →
  deletes; detached HEAD with a commit on no ref → `worktree_dirty`, attached branch with unpushed
  commits → deletes; a clean request passes its own re-check (not `worktree_busy`); check error → `worktree_failed`; orphan skips the check; re-check after the check refuses a
  row that became busy; branch kept with the setting on (`removeWorktree` called with
  `deleteBranch: false`) and Mac deletes unchanged; `deleteWorktreeFailed`, script exit ≠ 0 / nil, the
  two early exits, the roster backstop (repository removed during the script) → `worktree_failed`
  and the entry settles; timeout; disconnect while deleting abandons and the busy guard holds until
  settled; every rejection; the shared check drives `canDeleteWorktree`; refresh replies only after a
  load with a newer generation, not after the in-memory `.repositoriesLoaded` nor after
  `.loadPersistedRepositories` clears the flag; nothing-to-load path; timeout; `list` with no `id`
  encodes `"id":null`; `loadFailures`. Then `make test` and `make build-app`.
- T2 protocol doc (`docs/remote-access-protocol.md`): `### worktree.delete` and
  `### worktrees.refresh` after `### worktree.new` (with К6–К10), `canDeleteWorktree`,
  `canRefreshWorktrees`, `loadFailures` and the `id: null` rule in `### list`, the new codes in
  `### errors`, the general decoder rule (К6). Same worker as T1.
- T3 web client, T4 Android client: another session, against this contract only.

## Not confirmed / notes

- That the `.ssh(host:)` `GitClientDependency` runs a `git -C <path> status` on the host the way it
  runs `git worktree remove` there, and how AppFeature gets that client: read from the comments at
  `GitClient.swift:1318-1320` and `RepositoriesFeature.swift:718-727`, not traced into the ssh shell.

## Open questions

- ОВ5 Confirmation wording — decided by the owner (ОП1): generic text, no new `list` fields:
  „Изтрий worktree <име> в <repo>? Папката и терминалите му се затварят; branch-ът остава.“ Dirty
  worktrees are refused by the host (ОВ7).
- ОВ6 Delete the local branch — decided by the owner (ОП2): a remote delete never deletes the local
  branch, whatever `deleteBranchOnDeleteWorktree` says (D4, `keepBranch`). Rejected: follow the Mac
  setting; a per-request field.
- ОВ7 Dirty worktree — decided by the owner (ОП2): refuse with `worktree_dirty` when `git status`
  shows uncommitted changes or untracked files (D4); no force flag in v1. Unpushed commits do not
  block, because the branch is kept (ОВ6). Rejected: mirror the Mac (no check); a `force` field.
- ОВ8 Mac focus — decided by the owner (ОП1): no focus change on the Mac. The host sends
  `background: true` (D4). From the code: `background` only becomes `focusing: !background` for the
  delete script (`RepositoriesFeature.swift:1403-1404`), which the terminal manager passes as
  `select: focusing` for the new script tab inside that worktree's layout
  (`WorktreeTerminalManager.swift:1212-1285`); nothing on this path changes the Mac's selected worktree
  (that only happens in `.worktreeDeleted` when the deleted worktree was the selected one,
  `RepositoriesFeature.swift:1561-1565`, as for every delete). So the script still runs, its tab is
  added but not selected, and the Mac window does not jump. Rejected: `background: false`.
- ОВ9 ssh repositories — decided by the owner (ОП1): supported, through the Mac's host-aware delete
  path; the dirty check runs on the ssh host (D4, D7). Rejected: `worktree_unsupported`.
- ОВ10 Refresh scope for ssh — decided (main, on the earlier recommendation, owner away): v1 replies
  after the local load; ssh results arrive in a later `list` (R5). This accepts Codex r1 F7: right
  after a refresh the client can still show a worktree deleted on an ssh host until its next `list`.
  Rejected for v1: waiting for each `.remoteRepositoryResolved`; an extra client `list` after 10 s.
- ОВ11 Refresh as a message — decided by the owner (ОП1): a separate `worktrees.refresh`; the client
  shows a "Refresh" button; the reply is a fresh `list` frame. Rejected: a flag on `list` (an old
  host would answer with a stale list and the client could not tell), a refresh on every `list`
  (`list` is a synchronous reply, `RemoteHostRouter.swift:279-280`; a git reload per `list` is slow
  and each cancels the previous load), a host-started refresh on connect (can follow later).
- ОВ12 Archived worktrees — decided (main, on the recommendation, owner away): archived worktrees
  cannot be deleted from the remote in v1. `list` leaves them out, `canDeleteWorktree` is false for
  them, and a `worktree.delete` for one gets `worktree_invalid` "no such worktree" (D3). This is a
  stated deviation from the Mac, which can delete them from its archived list
  (`ArchivedWorktreesDetailView.swift:57`); archive is out of scope (ГР1). Rejected for v1: listing
  archived worktrees with `"archived":true` and allowing their delete.
