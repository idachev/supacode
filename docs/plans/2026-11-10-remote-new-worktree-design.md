# Remote new worktree (ЗД11) — design

Status: draft, verified against the code on 2026-11-10 (base `0342212c`). Contract for the Mac host,
the protocol doc, the web client and the Android client. ОВ1–ОВ4 are decided by the owner.

## Goal

Owner: „дали можем да добавим през web app/apk да може да създаваме нов worktree през супакод?“,
„нека е бутон с меню за име на worktree както е на самия supacode на всяко репо - така се знае за
кое репо е“, and (УТ2) „да създаваме и нов таб/темринал“. Each repository in the client's list gets
a "New Worktree" button. It asks for a name, creates the worktree in that repository the way
Supacode's own per-repository button does, and gives the client the worktree's first terminal tab
so it can attach at once.

## What Supacode's own button does (the behaviour to mirror)

- The button: `SidebarListView.swift:441-453` (`plus`, accessibility label and help "New Worktree",
  disabled while the repository is being removed) sends `.createRandomWorktreeInRepository(repositoryID)`.
- `RepositoriesFeature.swift:4245-4320` (`.createRandomWorktreeInRepository`): rejects a missing
  repository, a folder (non-git) entry ("Worktrees are only supported for git repositories.") and a
  repository being removed ("This repository is being removed."), each with a Mac alert titled
  "Unable to create worktree". With the global setting `promptForWorktreeCreation` off it sends
  `.createWorktreeInRepository(nameSource: .random, baseRefSource: .repositorySetting,
  fetchOrigin: settingsFile.global.fetchOriginBeforeWorktreeCreation, …)` (`:4277-4292`); with it on
  it opens the New Worktree prompt (branch name, base ref, title/colour) instead.
- The action every path ends in (`RepositoriesFeature.swift:463-474`):
  `.createWorktreeInRepository(repositoryID:nameSource:baseRefSource:upstream:fetchOrigin:placement:
  pendingID:background:pin:licensePermit:)`; `upstream` defaults to `.automatic`, `placement`,
  `pendingID` and `licensePermit` to nil, `background` and `pin` to false. `nameSource` is
  `WorktreeCreationNameSource` (`:365-368`): `.random` or `.explicit(String)`. The arm lives in
  `worktreeCreateInRepoReducer` (`:1975-2580`).
- The CLI/deeplink path (`AppFeature.swift:2820-2900`): without a branch it sends
  `.createRandomWorktreeInRepository` (so the Mac prompt setting applies); with a branch it sends
  `.createWorktreeInRepository(nameSource: .explicit(branch), …)` directly (`:2886-2898`), which
  bypasses the prompt. Its pending id is `"pending:cli-<n>"` (`AppFeature.swift:4017`, `:2860`).
- License gate first (`RepositoriesFeature.swift:1986-2013`): when `licenseClient.isEnforced`, no
  permit yet, the repository is a local git repository (`host == nil`) not being removed, the arm
  calls `licenseClient.authorizeCreation(resource)` asynchronously (resource
  `"<repositoryID>:<lowercased trimmed name>"` for an explicit name, nil for random) and re-sends
  the same action with the permit, or sends `.worktreeCreationRejected(pendingID:message:
  licenseRequired:)` with the `LicenseError` text. `licenseRequired: true` shows no alert; it opens
  the Mac's purchase sheet (`.delegate(.licenseRequired)` → `.license(.purchaseRequired)`,
  `AppFeature.swift:1617-1619`). `.creationInProgress` ("A worktree with this branch is already
  being created.") rejects a second creation of the same name while the first runs.
- Guards in the arm (`:2016-2058`): missing repository, folder entry, repository being removed;
  each sets a Mac alert and sends `.worktreeCreationRejected(…, licenseRequired: false)`, whose
  arm sets the alert again (`:2568-2574`). An ssh repository (`host != nil`) goes to
  `remoteCreateWorktree` (`:2063-2077`, `RepositoriesFeature+Remote.swift`): no pending row, no
  first tab, no `.worktreeCreated`; it ends in `.remoteWorktreeCreationCompleted` or
  `.worktreeCreationRejected`.
- Local creation (`:2078-2127`): settings come from `@Shared(.settingsFile)` and the repository's
  settings (`:2085-2099`: base directory, base ref, copy ignored/untracked). A `PendingWorktree`
  row with the pending id is appended and, unless `background`, **selected at once** on the Mac
  (`:2117-2124`). Then a `.run` effect streams progress (`.pendingWorktreeProgressUpdated`); it can
  take from one second to minutes (fetch, file copying). No upper bound exists in the app.
- Name checks in that effect (`:2145-2234`), all ending in `.createRandomWorktreeFailed(title:
  message:pendingID:…)`:

  | case | title | message |
  |---|---|---|
  | random: every adjective-animal name used | "No available worktree names" | "All default adjective-animal names are already in use. Delete a worktree or rename a branch, then try again." |
  | explicit, empty after trim | "Branch name required" | "Enter a branch name to create a worktree." |
  | explicit, contains whitespace | "Branch name invalid" | "Branch names can't contain spaces." |
  | explicit, `gitClient.isValidBranchName` false | "Branch name invalid" | "Enter a valid git branch name and try again." |
  | explicit, equals (case-insensitive) a worktree name or local branch | "Branch name already exists" | "Choose a different branch name and try again." |
  | any later git/copy error | "Unable to create worktree" | the error's `localizedDescription` |

  Only the "already exists" check is case-insensitive (`existingNames` and `localBranchNames` are
  lowercased). The explicit name is trimmed before use.
- Success (`.createRandomWorktreeSucceeded(worktree, repositoryID:, pendingID:)`,
  `RepositoriesFeature.swift:4615-4685`): if the Mac user cancelled the pending row
  (`cancelRequestedPendingIDs` holds the pending id) the new worktree is deleted and nothing else
  happens. Otherwise the pending row is replaced by the real worktree (`insertWorktree`,
  `syncSidebar`, same reducer pass), the selection moves from the pending id to the real id,
  the row gets `.focusTerminalRequested` (unless `background`), repositories reload, and the
  delegates `.selectedWorktreeChanged` and `.worktreeCreated` are sent in that order.
- First tab: AppFeature's `.selectedWorktreeChanged` arm (`AppFeature.swift:600-628`) and its
  `.worktreeCreated` arm (`:635-646`) both send `terminalClient.send(.ensureInitialTab(worktree,
  runSetupScriptIfNew: <row lifecycle == .pending>, focusing: …))`; the second is a no-op once the
  tab exists. **Supacode itself opens the first terminal tab** and runs the setup script in it.
  `ensureInitialTab` takes no start grid (`TerminalClient.swift:76`).
- Outcome events AppFeature sees (all in `core`, which runs **before** the repositories `Scope`,
  `AppFeature.swift:2245-2253`, so it still sees the child's pre-action state):
  - `.repositories(.createRandomWorktreeSucceeded(worktree, _, pendingID))` (`:1645-1649`): pending
    id and real worktree; the CLI binds its ack from pending id to `worktree.id` here
    (`bindWorktreeNewAck`, `:4125-4136`).
  - `.repositories(.createRandomWorktreeFailed(title, message, pendingID, …))` (`:1651-1655`).
  - `.repositories(.worktreeCreationRejected(pendingID, message, licenseRequired))` (`:1625-1629`).
  - `.terminalEvent(.tabCreated(worktreeID))` (`:2115-2127`) and
    `.terminalEvent(.initialTabCreationFailed(worktreeID, message))` (`:2144-2152`): these carry
    only the **real worktree id**, no pending id and no tab id.
- Mac alerts: name/git failures and guard rejections show an alert; a cancelled creation
  (`createRandomWorktreeFailed` with the cancel flag) and `licenseRequired` do not.

So the remote flow reuses this first tab (owner УТ2) and never opens a second one.

## Protocol contract

### worktree.new (client → host)

`{"t":"worktree.new","id":7,"repositoryId":"<repository id from list>","name":"feature-x","cols":N,"rows":M}`

- `repositoryId` (string, required): `repos[].id` from `list`.
- `name` (string, required, ОВ2 decided): the branch name. Trimmed by the host. Missing, not a
  string, or empty after trimming → `worktree_invalid` (router check, before the app and git). The
  remote never asks for a random name; clients do not send without a name.
- `cols`, `rows` (optional integers, sent together): resolved by `RemoteTabNewGrid.resolve` as in
  `tab.new`. Best effort only (ОВ1): the Mac shows the new tab, so it takes the Mac pane's size and
  the client learns the real grid from `attached`. Clients send them; they do not resize after.
- `id` (optional integer): echoed in the reply or error (`null` when omitted).
- Limits: `name` at most 200 UTF-8 bytes after trimming (router check, before the app); everything
  else is validated by the app's rules above, not re-implemented in the router.
- The worktree's directory name follows the branch name as in Supacode; no `worktreeName`/`path`
  override, no title/colour, no base-ref choice, no upstream choice in v1.
- Field types: `id` must be an integer (the existing decoder drops a message whose `id` is not, with
  no reply). `repositoryId` and `name` are decoded leniently (a value that is not a string is
  recorded as invalid, not a decode failure), so a request with a valid `id` always gets an answer.

### worktree.new (host → client, success)

`{"t":"worktree.new","id":7,"repositoryId":"…","worktreeId":"<worktree id>","name":"feature-x","tabId":"<tab uuid>","contentId":"<content uuid>"}`

- Same `t` as the request, as `tab.new` does.
- Sent once the worktree exists and its first terminal tab is in the worktree's layout; the client
  attaches to `contentId` itself (it is not attached automatically).
- `worktreeId` and `name` are always present: `worktree.id.rawValue` and `worktree.name` of the
  created worktree, the same values `list` uses for `repos[].worktrees[].id` / `.name`. `name` is
  the trimmed branch name the app used. `tabId` and `contentId` are read from the worktree's layout
  the same way `list` builds `tabs[].id` / `tabs[].contentId` (`RemoteSnapshotSource.tabs(in:
  runtime:)`), so they match the next `list` exactly (T1 tests this).
- `tabId` and `contentId` are omitted together when the worktree was created but its first tab
  failed (`.initialTabCreationFailed`) or was not in the layout within 10 s; the client then shows
  the worktree and may send `tab.new` itself. This is still a success.

### Errors

`{"t":"error","id":7,"message":"…","code":"<code>"}`

| code | when | message |
|---|---|---|
| `worktree_invalid` | `repositoryId` missing, not a string, or unknown; `name` missing, not a string, empty after trimming, or over 200 bytes | router text, e.g. `worktree.new needs a repositoryId`, `no such repository`, `worktree.new needs a branch name`, `the branch name is too long` |
| `worktree_busy` | a remote `worktree.new` for the same repository and (case-insensitive) name is still being created on this host (its phone may have gone) | `a worktree with this branch is already being created` |
| `worktree_unsupported` | folder entry; repository being removed | router text: `worktrees are only supported for git repositories`, `the repository is being removed` |
| `worktree_failed` | any app-side failure: name checks, license, git error, guard rejection, cancelled on the Mac | `createRandomWorktreeFailed`: `"<title>: <message>"` (e.g. `"Branch name already exists: Choose a different branch name and try again."`); `worktreeCreationRejected`: the bare message; Mac cancel: `"Worktree creation was cancelled on the Mac."` |
| `worktree_timeout` | no outcome within 300 s | `worktree creation is still running on the Mac; it will appear in the list when it finishes` |

Router-side errors (`worktree_invalid`, `worktree_unsupported`) never reach the app, so the Mac shows
no alert for them. Old clients ignore unknown codes and show `message` (existing rule). Old hosts
answer `worktree.new` with `{"t":"error","id":7,"message":"unknown message type: worktree.new"}`
and no code (`RemoteHostRouter.swift:288-289`); clients treat that as "this Mac does not support it"
and hide the button for that host (it is hidden anyway, since old hosts send no `canCreateWorktree`).

### list

`repos[]` gains `"canCreateWorktree": true|false`: true for a git repository (local or ssh, ОВ3)
that is not being removed. Absent (old host) means false: the client shows no button.

### Client contract details

- К1 Request id: every reply and every `worktree_*` error carries the request's `id` (explicit
  `null` when the request had none). The one exception is the existing decoder rule: a message whose
  `id` is not an integer (or that is not a JSON object with a string `t`) is dropped with no reply.
- К2 Lost connection: confirmed. A wait belongs to its connection id. `conn.close`, a LAN socket
  closing and the relay socket dropping cancel the waits of those phones (as `tab.new` does), and a
  path switch (LAN ↔ relay) is a new connection id. The host never re-sends a reply and never
  cancels the creation. The client shows "Connection lost; the worktree may still appear in the
  list", does not retry, and after reconnecting refreshes `list`. A retry with the same name gets
  `worktree_busy` while the first still runs, or "Branch name already exists" once it has succeeded.
- К3 Reply time: the host answers within **310 s** of receiving the request: at most 300 s
  local / 290 s ssh (`worktreeNewTimeout`) for the app's outcome (license check included), then at
  most 10 s local / 20 s ssh (`worktreeNewTabTimeout`) for the first tab, each enforced by `RemoteHostRouter.poll`'s raced
  deadline; add main-actor scheduling slack (well under 1 s). Router-side errors are immediate.
  A client timeout of 320 s measured from sending is safe; after it the client treats the request
  like К2.
- К3a Correlating a late result: errors carry only `id`; the client keeps the `repositoryId` and
  `name` it sent. After a timeout or lost connection the outcome is unknown: if the creation
  succeeds, the worktree shows in a later `list` as the entry of that repository whose `name`
  equals the sent name (case-insensitive); if it fails late (git or copy error), it never shows and
  only the Mac's alert reports it. The client never learns that failure. A manual retry with the
  same name is safe: while the first creation still runs the host answers `worktree_busy`
  (Host behaviour 6); once it has succeeded, `worktree_failed` "Branch name already exists"; once
  it has failed, the retry creates normally.
- К4 Ids: `worktreeId` is the same string as `list`'s `repos[].worktrees[].id`: both are
  `Worktree.id.rawValue`, which for a local worktree is its working directory path
  (`RepositoryIdentity.swift:212-218`). `name` is always present. For an ssh repository the id is `host.authority + <normalized remote path>`
  on both sides (`RepositoryIdentity.swift:216-217`, `RepositoriesFeature+Remote.swift:512-519`).
- К5 Next `list` (ssh): when the reply has `tabId`, the worktree was already in the roster, so the
  next `list` has it; a reply without `tabId` may come before the ssh roster reload finishes, and the
  worktree then shows in a later `list`.
- К5 Next `list` (local): yes. `createRandomWorktreeSucceeded` inserts the worktree into the repository and
  rebuilds the sidebar structure in the same reducer pass; the host replies only after that, so any
  `list` the client sends after the reply has it in `repos[].worktrees` and in `rowIds` (or in an
  Active/Pinned section's `worktreeIds`). During creation `rowIds` can already hold the pending row's
  id (`pending:remote-…`, `SidebarStructure.swift:984-987`, `:1315`) with no matching entry in
  `worktrees` (this already happens for Mac-side creations); clients skip row ids they cannot
  resolve.

## Host behaviour

1. Protocol types (`RemoteProtocol.swift`): `RemoteInboundMessage` gains `repositoryId` and `name`
   as lenient optional strings (absent / string / invalid). New `RemoteWorktreeNewMessage`
   (`t`, `id`, `repositoryId`, `worktreeId`, `name`, optional `tabId`, `contentId`; `id` encoded as
   explicit null like `RemoteErrorMessage`). `RemoteRepository` gains `canCreateWorktree: Bool`,
   filled through `RemoteSnapshotBuilder.RepositoryInput` from `RemoteSnapshotSource.repositories()`.
   Error codes as constants next to `RemoteResizeResult.errorCode`; `replyError` gets a `code`
   parameter (it has none today, `RemoteHostRouter.swift:936-938`).
2. Router: `case "worktree.new"` in `receiveDirect` → `newWorktree(connID:message:)`. It checks
   `repositoryId`, the required `name` (trimmed, non-empty, ≤ 200 UTF-8 bytes) and the in-flight
   set (step 6), then calls
   `source.requestNewWorktree(repositoryID:name:) -> Result<Worktree.ID, RemoteWorktreeNewRejection>`.
3. Source check (`RemoteSnapshotSource.requestNewWorktree`): the repository exists in
   `store.repositories.repositories`, `isGitRepository`, and `removingRepositoryIDs[id] == nil`;
   otherwise a rejection mapped to `worktree_invalid` / `worktree_unsupported`. ssh repositories
   pass (ОВ3). On pass it mints `pendingID = WorktreeID(WorktreeID.pendingPrefix + "remote-" +
   UUID().uuidString)` and sends one AppFeature action
   `.remoteWorktreeNewRequested(repositoryID:, name:, pendingID:)`, returning the pending id and
   whether the repository is ssh (`host != nil`).
4. AppFeature (core, next to the CLI arms): new state
   `remoteWorktreeCreations: [Worktree.ID /* pending id */: RemoteWorktreeCreation]` with
   `enum RemoteWorktreeCreation: Equatable { case creating(repositoryID:, name:, abandoned: Bool);
   case created(worktreeID:, name:);
   case tabFailed(worktreeID:, name:); case failed(message:) }`.
   - `.remoteWorktreeNewRequested`: inserts `.creating(repositoryID, name /* trimmed */,
     abandoned: false)`, then sends
     `.repositories(.createWorktreeInRepository(repositoryID:, nameSource: .explicit(name),
     baseRefSource: .repositorySetting, fetchOrigin: settingsFile.global.fetchOriginBeforeWorktreeCreation,
     pendingID:, background: false, pin: false))` (`@Shared(.settingsFile)`; `upstream`,
     `placement`, `licensePermit` default). Never `.random` (ОВ2). This bypasses the Mac prompt
     sheet, as the CLI's explicit-branch path does. The reducer routes an ssh repository to
     `remoteCreateWorktree` with this same pending id (`RepositoriesFeature.swift:2063-2077`). No
     new git logic.
   - The existing arms move an entry **only from `.creating`** (entries never appear from them;
     a settled entry is never overwritten):
     - local success `createRandomWorktreeSucceeded(worktree, _, pendingID)`: if
       `state.repositories.cancelRequestedPendingIDs` contains the pending id (core runs before the
       repositories scope) → `.failed("Worktree creation was cancelled on the Mac.")`, else
       `.created(worktree.id, worktree.name)`;
     - ssh success `remoteWorktreeCreationCompleted(pendingID, worktreeID)` (`AppFeature.swift:1630`)
       → `.created(worktreeID, name)` with the trimmed `name` the host validated, taken from the
       `.creating(…, name:, …)` entry (the action carries no name; the ssh path uses that trimmed
       name as the branch, `RepositoriesFeature+Remote.swift:466-472`);
     - `createRandomWorktreeFailed` → `.failed("<title>: <message>")`;
       `worktreeCreationRejected` (local guards, license, and every ssh failure) → `.failed(message)`;
     - Mac cancel: no arm for `.cliWorktreeAckCancelled(pendingID)`, although `cancelPendingWorktree`
       sends it at once (`RepositoriesFeature.swift:5514`). git keeps running, so the entry stays
       `.creating` (and the busy guard holds) until the creation's terminal action:
       `createRandomWorktreeSucceeded` with the cancel flag (above) or `createRandomWorktreeFailed`
       (cancelled failure) → `.failed`. The phone gets `worktree_failed` only then.
   - `.terminalEvent(.initialTabCreationFailed(worktreeID, _))`: the entry whose value is
     `.created(worktreeID, name)` becomes `.tabFailed(worktreeID, name)` (lookup by real id, as
     `bindWorktreeNewAck` binds the CLI ack). `.tabCreated` needs no arm: the router reads the tab
     from the layout.
   - `.remoteWorktreeCreationConsumed(pendingID)` removes the entry; the router sends it when it
     replies, and on a timeout or cancelled wait when the entry has already left `.creating`.
     `.remoteWorktreeCreationAbandoned(pendingID)` sets `abandoned: true` on a `.creating` entry;
     the router sends it instead on a timeout or cancelled wait while the creation still runs. An
     arm that would move an abandoned entry out of `.creating` removes it instead. So the
     dictionary never leaks, and later outcomes of a removed id find no key and are ignored.
   - Pure state, no NSNotification, no new dependency client.
5. Router wait (one `Task` per request, stored per connection like `tabNewWaits`; poll interval
   100 ms; constants `worktreeNewTimeout` = 300 s local / 290 s ssh, `worktreeNewTabTimeout` =
   10 s local / 20 s ssh, so every request is answered within 310 s):
   - Phase 1: `poll` `source.worktreeCreation(pendingID)` until it is not `.creating`; `.created`
     and `.tabFailed` both end phase 1 (a fast tab failure between two ticks is not missed).
     `.failed` → `worktree_failed`; timeout → `worktree_timeout`.
   - Phase 2, local repository: `poll` for `.tabFailed` (→ reply without tab) or
     `source.firstTerminalTab(of: worktreeID)` — the first terminal tab of
     `terminalManager.layoutState(for:)` in `RemoteSnapshotSource.tabs(in:runtime:)` order — which
     gives `tabId`/`contentId`. Supacode opened that tab itself (`ensureInitialTab`). Timeout →
     reply without tab.
   - Phase 2, ssh repository: the ssh path opens no tab and the worktree enters the roster only
     after the `.loadPersistedRepositories` reload it sends (`RepositoriesFeature+Remote.swift:520-521`).
     The router polls until `worktreeID` is in `store.repositories.repositories`, then opens the
     first tab exactly as `tab.new` does: `source.requestNewTab(worktreeID:startGrid:)` with the
     request's grid (`RemoteTabNewGrid.resolve`), then polls `contentID(ofTab:in:)` +
     `sizeNewTabGrid` as `newTab` does. One 20 s budget covers both; on timeout or a
     `RemoteTabNewRejection` → reply without tab. Existing mechanisms only; nothing new in the app.
   - Every exit path sends `.remoteWorktreeCreationConsumed(pendingID)` or, while the entry is
     still `.creating`, `.remoteWorktreeCreationAbandoned(pendingID)` (step 4) first. A local reply is
     gated on the tab being in the layout only, not on its grid (see ОВ1).
6. In-flight guard (remote requests only; owner МС1 = ОП1): a request whose `(repositoryID,
   lowercased trimmed name)` matches a `.creating` entry in `remoteWorktreeCreations` (abandoned
   or not; read through the source) gets `worktree_busy` at once. The guard is the entry itself, so
   it lives until the creation's outcome settles, not until the phone's wait ends: a retry after a
   reconnect or a timeout while the first creation still runs gets `worktree_busy`. It
   avoids a pre-existing hazard: two creations of one name that both pass the name check can make
   the loser's failure cleanup (`cleanupFailedWorktree`, `RepositoriesFeature.swift:6570-6600`,
   path `<base>/<name>`) remove the winner's worktree. The Mac-side race itself is out of scope (reported separately).
7. A phone disconnect cancels its waits (in `cancelTabNewWaits` or a twin called from the same
   three places: `conn.close`, `lanClosed`, `dropAllClients`) but never the creation; the reply
   checks `clients[connID] != nil` as `newTab` does.
8. Mac side after success, local repository (ОВ1, decided): as with its own button, the pending row
   is selected at once and the selection moves to the real worktree **if it is still on the pending
   row**; the first tab gets focus only on that path (the `.selectedWorktreeChanged` bootstrap with
   `shouldFocusTerminal`; the `.worktreeCreated` call uses `focusing: false`), and the setup script
   runs when the row's lifecycle is still `.pending` and a script is set. If the Mac user selects
   another worktree meanwhile, the Mac keeps that selection; the tab is still created by
   `.worktreeCreated`. The tab takes the Mac pane's size once shown; `cols`/`rows` are not applied
   (`capUnmountedGrid` is a no-op for a view that is or was in a window, and `ensureInitialTab`
   takes no start grid). The client gets the grid in `attached` and later `size` messages.
9. Mac side, ssh repository (ОВ3): exactly as Supacode's own button for ssh: no pending row, no
   selection change, no license gate ("SSH creation is free"), alert only on failure (the
   `worktreeCreationRejected` arm). The phone's first tab is a background tab like `tab.new`, so it
   starts at the requested grid. ssh name checks are the ssh path's own: empty or whitespace →
   "Enter a branch name without spaces to create a worktree."; an existing name fails in git.
10. Failures from the app also show the app's normal Mac alert (same code path), except a
   cancelled creation and a missing license (purchase sheet instead); the client gets the text in
   the error table.
11. Concurrency: each request has its own pending id. Two remote requests for one name: the
   second gets `worktree_busy` (step 6). A remote request racing the Mac user or the CLI: with the
   license enforced (local only) `authorizeCreation` rejects the second ("A worktree with this
   branch is already being created."); otherwise "Branch name already exists" once the first made
   its branch, or git's error. All arrive as `worktree_failed`.
12. No read-only rule applies: any authenticated client may create (as `tab.new`).

## Client UI (web + Android)

- A "+" icon button on each repository header in the repository list, shown only when
  `canCreateWorktree` is true; tooltip/content description "New worktree in <repo name>".
- Tapping opens a small dialog titled "New worktree in <repo name>" with one text field "Branch
  name" (required; Create is disabled while it is empty), monospaced, no autocorrect/capitalisation.
  Inline hints, checked locally before sending: no whitespace; no leading `-`, no `..`, no
  `~^:?*[\`, not ending in `/` or `.lock`; at most 200 UTF-8 bytes (a subset of git's rules; the
  host is the authority); not equal (case-insensitive) to a worktree name already in that
  repository.
- Create sends `worktree.new` with the current terminal grid as `cols`/`rows`. The dialog shows a
  spinner and "Creating…"; closing it only stops waiting on the client (the Mac keeps creating).
- Success: close the dialog, refresh `list`, open the new worktree and attach to `contentId`; without
  `contentId` open the worktree and offer "New tab".
- Error: keep the dialog open with the name, show `message`; for `worktree_timeout`, a client-side
  timeout (К3) or a lost connection (К2) say "Still creating on the Mac, or the connection
  was lost. If it succeeds it will appear in the list; if not, the Mac shows why. You can try again
  with the same name." (К3a). No automatic retry.

## Task split

- T1 Mac host (one worker): `RemoteProtocol.swift` (lenient `repositoryId`/`name`,
  `RemoteWorktreeNewMessage`, `canCreateWorktree`, error codes), `RemoteSnapshotBuilder.swift`
  (`RepositoryInput.canCreateWorktree`), `RemoteSnapshotSource` (`requestNewWorktree`,
  `worktreeCreation(pendingID:)`, `firstTerminalTab(of:)`, `canCreateWorktree`), `RemoteHostRouter`
  (`worktree.new`, waits, timeouts, cancel on disconnect, `replyError` code), `AppFeature`
  (`remoteWorktreeCreations`, `.remoteWorktreeNewRequested`, `.remoteWorktreeCreationConsumed`,
  `.remoteWorktreeCreationAbandoned`,
  the outcome updates in the existing arms). Tests: router/source unit tests with `TestClock`
  (success with tab, success without tab after 10 s, `.tabFailed`, app failure message, timeout,
  disconnect or timeout while creating marks the entry abandoned and the busy guard holds until
  the outcome settles, then the entry is removed; disconnect after `.created` consumes it;
  Mac cancel keeps `.creating` until the terminal action), builder test for `canCreateWorktree`,
  `AppFeature` `TestStore` tests for each outcome arm, the Mac-cancel case, unknown pending ids
  ignored, and consumption. Then `make test` and `make build-app`.
- T2 protocol doc (`docs/remote-access-protocol.md`): new `### worktree.new` section after
  `### tab.new` (incl. the client contract К1–К5), `canCreateWorktree` in `### list`, a note that
  `rowIds` may hold unresolvable pending ids, the new codes in `### errors` (today it says "today
  only `resize_failed`"). Same worker as T1, same commit series.
- T3 web client, T4 Android client: another session, against this contract only.

## Decisions

- ОВ1 Mac selection — decided by the owner („ok сме с това“): `background: false`, mirror
  Supacode's button. The Mac selects the new worktree, the first tab takes the Mac pane's size;
  clients still send `cols`/`rows` and do not resize after. Rejected: `background: true` (the tab
  would keep the client's grid, but the Mac would not show the worktree as its own button does).
  ssh exception: for an ssh repository the Mac does not select the new worktree, as its own button
  does not (`remoteCreateWorktree` has no pending row and no selection); the phone's first tab is
  a background tab at the requested grid (Host behaviour 9).
- ОВ2 Name — decided by the owner: `name` is required; missing or empty → `worktree_invalid`
  before git. No random name from the remote. Rejected: empty = random name.
- ОВ3 ssh repositories — decided by the owner: supported in v1, `canCreateWorktree: true`. The
  host reuses `remoteCreateWorktree` (outcome by pending id through `remoteWorktreeCreationCompleted`
  / `worktreeCreationRejected`) and opens the first tab itself with the `tab.new` mechanism after
  the roster reload lists the worktree (Host behaviour 5, 9). Rejected: `worktree_unsupported`.
- ОВ4 Progress — decided by the owner (ОП1): no progress frames in v1, spinner only. The app's
  stage progress (`WorktreeCreationProgress` via `.pendingWorktreeProgressUpdated`) is not sent.
  Rejected: a `worktree.progress` message in v1.
