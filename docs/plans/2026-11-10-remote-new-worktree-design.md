# Remote new worktree (ЗД11) — design

Status: draft, verified against the code on 2026-11-10 (base `0342212c`). Contract for the Mac host,
the protocol doc, the web client and the Android client. ОВ1 is decided; ОВ2–ОВ4 wait for the owner.

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
- `name` (string, optional): the branch name. Trimmed by the host. Omitted or empty means "pick a
  random adjective-animal name" (ОВ2, recommendation; Supacode's button does this only with its
  prompt off).
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
  the branch the app used (the generated one when `name` was empty).
- `tabId` and `contentId` are omitted together when the worktree was created but its first tab
  failed (`.initialTabCreationFailed`) or was not in the layout within 10 s; the client then shows
  the worktree and may send `tab.new` itself. This is still a success.

### Errors

`{"t":"error","id":7,"message":"…","code":"<code>"}`

| code | when | message |
|---|---|---|
| `worktree_invalid` | `repositoryId` missing, not a string, or unknown; `name` not a string or over 200 bytes | router text, e.g. `worktree.new needs a repositoryId`, `no such repository`, `the branch name is too long` |
| `worktree_unsupported` | folder entry; ssh repository (`host != nil`, ОВ3); repository being removed | router text: `worktrees are only supported for git repositories`, `worktrees on ssh repositories are not supported yet`, `the repository is being removed` |
| `worktree_failed` | any app-side failure: name checks, license, git error, guard rejection, cancelled on the Mac | `createRandomWorktreeFailed`: `"<title>: <message>"` (e.g. `"Branch name already exists: Choose a different branch name and try again."`); `worktreeCreationRejected`: the bare message; Mac cancel: `"Worktree creation was cancelled on the Mac."` |
| `worktree_timeout` | no outcome within 300 s | `worktree creation is still running on the Mac; it will appear in the list when it finishes` |

Router-side errors (`worktree_invalid`, `worktree_unsupported`) never reach the app, so the Mac shows
no alert for them. Old clients ignore unknown codes and show `message` (existing rule). Old hosts
answer `worktree.new` with `{"t":"error","id":7,"message":"unknown message type: worktree.new"}`
and no code (`RemoteHostRouter.swift:288-289`); clients treat that as "this Mac does not support it"
and hide the button for that host (it is hidden anyway, since old hosts send no `canCreateWorktree`).

### list

`repos[]` gains `"canCreateWorktree": true|false`: true only for a git repository with no `host`
that is not being removed. Absent (old host) means false: the client shows no button.

### Client contract details

- К1 Request id: every reply and every `worktree_*` error carries the request's `id` (explicit
  `null` when the request had none). The one exception is the existing decoder rule: a message whose
  `id` is not an integer (or that is not a JSON object with a string `t`) is dropped with no reply.
- К2 Lost connection: confirmed. A wait belongs to its connection id. `conn.close`, a LAN socket
  closing and the relay socket dropping cancel the waits of those phones (as `tab.new` does), and a
  path switch (LAN ↔ relay) is a new connection id. The host never re-sends a reply and never
  cancels the creation. The client shows "Connection lost; the worktree may still appear in the
  list", does not retry, and after reconnecting refreshes `list`. A retry with the same name would
  fail with "Branch name already exists" (or `creationInProgress` while the first still runs).
- К3 Reply time: the host answers within **310 s** of receiving the request: at most 300 s
  (`worktreeNewTimeout`) for the app's outcome (license check included), then at most 10 s
  (`worktreeNewTabTimeout`) for the first tab, each enforced by `RemoteHostRouter.poll`'s raced
  deadline; add main-actor scheduling slack (well under 1 s). Router-side errors are immediate.
  A client timeout of 320 s measured from sending is safe; after it the client treats the request
  like К2.
- К4 Ids: `worktreeId` is the same string as `list`'s `repos[].worktrees[].id`: both are
  `Worktree.id.rawValue`, which for a local worktree is its working directory path
  (`RepositoryIdentity.swift:212-218`). `name` is always present (random names included).
- К5 Next `list`: yes. `createRandomWorktreeSucceeded` inserts the worktree into the repository and
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
   `repositoryId` and the `name` limit, then calls
   `source.requestNewWorktree(repositoryID:name:) -> Result<Worktree.ID, RemoteWorktreeNewRejection>`.
3. Source check (`RemoteSnapshotSource.requestNewWorktree`): the repository exists in
   `store.repositories.repositories`, `isGitRepository`, `host == nil`, and
   `removingRepositoryIDs[id] == nil`; otherwise a rejection mapped to `worktree_invalid` /
   `worktree_unsupported`. On pass it mints `pendingID = WorktreeID(WorktreeID.pendingPrefix +
   "remote-" + UUID().uuidString)` and sends one AppFeature action
   `.remoteWorktreeNewRequested(repositoryID:, name:, pendingID:)`, returning the pending id.
4. AppFeature (core, next to the CLI arms): new state
   `remoteWorktreeCreations: [Worktree.ID /* pending id */: RemoteWorktreeCreation]` with
   `enum RemoteWorktreeCreation: Equatable { case creating; case created(worktreeID:, name:);
   case tabFailed(worktreeID:, name:); case failed(message:) }`.
   - `.remoteWorktreeNewRequested`: inserts `.creating`, then sends
     `.repositories(.createWorktreeInRepository(repositoryID:, nameSource: name.isEmpty ? .random :
     .explicit(name), baseRefSource: .repositorySetting, fetchOrigin:
     settingsFile.global.fetchOriginBeforeWorktreeCreation, pendingID:, background: false, pin: false))`
     (`@Shared(.settingsFile)`; `upstream`, `placement`, `licensePermit` default). This bypasses the
     Mac prompt sheet, as the CLI's explicit-branch path does. No new git logic.
   - The existing arms update **only keys already present** (entries never appear from them):
     `createRandomWorktreeSucceeded`: if `state.repositories.cancelRequestedPendingIDs` contains the
     pending id → `.failed("Worktree creation was cancelled on the Mac.")`, else
     `.created(worktree.id, worktree.name)`; `createRandomWorktreeFailed` → `.failed("<title>:
     <message>")`; `worktreeCreationRejected` → `.failed(message)`;
     `.terminalEvent(.initialTabCreationFailed(worktreeID, _))` → the entry whose value is
     `.created(worktreeID, name)` becomes `.tabFailed(worktreeID, name)` (lookup by real id, as
     `bindWorktreeNewAck` binds the CLI ack). `.tabCreated` needs no arm: the router reads the tab
     from the layout.
   - `.remoteWorktreeCreationConsumed(pendingID)` removes the entry. The router sends it on reply,
     timeout and a cancelled wait, so the dictionary never leaks; later outcomes of a consumed
     id find no key and are ignored.
   - Pure state, no NSNotification, no new dependency client.
5. Router wait (one `Task` per request, stored per connection like `tabNewWaits`; constants
   `worktreeNewTimeout = 300 s`, `worktreeNewTabTimeout = 10 s`, poll interval 100 ms):
   phase 1 `poll` `source.worktreeCreation(pendingID)` until it is not `.creating` (300 s);
   `.failed` → `worktree_failed`; nil (timeout) → `worktree_timeout`. Phase 2 on `.created`:
   `poll` (10 s) for `.tabFailed` (→ reply without tab) or `source.firstTerminalTab(of: worktreeID)`
   — the first terminal tab of `terminalManager.layoutState(for:)` in `RemoteSnapshotSource.tabs(in:
   runtime:)` order — which gives `tabId`/`contentId`. Timeout → reply without tab. Every exit
   path sends `.remoteWorktreeCreationConsumed(pendingID)` first. The reply is gated on the tab
   being in the layout only, not on its grid (see ОВ1).
6. A phone disconnect cancels its waits (in `cancelTabNewWaits` or a twin called from the same
   three places: `conn.close`, `lanClosed`, `dropAllClients`) but never the creation; the reply
   checks `clients[connID] != nil` as `newTab` does.
7. After success the Mac behaves exactly as with its own button (ОВ1, decided): the pending row is
   selected at once, then the real worktree; its first tab gets focus and runs the setup script.
   The first tab therefore takes the Mac pane's size; `cols`/`rows` are not applied
   (`capUnmountedGrid` is a no-op for a view that is or was in a window, and `ensureInitialTab`
   takes no start grid). The client gets the grid in `attached` and later `size` messages
   (existing behaviour).
8. Failures from the app also show the app's normal Mac alert (same code path), except a cancelled
   creation and a missing license (purchase sheet instead); the client gets the text in the table.
9. Concurrency: each request has its own pending id, so two clients (or a client and the Mac user)
   creating in parallel are independent. Two requests for the same name: with the license enforced
   the second is rejected by `authorizeCreation` with "A worktree with this branch is already being
   created."; otherwise it fails "Branch name already exists" if the first already made its branch,
   or with git's error ("Unable to create worktree: …") if both race inside git. All arrive as
   `worktree_failed`. No host-side lock.
10. No read-only rule applies: any authenticated client may create (as `tab.new`).

## Client UI (web + Android)

- A "+" icon button on each repository header in the repository list, shown only when
  `canCreateWorktree` is true; tooltip/content description "New worktree in <repo name>".
- Tapping opens a small dialog titled "New worktree in <repo name>" with one text field "Branch
  name" (placeholder "leave empty for a random name"), monospaced, no autocorrect/capitalisation.
  Inline hints, checked locally before sending: no whitespace; no leading `-`, no `..`, no
  `~^:?*[\`, not ending in `/` or `.lock`; at most 200 UTF-8 bytes (a subset of git's rules; the
  host is the authority); not equal (case-insensitive) to a worktree name already in that
  repository.
- Create sends `worktree.new` with the current terminal grid as `cols`/`rows`. The dialog shows a
  spinner and "Creating…"; closing it only stops waiting on the client (the Mac keeps creating).
- Success: close the dialog, refresh `list`, open the new worktree and attach to `contentId`; without
  `contentId` open the worktree and offer "New tab".
- Error: keep the dialog open with the name, show `message`; for `worktree_timeout`, a client-side
  timeout (К3) or a lost connection (К2) say "Still creating on the Mac (or connection lost); it
  will appear in the list." and do not retry.

## Task split

- T1 Mac host (one worker): `RemoteProtocol.swift` (lenient `repositoryId`/`name`,
  `RemoteWorktreeNewMessage`, `canCreateWorktree`, error codes), `RemoteSnapshotBuilder.swift`
  (`RepositoryInput.canCreateWorktree`), `RemoteSnapshotSource` (`requestNewWorktree`,
  `worktreeCreation(pendingID:)`, `firstTerminalTab(of:)`, `canCreateWorktree`), `RemoteHostRouter`
  (`worktree.new`, waits, timeouts, cancel on disconnect, `replyError` code), `AppFeature`
  (`remoteWorktreeCreations`, `.remoteWorktreeNewRequested`, `.remoteWorktreeCreationConsumed`,
  the outcome updates in the existing arms). Tests: router/source unit tests with `TestClock`
  (success with tab, success without tab after 10 s, `.tabFailed`, app failure message, timeout,
  disconnect cancels the wait and consumes the entry), builder test for `canCreateWorktree`,
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

## Open questions

- ОВ2 Empty name: Supacode's button uses a random name only when its prompt setting is off.
  Recommendation: empty name = random name regardless of the setting, so the client needs no
  settings knowledge and there is no prompt the phone cannot answer.
- ОВ3 ssh repositories (`repository.host != nil`) go through `remoteCreateWorktree`: no pending
  row, no first tab, no `.worktreeCreated`, no license gate, a different completion
  (`.remoteWorktreeCreationCompleted`). Recommendation: `canCreateWorktree: false` and
  `worktree_unsupported` in v1; add later if needed.
- ОВ4 Progress: the app has stage progress (`WorktreeCreationProgress` via
  `.pendingWorktreeProgressUpdated`). Recommendation: no progress frames in v1 (spinner only); add
  `worktree.progress` later if creations prove slow.
