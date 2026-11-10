# Remote new worktree (ЗД11) — design

Status: draft for review, 2026-11-10. Contract for the Mac host, the protocol doc, the web client
and the Android client.

## Goal

Owner: „дали можем да добавим през web app/apk да може да създаваме нов worktree през супакод?“,
„нека е бутон с меню за име на worktree както е на самия supacode на всяко репо“, and (УТ2) „да
създаваме и нов таб/терминал“. Each repository in the client's list gets a "New Worktree" button.
It asks for a name, creates the worktree in that repository exactly as Supacode's own per-repository
button does, and gives the client the worktree's first terminal tab so it can attach at once.

## What Supacode's own button does (the behaviour to mirror)

- The button: `SidebarListView.swift:441-452` (`plus`, help "New Worktree") sends
  `.createRandomWorktreeInRepository(repositoryID)`.
- `RepositoriesFeature.swift:4245-4300`: rejects a missing repository, a folder (non-git) entry
  ("Worktrees are only supported for git repositories.") and a repository being removed. With the
  global setting `promptForWorktreeCreation` off it creates at once with a random adjective-animal
  name; with it on it opens the New Worktree prompt (branch name, base ref, title/colour).
- Both paths end in `.createWorktreeInRepository(repositoryID:nameSource:baseRefSource:fetchOrigin:
  pendingID:background:pin:)` (`RepositoriesFeature.swift:463-474`, arm at `:1975`). The random path
  uses `baseRefSource: .repositorySetting` and `fetchOrigin: settings.fetchOriginBeforeWorktreeCreation`
  (`:4277-4290`); the CLI/deeplink path does the same with `.explicit(branch)`
  (`AppFeature.swift:2876-2898`).
- Validation of an explicit name (`RepositoriesFeature.swift:2176-2236`), all case-insensitive
  against existing worktree names and local branches: empty → "Branch name required"; whitespace →
  "Branch names can't contain spaces."; `git check-ref-format` fails → "Enter a valid git branch name
  and try again."; already exists → "Branch name already exists". The license gate (`:1987-2011`)
  may reject first. Failures arrive as `.createRandomWorktreeFailed(title:message:pendingID:…)` or
  `.worktreeCreationRejected(pendingID:message:)`; both show a Mac alert.
- Base directory, copy-ignored/untracked files and base ref come from the repository's and global
  settings (`:2095-2108`). Creation streams progress and can take from one second to minutes
  (fetch, file copying).
- After success (`.createRandomWorktreeSucceeded`, `RepositoriesFeature.swift:4615-4681`): the
  pending row becomes the real worktree, the Mac selects it (unless `background`) and requests
  terminal focus, reloads repositories and sends `.delegate(.worktreeCreated)`. AppFeature answers
  that with `terminalClient.send(.ensureInitialTab(worktree, runSetupScriptIfNew: <row still pending>, …))`
  (`AppFeature.swift:635-645`): **Supacode itself opens the first terminal tab** (running the setup
  script when one is set). The CLI ack resolves on that tab's `.tabCreated`
  (`AppFeature.swift:2115-2125`) or fails on `.initialTabCreationFailed` (`:2141-2150`).

So the remote flow reuses this first tab (owner УТ2) and never opens a second one.

## Protocol contract

### worktree.new (client → host)

`{"t":"worktree.new","id":7,"repositoryId":"<repository id from list>","name":"feature-x","cols":N,"rows":M}`

- `repositoryId` (string, required): `repos[].id` from `list`.
- `name` (string, optional): the branch name. Trimmed by the host. Omitted or empty means "pick a
  random adjective-animal name", the same as Supacode's button with the prompt off.
- `cols`, `rows` (optional integers, sent together): the grid of the first tab, the same rules as
  `tab.new` (`RemoteTabNewGrid.resolve`: clamped to 20…500 × 5…200; without them, at most 120 × 40).
- `id` (optional integer): echoed in the reply or error.
- Limits: `name` at most 200 UTF-8 bytes after trimming (host check, before git); everything else
  is validated by the app's own rules above, not re-implemented in the router.
- The worktree's directory name follows the branch name as in Supacode; no `worktreeName`/`path`
  override, no title/colour, no base-ref choice in v1.

### worktree.new (host → client, success)

`{"t":"worktree.new","id":7,"repositoryId":"…","worktreeId":"<worktree id>","name":"feature-x","tabId":"<tab uuid>","contentId":"<content uuid>"}`

- Same `t` as the request, as `tab.new` does.
- Sent once the worktree exists and its first terminal tab is in the layout and sized to the
  requested grid; the client attaches to `contentId` (it is not attached automatically).
- `name` is the branch the app actually used (the random one when `name` was empty).
- `tabId` and `contentId` are omitted when the worktree was created but its first tab failed
  (`.initialTabCreationFailed`) or did not appear within 10 s; the client then shows the worktree
  and may send `tab.new` itself. This is still a success.

### Errors

`{"t":"error","id":7,"message":"<the app's own message>","code":"<code>"}`

| code | when |
|---|---|
| `worktree_invalid` | missing/unknown `repositoryId`, `name` over the limit (router checks) |
| `worktree_unsupported` | folder entry, ssh-remote repository (v1), repository being removed |
| `worktree_failed` | any app-side failure: name invalid / exists, license, git error; `message` is the app's text, prefixed by its title (`"Branch name already exists: Choose a different …"`) |
| `worktree_timeout` | no outcome within 300 s; the creation may still finish and show up in `list` |

Old clients ignore unknown codes and show `message` (existing rule). Old hosts answer
`worktree.new` with `error` "unknown message type: worktree.new" and no code: clients treat that as
"this Mac does not support it" and hide the button for that host.

### list

`repos[]` gains `"canCreateWorktree": true|false` (true only for a local git repository not being
removed). Absent (old host) means false: the client shows no button. Clients learn about the new
worktree both from the reply and from the next `list` refresh (unchanged polling).

## Host behaviour

1. Router `case "worktree.new"` → `newWorktree(connID:message:)`, parallel to `newTab`.
2. `RemoteSnapshotSource.requestNewWorktree(repositoryID:name:)` checks the repository (exists, git,
   no `host`, not being removed) and sends
   `.repositories(.createWorktreeInRepository(repositoryID:, nameSource: name.isEmpty ? .random :
   .explicit(name), baseRefSource: .repositorySetting, fetchOrigin: settings.global.
   fetchOriginBeforeWorktreeCreation, pendingID: <remote pending id>, background: false, pin: false))`.
   No new git logic. The pending id is `WorktreeID.pendingPrefix + "remote-" + UUID` so it is unique
   per request. Calling `createWorktreeInRepository` directly bypasses the Mac prompt sheet, as the
   CLI path does.
3. Outcome bridge: AppFeature already observes `createRandomWorktreeSucceeded`,
   `createRandomWorktreeFailed`, `worktreeCreationRejected`, `.terminalEvent(.tabCreated)` and
   `.initialTabCreationFailed` for CLI acks. Add `AppFeature.State.remoteWorktreeOutcomes:
   [Worktree.ID (pending id): RemoteWorktreeOutcome]` filled in those same arms for pending ids with
   the `remote-` marker: `.creating`, `.created(worktreeID, name)`, `.tabReady(worktreeID, tabID)`,
   `.tabFailed(worktreeID)`, `.failed(title, message)`. Pure state, no NSNotification, no new client.
   Consumption via `.remoteWorktreeOutcomeConsumed(pendingID)` so the dictionary never leaks.
4. The router polls that state (as `tab.new` polls the layout) every 100 ms: up to 300 s for
   created/failed, then up to 10 s for the first tab. When the tab is in the layout it calls
   `source.sizeNewTabGrid(contentID:columns:rows:exact:)` exactly like `tab.new`, then replies.
5. A phone disconnect cancels its waits (`cancelTabNewWaits` pattern) but never the creation.
6. After success the Mac behaves exactly as with its own button: the new worktree is selected in
   the Mac window, the first tab gets focus and the setup script runs in it. Because the Mac then
   shows the tab, the terminal takes the Mac pane's size and the client gets a `size` message
   (existing behaviour); the requested grid only holds until then.
7. Failures also show the app's normal Mac alert (same code path); the client gets the same text.
8. Concurrency: each request has its own pending id, so two clients (or a client and the Mac user)
   creating in parallel are independent. Two requests for the same name: the second fails with
   "Branch name already exists" if the first already made its branch, or with git's own error if
   both race inside git; both arrive as `worktree_failed`. No host-side lock.
9. No read-only rule applies: any authenticated client may create (as `tab.new`).

## Client UI (web + Android)

- A "+" icon button on each repository header in the repository list, shown only when
  `canCreateWorktree` is true; tooltip/content description "New worktree in <repo name>".
- Tapping opens a small dialog titled "New worktree in <repo name>" with one text field "Branch
  name" (placeholder "leave empty for a random name"), monospaced, no autocorrect/capitalisation.
  Inline hints, checked locally before sending: no spaces; no leading `-`, no `..`, no `~^:?*[\`,
  not ending in `/` or `.lock` (a subset of git's rules; the host is the authority); not equal
  (case-insensitive) to a worktree name already in that repository.
- Create sends `worktree.new` with the current terminal grid as `cols`/`rows`. The dialog shows a
  spinner and "Creating…" and stays cancellable from the client's side only (closing it does not
  stop the Mac).
- Success: close the dialog, refresh `list`, open the new worktree and attach to `contentId`; without
  `contentId` open the worktree and offer "New tab".
- Error: keep the dialog open with the name, show `message`; for `worktree_timeout` say "Still
  creating on the Mac; it will appear in the list."

## Task split

- T1 Mac host (one worker): `RemoteProtocol.swift` (`name`, `repositoryId` on the inbound message,
  `RemoteWorktreeNewMessage`, `canCreateWorktree` on `RemoteRepository`), `RemoteSnapshotSource`
  (`requestNewWorktree`, repository check), `RemoteHostRouter` (`worktree.new`, waits, timeouts,
  cancel on disconnect), `AppFeature` outcome bridge. Tests: router/source unit tests with
  `TestClock` (success with tab, success without tab, app failure message, timeout, disconnect
  cancels the wait), `AppFeature` `TestStore` tests for each outcome arm and for consumption. Then
  `make test` and `make build-app`.
- T2 protocol doc: new `### worktree.new` section after `tab.new`, `canCreateWorktree` in `list`,
  the new codes in `### errors`. Same worker as T1, same commit series.
- T3 web client, T4 Android client: another session, against this contract only.

## Open questions

- ОВ1 Mac selection: Supacode's button selects the new worktree on the Mac, `tab.new` does not
  change the Mac window. Recommendation: mirror the button (`background: false`), as the owner asked
  for "exactly as Supacode"; switch to `background: true` only if the owner finds it disruptive.
- ОВ2 Empty name: Supacode's button uses a random name only when its prompt is off. Recommendation:
  empty name = random name regardless of the setting, so the client needs no settings knowledge.
- ОВ3 ssh-remote repositories (`repository.host != nil`) go through `remoteCreateWorktree` with a
  different completion path. Recommendation: `canCreateWorktree: false` and `worktree_unsupported`
  in v1; add later if needed.
- ОВ4 Progress: the app has stage progress (`WorktreeCreationProgress`). Recommendation: no progress
  frames in v1 (spinner only); add `worktree.progress` later if creations prove slow.
