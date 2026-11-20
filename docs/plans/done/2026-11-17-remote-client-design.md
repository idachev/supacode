# Remote client: Supacode as a window onto another Mac — design

Date: 2026-11-17. Status: implemented and merged (the plan `docs/plans/done/2026-11-17-remote-client-app.md`, Tasks 1-16, merged into `idachev-supacode` on 2026-11-20; the fork notes are in `docs/fork.md` → "Remote Client Window", how to use it in `docs/remote-access.md` → "Use another Mac from Supacode"). Builds on
`docs/plans/done/2026-11-03-remote-access-android-design.md` and
`docs/plans/2026-11-10-remote-multi-host-design.md`. The wire protocol is
`docs/remote-access-protocol.md`; operations are `docs/remote-access.md`. Stage 1 (a Node `attach`
process that shows one remote tab in a local terminal) lives in the repo `supacode-remote`:
`docs/plans/done/2026-11-17-ghostty-attach-design.md`.

## Intent

Ivan runs this fork of Supacode on more than one Mac. When he sits at laptop B he wants to work in
the Supacode of Mac A as if he sat in front of it: its sidebar, its tabs and splits as real Ghostty
terminals, new tabs and worktrees, and its "agent is waiting" notifications. The link is the
existing remote access protocol (the Cloudflare relay plus the LAN shortcut), the same one the
Android app and the web app use.

Why inside Supacode and not a separate native app (owner, 2026-11-17): Supacode already has
GhosttyKit, the UI, and the host side of the protocol.

Why not the existing ssh repositories (owner, 2026-11-17): ssh is set aside. The goal is a mirror of
the other Supacode, not that Mac's repositories mixed into the local ones.

## Owner decisions (fixed)

- **ФМ1.** The remote Mac is shown in its own window. The local main window is not changed.
- **ПД1.** The connection lives in Supacode as a Swift client of the protocol. A remote tab is a
  normal Ghostty surface whose process is a thin byte pipe (a new command of the bundled `supacode`
  CLI) between the terminal and the app.
- **КЧ1.** The client reads the connection key from the existing file
  `~/.config/supacode/remote-client-key.txt` (mode 0600, `<relay host>/<client key>`). No Keychain,
  no new settings field for the key.
- **ОБ1–ОБ5** are the scope of the first version (see Goals). **ПС1–ПС5** come later (see Non-goals).
- **ИЗ3.** A lost connection is visible above the terminal, not only as a frozen screen.
- **АВ2.** An automatic resize sends Ctrl+L only to a tab where an agent runs (owner, 2026-11-17;
  see ПТ6).
- **АВ1.** In the remote window the size of a remote tab follows the laptop's pane automatically
  (owner, 2026-11-17). This replaces ЗД12 for the Supacode client only. The phone and the web app
  keep ЗД12: there the size belongs to the Mac and `resize` goes out only on an explicit action
  (author's reading of the owner's answer; see АР10).
- Protocol changes are written first in `docs/remote-access-protocol.md` here, then mirrored in
  `supacode-remote` (Android `protocol/Protocol.kt`, `ProtocolCodecTest`, web `web/src/protocol.mjs`).

## Goals (first version)

- **ОБ1.** The remote window's sidebar shows Mac A's sidebar: Active, Pinned, repository groups,
  repositories, worktree rows with agent state, and a filter field.
- **ОБ2.** Tabs and splits are arranged as on Mac A. Every tab is a real Ghostty surface.
- **ОБ3.** Actions: new tab, close tab, select tab, split a pane, close a pane, new worktree, delete
  worktree, refresh worktrees. A tab's size follows its pane (АВ1).
- **ОБ4.** "Agent is waiting" notifications from Mac A appear on laptop B.
- **ОБ5.** A banner above the terminal says when there is no connection (ИЗ3).

## Non-goals (later)

- **ПС1.** File explorer and the changes / diff view for Mac A.
- **ПС2.** Pull request badges and checks.
- **ПС3.** Repository scripts (setup, run) as buttons.
- **ПС4.** "Open in editor" and Finder for Mac A's paths.
- **ПС5.** Mac A's settings, and the command palette for Mac A.
- **ПС6.** Layout edits beyond ОБ3: moving a tab between panes, dragging a split divider, renaming
  a tab, reordering tabs, pane windows.
- **ПС7.** Dropped: АВ1 makes font scaling unnecessary.
- **ПС8.** Several remote windows at once (one per Mac; the owner moved this part into the plan as
  stage ЕТ6, Task 16, on 2026-11-19), and notifications while the remote window
  is closed.
- A host older than this design (see ПТ0). Both Macs run the owner's fork.
- Any change to the relay Worker. Every new message is a client ⇄ host application message, which
  the relay forwards without parsing.

## Anti-goals

- A second answer to a terminal query. Ghostty on Mac A already answered in the PTY; the local
  surface must never answer the same query as input (the stage 1 `QueryFilter` problem).
- A resize loop: two clients, or a client and Mac A's own pane, that keep taking a tab's size
  from each other (see ПТ6).
- Remote repositories, worktrees or ids entering `RepositoriesFeature`, `TerminalsFeature` or any
  persisted local file (`routes.json`, `layoutsFile`, `sidebarState`).
- Content-specific state in `LayoutFeature` (see `CLAUDE.md`, the layout-layer rule).
- The relay URL or a key in git, in a log line, or in a UI text.

## Constraints found in the code

- **НХ1.** The host keeps one attachment per connection (`clients[connID]` in
  `supacode/Features/RemoteAccess/RemoteHostRouter.swift`). The relay allows 20 connects per IP per
  minute and the LAN server 8 peers, so one connection per visible tab does not scale.
- **НХ2.** `list` carries a flat tab list per worktree: no split tree. The host never sends `list`
  by itself (`RemoteProtocol.broadcastConnID` has no caller); clients poll. There is no `tab.close`.
- **НХ3.** A local pane rarely has the remote grid's size, and Mac A's own pane takes its size back
  when its layout changes (`docs/remote-access-protocol.md`, `resize`).
- **НХ4.** libghostty has one termio backend, `Exec` (`ThirdParty/ghostty/src/termio/backend.zig`).
  `Termio.processOutput` is not in the C API. A surface always needs a child process.
- The app has one main `Window` scene and one `AppFeature` store (`supacode/App/supacodeApp.swift`).
- The CLI socket (`AgentHookSocketServer`) is one request and one response per connection with a
  5 s read timeout; it cannot carry a long-lived byte stream.
- The model for repositories has two location kinds (`local`, ssh `remote(RemoteHost)`), and about
  75 call sites branch on `host == nil`. A third kind would touch all of them; ФМ1 avoids that.
- `GhosttySurfaceView` resizes the PTY and the emulator grid in one step. It already holds a
  requested grid against layout (`RequestedGridHold`, used by the host's `resize`), but releases it
  on the next pane change.
- `CLAUDE.md` asks for a pfw (pointfree) skill consult before a big TCA feature. No such skill is
  installed in this environment; the plan follows the TCA rules in `CLAUDE.md` instead.

## Approaches

| | Approach | Trade-off |
|---|---|---|
| **ПД1** (chosen) | Swift client in Supacode; a surface runs a CLI byte pipe to the app | One connection and one state for sidebar, banner and notifications; no outside dependency; about 1000 lines of `web/src/*.mjs` logic are ported to Swift |
| ПД2 | Every tab runs the Node `attach` with its own connection | Fastest to a first picture, but one connection per tab (НХ1), Node and the `supacode-remote` checkout become app dependencies, and the banner needs a side channel from every process |
| ПД3 | A new termio backend in Ghostty, no process | No helper process, but a sixth Ghostty patch in the termio core and upkeep on every Ghostty update; `QueryFilter` is still needed |

The owner picked ПД1. ПД3 can replace only the pipe later; the client stays.

For the window form the owner picked ФМ1 over one window with a switcher (ФМ2: local tabs hide
while Mac A shows) and remote repositories in the local sidebar (ФМ3: the costliest, and not a
mirror).

## Protocol changes

All changes are additive and optional, so `v` stays `1` (the version rule in the protocol doc).
Old clients (Android, web, `phone-sim.mjs`) keep working unchanged.

### ПТ0. Capabilities in `hello`

host → client `hello` gains an optional string array:

```json
{"t":"hello","v":1,"host":"Office Mac","hostId":"…",
 "caps":["attach.keep","watch","layout","tab.close","pane.split","pane.close","resize.hold"]}
```

A client ignores values it does not know. The Supacode client needs all seven; when one is missing
(an older host) it shows "<Mac name> runs an older Supacode" in the remote window and attaches
nothing.

### ПТ1. Several attachments on one connection

- `{"t":"attach","id":2,"contentId":"…","scrollback":500,"keep":true}`. With `keep:true` the
  connection's other attachments stay. Without `keep` (or `false`) the host behaves as today:
  every other attachment of that connection is detached.
- At most 16 attachments per connection. One more gets
  `{"t":"error","id":2,"code":"attach_limit","contentId":"…","message":"too many attached terminals"}`
  and changes nothing.
- `attach` of a content the connection already has restarts that stream (a new `attached` and
  screen).
- `detach` stops the named content only. Closing the socket detaches all.
- `resize` is accepted for any content the connection is attached to. A pending resize is cancelled
  by a newer `resize` of that terminal or by the requester's `detach` of that content. An `attach`
  of the same content again restarts its stream and cancels the pending resize that connection asked
  for there (its hold stays); an `attach` with `keep:true` of another content cancels nothing.
- `out`, `size`, `detached` and `input` already carry `contentId` and do not change.

### ПТ2. The layout in `list`

Each worktree in `list` gains an optional `layout` (omitted when the worktree has no tabs):

```json
"layout":{
  "mode":"tabsPerSplit",
  "activeGroupId":"main",
  "groups":[
    {"id":"main","focusedPaneId":"<pane id>","zoomedPaneId":"<pane id>",
     "tree":{"split":{"direction":"horizontal","ratio":0.5,
                      "left":{"pane":"<pane id>"},"right":{"pane":"<pane id>"}}}}
  ],
  "panes":[{"id":"<pane id>","tabIds":["<tab uuid>"],"selectedTabId":"<tab uuid>"}]
}
```

- `mode` is the raw `TerminalLayoutMode` (`tabsPerSplit` or `splitPerTab`).
- `groups` mirrors `PaneLayout`: in `tabsPerSplit` exactly one group with the id `main`; in
  `splitPerTab` one group per top-level tab, in strip order (`groupOrder`), the active one included.
- `tree` is a node: `{"pane":"<pane id>"}` or `{"split":{direction, ratio, left, right}}`.
  `direction` is `horizontal` or `vertical` (`SplitDirection`); `ratio` is `SplitTree.Split.ratio`,
  the `left` child's share of the split (`SplitView.swift` scales the first region by it).
- `zoomedPaneId` is present only when that group's tree is zoomed on a single pane.
- `panes` is flat: every pane of every group. `tabIds` refer to the worktree's `tabs[].id`. A
  client skips ids it cannot resolve.
- The existing `tabs` array does not change, so old clients are unaffected.

### ПТ3. Pushed `list`: `watch`

- client → host `{"t":"watch","id":5,"on":true}`; host → client `{"t":"watch","id":5,"on":true}`.
- While a connection watches, the host sends it a full `list` frame with `"id":null` whenever the
  snapshot differs from the last `list` it sent to that connection. At most one push per 250 ms per
  connection, trailing edge, so the last state always arrives.
- Tab titles are the exception. `tabs[].title` is the live reported title
  (`TabTitle.resolved` in `RemoteSnapshotSource.tabs`), and an agent TUI rewrites it several times a
  second. A snapshot that differs from the last one sent only in tab titles is pushed at most once
  per 2 s per connection (trailing edge). Any other difference follows the 250 ms rule and carries
  the current titles.
- `on:false` stops it. The watch ends with the connection; a LAN ⇄ relay path switch is a new
  connection, so the client sends `watch` again.
- The host does no periodic work while no connection watches. How it detects a change (a tick that
  compares the built `RemoteListMessage`, which is `Equatable`, or observation) is the builder's
  choice; time comes from an injected clock.

### ПТ4. Layout actions

Every reply and error carries the request's `id`. The Mac shows no confirmation (the client
confirmed) and does not change which worktree its window shows.

- **`tab.close`** — `{"t":"tab.close","id":6,"tabId":"<tab uuid>"}` →
  `{"t":"tab.close","id":6,"tabId":"…","worktreeId":"…"}`. Closes that tab and ends its terminal,
  as the Mac's own close does (a pane left without tabs collapses). Clients attached to it get
  `detached`. Errors: `tab_invalid` (unknown tab), `tab_failed`.
- **`pane.split`** —
  `{"t":"pane.split","id":7,"paneId":"<pane id>","direction":"horizontal|vertical"}`
  → `{"t":"pane.split","id":7,"worktreeId":"…","paneId":"<new pane id>","tabId":"…","contentId":"…"}`
  once the new terminal can be attached. `direction` is the two-way `SplitDirection` that the
  pane-addressed command takes (`TerminalClient.Command.splitPane`, the CLI's `pane split`); the
  new pane lands where that command puts it. The four-way direction exists only for focused-pane
  menu commands and is not on the wire. There is no start size (that command has none): the new
  terminal takes its pane's size on the Mac, and a client that wants its own sends `resize` after
  `attached`. Errors: `pane_invalid` (unknown pane or direction), `pane_failed` (also when the
  terminal does not start within 10 s).
- **`pane.close`** — `{"t":"pane.close","id":8,"paneId":"<pane id>"}` →
  `{"t":"pane.close","id":8,"paneId":"…","worktreeId":"…"}`. Closes every tab of that pane. Errors:
  `pane_invalid`, `pane_failed`.
- **`tab.new`** gains an optional `paneId`: the pane that receives the tab. Ignored in
  `splitPerTab`, where a new tab is a new top-level tab. Without it the host picks as today.
- Old hosts answer `unknown message type: …` with no `code`; ПТ0 keeps the client from sending
  these to them.
- Decoder rule for the new fields. Strict (a wrong type drops the message with no reply, as for
  `contentId` today): `keep` and `on` (booleans), `tabId` and `paneId` (strings). Lenient (answered
  with an error): `direction` (a value of another type or an unknown string gives `pane_invalid`).

### ПТ6. A held size: `resize` with `hold`

Today a requested size lasts until the Mac's own pane for that tab changes layout. A client whose
pane decides the size (АВ1) would have to ask again after every such change, and two such clients
would take the size from each other without end. So the size gets an owner.

- `{"t":"resize","contentId":"…","cols":N,"rows":M,"hold":true}`. The clamp, the replies,
  `resize_failed` and the wake of a terminal without a live surface stay as in today's `resize`.
- **Ctrl+L only where an agent runs** (АВ2). After a confirmed `resize` with `hold:true` the host
  sends Ctrl+L once only when the tab's chrome lists at least one agent
  (`TerminalTabChrome.agents`, the data `list` sends as `tabs[].agents`), whatever its activity. A
  tab without an agent (a shell, `vim`, `less`) gets none: the resize goes out by itself on every
  window drag, and a typed 0x0C in a program that does not expect it is wrong; the PTY's size change
  (SIGWINCH) already makes such programs redraw. Without `hold` the Ctrl+L stays as today.
- How a tab "has an agent": the agent's hooks write OSC 3008 into the tab's terminal on the Mac
  (session start, busy, idle, awaiting input, stop, compacting, error, session end); Supacode files
  each event under the receiving surface (`AgentPresenceFeature`), and a liveness sweep every 2 s
  drops an agent whose local process is gone. So an agent that exits without `session_end` leaves
  the list within about 2 s.
- **Held.** While a size is held, a layout change of the Mac's own pane (a window resize, a split,
  the pane shown or hidden, zoom, the tab hibernated and woken) does not change the PTY's size;
  the Mac's pane shows the held grid as it shows a requested size today.
- **One owner.** The hold belongs to the connection that asked last. A newer `resize` of that
  terminal from any connection wins: with `hold:true` the hold moves to it, without `hold` the hold
  ends and the size is unowned as today.
- **Release.** The hold ends at once when its owner sends `detach` for that content or attaches
  another content without `keep`. When the owner's connection closes or its stream fails
  (`conn.close`, a LAN socket closing, the relay socket dropping), the hold stays for 30 s without
  an owner; a `resize` with `hold:true` in that time takes it over, and with the same size the PTY
  never changes. After 30 s without one the hold ends. So a short network drop or a LAN ⇄ relay
  switch does not reflow the terminal twice.
- When a hold ends with no newer request, the Mac's pane size returns and every attached client
  gets `size`.
- A client never answers a `size` it did not ask for with a new `resize`. It sends `resize` only
  when its own pane's grid changes and after its own `attached`. This rule, not the host, is what
  prevents a loop between two holding clients.
- `hold` is a strict boolean (decoder rule). Without it the message means what it means today, so
  the phone and the web app are unaffected.

### ПТ5. No new row fields

Path, repository kind and ssh host are not sent in the first version: the sidebar in ОБ1 does not
show them (author's call; add them with ПС1–ПС4).

## Client design (Supacode)

New code lives in `supacode/Features/RemoteClient/` (fork-only, listed in `docs/fork.md`). Host
changes stay in `supacode/Features/RemoteAccess/`.

### Connection (ОР2 = ПД1)

- **КЛ1. Key and relay address** come from the file of КЧ1. `RemoteAccessConfig.loadClientKey()`
  returns only the key (the part after the last `/`); the client adds a sibling parser for the relay
  host in front of it. No file, or no relay host in it: the remote window shows how to add it (copy
  `remote-client-key.txt` from a hosting Mac, mode 0600) and does not connect.
- **КЛ2. Relay path.** `wss://<relay>/client?host=<hostId>` with `Authorization: Bearer <client key>`,
  text `ping` every 30 s, `relay` messages handled by the edge rule (send `hello`, `list`, `watch`
  and the attaches only on `hostOnline` false → true). Reconnect with backoff, never more than
  the relay's 20 connects per minute.
- **КЛ3. LAN path.** When `hello` carries `lan`: check `fpMac` (HMAC-SHA256 with the client key over
  `supacode-lan-fp-v1:` + `fp`), then `wss://<addr>:<port>/lan`, TLS 1.3 only, accepted only when the
  SHA-256 of the leaf certificate's DER equals `fp`, the key in `Authorization`. A `hello` whose
  `hostId` differs from the selected Mac gets no LAN attempt. The relay socket stays as an idle
  fallback (ping only). The server side already uses Network.framework
  (`RemoteLANServer.swift`); the client uses the same stack.
- **КЛ4. Stream gate.** A port of `TerminalStreamGate` (`supacode-remote/web/src/stream-gate.mjs`),
  one gate per attached content: a new path takes a stream over only at its `attached`; frames from
  another path, a dropped socket or an older attach never reach the terminal. After a path switch
  the client re-sends `watch` and re-attaches every open content with `keep:true`.
- **КЛ5. Decoding.** Client models tolerate a missing optional field and an unknown `status`,
  `activity`, `kind` or `code` string (a new value from the host must not break the whole `list`).
  Whether these reuse the host's `Encodable` types or are separate types is the builder's choice.
- **КЛ6. Lifetime** (author's call): the client connects when the remote window opens and
  disconnects when it closes. No connection and no notifications while the window is closed (ПС8).
- **КЛ7. Logging** through `SupaLogger`; never the key, the relay address or a Mac's name.

### Which Mac (multi-host)

- **МХ1.** One selected Mac at a time, saved as plain app storage (`@Shared`, not secret). The rules
  are the phone's: a saved selection never changes by itself; with nothing saved the client
  connects unbound, reads `hosts`, selects the Mac when exactly one other Mac is online, and shows
  the picker otherwise.
- **МХ2.** The picker leaves out this Mac itself (its own `hostId`, `RemoteAccessConfig.hostID`).
- **МХ3.** Switching the Mac closes both sockets, clears the window's state and reconnects with the
  new `host`.
- **МХ4.** A relay without `hosts` (single-host mode) connects without `host`, as the phone does.

### Window (ОР1 = ФМ1)

- **ПЗ1.** A new `Window` scene (its own id in `WindowID`) with its own store for a new
  `RemoteClientFeature`. It is opened from a menu item ("Open Remote Mac…") with a tooltip and a
  hotkey, published through `FocusedAction` like the other menu actions.
- **ПЗ2.** The title shows the Mac's name and the path in use ("LAN" / "Relay"); clicking the name
  opens the picker.
- **ПЗ3.** Remote state never enters `RepositoriesFeature` or `TerminalsFeature`. Ids from Mac A
  stay inside the remote window's state, so they cannot collide with local ids.
- **ПЗ4.** Menu commands (new tab, close, split) act on the remote window when it is the key
  window: the window publishes its own focused actions, which send protocol requests.

### Sidebar (ОБ1)

- **СЛ1.** New views render `list.sections` in order (`active`, `pinned`, `group`, `repository`),
  rows by `rowIds`, exactly as the protocol describes for clients. `loadFailures` rows show
  "cannot be read on the Mac: <message>".
- **СЛ2.** A row shows the worktree name, branch, `title`, `status`, the `working` state and the
  agents with their activity. Existing leaf views are reused only where they take plain values; no
  `Repository` / `Worktree` / `SidebarItemFeature` state is built for remote rows.
- **СЛ3.** The filter field filters locally by repository, worktree and tab title.
- **СЛ4.** Selecting a worktree is local: Mac A does not change what its own window shows.
- **СЛ5.** Actions: "New Worktree" on a repository with `canCreateWorktree` (asks for the branch
  name, sends `worktree.new`, follows contract К1–К5); "Delete Worktree…" on a row with
  `canDeleteWorktree` (confirmation on the laptop, `worktree.delete`, the `worktree_dirty` message
  shown as is, К6–К10); "Refresh Worktrees" (`worktrees.refresh`).

### Tabs and splits (ОБ2, ОБ3)

- **РЗ1. The layout is Mac A's.** The client projects `layout` (ПТ2) into what it renders. It
  never edits the topology locally: a structural action (new tab, close tab, split, close pane)
  becomes a protocol request, and the picture changes when the next `list` arrives (ПТ3).
- **РЗ2. Selection is local** (author's call): the selected tab in a pane, the active top-level tab
  (`splitPerTab`), the focused pane and zoom are the laptop's own and are not sent. The first
  `list` seeds them from Mac A (`selectedTabId`, `activeGroupId`, `focusedPaneId`, `zoomedPaneId`);
  later pushes keep the laptop's choice while that tab, group or pane still exists.
- **РЗ3. Both layout modes** render: `tabsPerSplit` and `splitPerTab` (the fork's mode).
- **РЗ4. Close confirmation** is on the laptop: closing a tab whose `working` is true, or a pane,
  asks first; then `tab.close` / `pane.close`.
- **РЗ5. Attached set.** The client attaches (`keep:true`) the selected tab of every visible pane of
  the selected worktree, and detaches a tab 30 s after it stops being visible, so a quick switch
  back needs no redraw. It never holds more than 16 (ПТ1); the least recently visible goes first.
- **РЗ6. How it is rendered** is the builder's choice, within these limits: reuse the
  content-agnostic pieces (`ContentRuntime`, `ContentHostView`, `SplitView`, the tab strip views)
  with a separate `ContentRuntime` instance for the remote window; if `LayoutFeature` is reused as
  the view state, a wrapping reducer must stop every structural action from changing the layout
  locally; a small dedicated remote layout feature is equally acceptable. No new state or actions
  in `LayoutFeature`, and upstream files change as little as possible (fork merges).

### Remote terminal (ОР3 = ПД1)

- **ТР1. Surface.** A remote tab is a `GhosttySurfaceView` whose `command` is
  `<bundled supacode CLI> remote-pipe <contentId>`, with no local zmx (`bypassZmx`) and shell
  integration off. The session lives on Mac A; nothing about it is persisted on the laptop, and
  the launch reaper never sees it.
- **ТР2. Pipe server.** The app listens on its own unix socket for pipes (mode 0600, beside the CLI
  socket; a separate listener because the CLI socket is request/response). The surface's
  environment carries the socket path and a one-time token.
- **ТР3. Pipe command.** `supacode remote-pipe` (hidden from the CLI help) puts its terminal in raw
  mode, connects, sends one header line (token, content id), then copies stdin → socket and
  socket → stdout until either end closes. It ignores SIGWINCH, restores the terminal on exit and
  exits 0.
- **ТР4. Out path.** `out` bytes pass a Swift port of `QueryFilter`
  (`supacode-remote/web/src/query-filter.mjs`, same list and the same split-sequence state: DA1/2/3,
  DSR / DECDSR, DECRQM, XTVERSION, every `CSI … t`, DECRQSS, XTGETTCAP, OSC 4/10/11/12 with `?`,
  kitty `CSI ? u`) and then go to the pipe. The filter also drops OSC 3008 (Supacode's agent
  presence signal), so a remote agent never enters the laptop's own agent presence; remote agent
  state comes from `list` only.
- **ТР5. In path.** Bytes from the pipe go out as `input` for that content. Ghostty encodes keys,
  mouse and paste according to the modes the remote program set through `out`.
- **ТР6. A new `attached`** (first attach, reconnect, path switch): before the redraw the client
  writes `CSI 3 J`, `CSI 2 J`, `CSI H` to the pipe, so the history is not doubled, and pins the grid
  (ТР7).
- **ТР7. The local grid is the remote grid.** The local surface always has exactly the `cols` ×
  `rows` of the last `attached` / `size`, never the pane's own grid: a persistent variant of
  `RequestedGridHold` that layout and window changes do not release. So the picture is right even
  while a resize is on its way or was refused.
- **ТР8. Automatic resize** (АВ1, ПТ6). The client computes the grid that fits the tab's local pane
  at the laptop's font. It sends `resize` with `hold:true` when that grid differs from the remote
  one: after its own `attached`, and when the pane's fitting grid has changed and stayed the same
  for 200 ms (a window resize, a new or closed split, zoom, a font change). The host's `size` reply
  then sets the local grid (ТР7), which now fills the pane. `tab.new` carries the
  local pane's `cols` / `rows` as the start size; `pane.split` has no start size, so the new pane is
  sized by the `resize` after its `attached`. There is no resize button.
- **ТР8в. Path switch and reconnect.** After the `attached` of a new path (LAN ⇄ relay) or of a
  reconnect, the client first sends its `resize` with `hold:true` on that path and only then
  `detach` on the old one, so the hold moves and is never released in between (ПТ6).
- **ТР8а. When the sizes differ** (a refused resize, the host's clamp of 20…500 × 5…200, another
  client that took the hold): the surface is drawn at the normal font, anchored top left; a larger
  pane shows the terminal background around the grid, a smaller pane clips. The client does not
  ask again until its own pane changes (ПТ6).
- **ТР8б. On Mac A** a held tab keeps the laptop's size while the remote window shows it. Closing
  the remote window, or switching away from that tab for more than 30 s (РЗ5), detaches and gives
  the Mac's pane its own size back.
- **ТР9. `detached`.** The tab shows "This terminal ended on <Mac name>" in place of the surface
  until the next `list` removes it.

### No connection (ОБ5, ИЗ3)

- **БН1.** Above every remote terminal (the content's toolbar slot, `TabContentToolbar`, or an
  overlay on the content host; builder's choice) a banner shows the state: "Connecting to <Mac>…",
  "No connection to <Mac>. Typing is not sent.", "<Mac> is offline.". System colors, Dynamic Type.
- **БН2.** While there is no connection, input from the pipe is dropped, not queued (a late burst of
  keys into an agent is worse than a lost key). The banner says so.
- **БН3.** The sidebar keeps the last `list`, dimmed, with the same state in the window title area.
- **БН4.** After the connection returns, the client sends `hello`, `list`, `watch` and re-attaches;
  the banner goes when the first `attached` arrives.

### Notifications (ОБ4)

- **ИВ1.** A port of the phone's `AwaitingTracker`: a notification only when a tab's agent goes to
  `awaitingInput` between two `list` snapshots; not for the first snapshot, and not when that tab is
  visible in the key remote window (the transition is still recorded).
- **ИВ2.** It uses the app's existing system-notification path with the Mac's name in the title.
  Clicking it brings the remote window forward and selects that worktree and tab. It adds nothing
  to the local window's notification list or sidebar.
- **ИВ3.** Switching the Mac or closing the window resets the tracker.
- **ИВ4.** Bell and desktop-notification sequences in the stream (author's call): a BEL from Mac A
  rings as a local terminal bell does, by the laptop's Ghostty settings. OSC 9 / 777 notifications
  from Mac A's programs are not shown on the laptop in the first version; only ИВ1 notifies.

## Host changes (Supacode on Mac A)

- **ХС1.** `RemoteHostRouter`: a set of attachments per connection (ПТ1), `caps` in `hello` (ПТ0),
  `watch` (ПТ3), the held size (ПТ6), and the handlers for `tab.close`, `pane.split`,
  `pane.close`, `tab.new.paneId`
  (ПТ4).
- **ХС2.** `RemoteSnapshotSource` / `RemoteSnapshotBuilder`: `layout` per worktree from
  `terminalManager.layoutState(for:)`, reading the flat `panes` and every group's tree (the
  split-per-tab invariants in `.agent-memory/split-per-tab-invariants.md`).
- **ХС3.** The new actions go through the app's existing layout and terminal commands (as `tab.new`
  does), never around `LayoutFeature`: `pane.split` through `TerminalClient.Command.splitPane`,
  `tab.close` and `pane.close` through `LayoutFeature.Action.closeTab(id:)` and `closePane(id:)`.
  These two reducers close at once; the Mac's close confirmation belongs to the
  `contentRequestedClose` path, which the host does not use.
- **ХС7. Where the hold lives.** The router owns who holds what (content → owner connection, cols,
  rows, the 30 s release). The terminal content keeps the pinned grid value and applies it to every
  surface it has or creates, so a hibernate and wake keeps it. `GhosttySurfaceView` gets a
  persistent hold next to `RequestedGridHold`: one that a different measured pane size and
  `viewDidMoveToWindow` do not release. This is the same piece the client needs for ТР7; it is built
  once, in ЕТ1.
- **ХС6.** `remote-relay/scripts/phone-sim.mjs` (this repo) learns the new messages: it prints
  `caps` and `layout`, and gets switches for `watch`, a second `attach` with `keep`, `tab.close`,
  `pane.split`, `pane.close` and `resize` with `hold`. ЕТ1 is verified with it.
- **ХС4.** No change to the relay (`remote-relay/`), to the LAN server's trust, or to `mayHost`. A
  Mac may host and be a client at once: the client socket is separate from its host socket.
- **ХС5. Test host id** (author's call). The host id comes only from the hardware UUID
  (`RemoteAccessConfig.currentHostID`), so a second Supacode on the same Mac has the client's own id:
  МХ2 hides it, and it takes the installed app's host slot. A new environment variable
  `SUPACODE_REMOTE_HOST_ID=<id>` replaces the derived id for that process. It is honoured only
  together with `SUPACODE_REMOTE_ACCESS=1` and only when the value matches
  `^[A-Za-z0-9_-]{1,64}$`; otherwise it is ignored with one log line. With it, an isolated second
  copy is "another Mac" for the live check and leaves the installed app's slot alone. It gives no
  new power: anyone with the host key may already claim any id. Documented in
  `docs/remote-access.md` (Troubleshooting, the second-Supacode entry).

## Work in `supacode-remote` (the other repo)

Not part of this repo's plan; the owner is told when each is needed.

- `tools/mock-host.mjs`: `caps`, `attach.keep`, `watch`, `layout`, `tab.close`, `pane.split`,
  `pane.close`, `resize.hold`, so the Swift client can be tried without a second Mac.
- `protocol/Protocol.kt`, `ProtocolCodecTest`, `web/src/protocol.mjs`: the new optional fields, only
  when the phone or the web app starts to use them. Until then they need no change.

## Tests

No `Task.sleep`; time comes from `TestClock` or an injected clock.

- **Protocol and host** (`supacodeTests/RemoteAccess*Tests.swift`): `caps` in `hello`; `attach` with
  and without `keep`, the limit, re-attach, `detach` of one; `resize` for any attached content; `resize` with `hold` (Ctrl+L only for a tab with an agent, kept across the Mac's
  layout changes and a hibernate and wake, released at `detach`, kept 30 s after a lost connection
  and taken over in that time, moved by a newer request, `size` to every attached client on
  release);
  `layout` for `tabsPerSplit` and `splitPerTab` (parked groups, zoom, unresolved ids); `watch`
  (push on change, 250 ms trailing edge, no push without a change, stop, no tick without watchers);
  `tab.close`, `pane.split`, `pane.close`, `tab.new.paneId` with their errors.
- **Client core**: `QueryFilter` with the vectors from `supacode-remote/web/test` plus OSC 3008;
  the stream gate cases from `TerminalStreamGateTest`; the `fpMac` vector from `LanTrustTest`; the
  host-choice rules (МХ1) from `HostChoiceTest`; the `hostOnline` edge rule; lenient decoding (КЛ5);
  the awaiting tracker (ИВ1).
- **Reducer** (`TestStore`): the remote feature's connection states and banner texts; the projection
  of `layout` with local selection kept (РЗ2); the attached set (РЗ5); automatic resize (ТР8: after `attached`, 200 ms after the grid settles,
  none in answer to a foreign `size`); each action sends the right
  request and shows the host's error.
- **Live check** (the owner's rule: finish the core and verify end to end): an isolated second
  Supacode as the host (`CFFIXED_USER_HOME`, `ZMX_DIR`, `SUPACODE_REMOTE_ACCESS=1` and
  `SUPACODE_REMOTE_HOST_ID`, ХС5; see `docs/remote-access.md`), with the installed or dev build as
  the client; the owner's second Mac is the final check. In the remote window run Claude Code, `vim`, `less`,
  mouse scroll, paste, Cyrillic, a split, a new and a closed tab, a window resize (the tab follows), a LAN ⇄
  relay switch, and Wi-Fi off and on for the banner. The installed dev build writes no unified log
  (`.agent-memory/dev-build-logs.md`), so the evidence is the window itself and `phone-sim.mjs`.

## Stages

Each stage builds and is tested on its own; the plan splits them into tasks.

| ID | Stage | Result |
|---|---|---|
| ЕТ1 | Protocol doc + host (ПТ0–ПТ4, ПТ6, ХС1–ХС7) | `phone-sim.mjs` shows `caps`, `layout`, pushed `list`, two attached tabs, and the new actions |
| ЕТ2 | Client core, no UI (КЛ1–КЛ7, МХ1–МХ4, `QueryFilter`, gate) | Unit tests pass against recorded frames |
| ЕТ3 | Pipe + one remote tab in the new window (ТР1–ТР9, ПЗ1) | One tab of Mac A works as a real Ghostty in the remote window |
| ЕТ4 | Sidebar, layout mirror and actions (СЛ1–СЛ5, РЗ1–РЗ6, ПЗ2–ПЗ4) | ОБ1–ОБ3 |
| ЕТ5 | Banner and notifications (БН1–БН4, ИВ1–ИВ3), docs (`docs/fork.md`, `docs/remote-access.md`) | ОБ4, ОБ5 |

## Left to the builder

- Module and type names inside `Features/RemoteClient/`; whether client models reuse the host's
  protocol types (КЛ5).
- The rendering route in РЗ6 and the banner's slot in БН1.
- The pipe's header format and socket file name (ТР2, ТР3), the `scrollback` value sent in `attach`.
- How the host detects a snapshot change for `watch` (ПТ3).
- The hotkey for "Open Remote Mac…" (it must not collide with an existing one).

## Author's calls for the owner to check

These were not decided by the owner; each can be changed before the plan.

- **АР1.** Tab selection, focus and zoom are local and are not sent to Mac A (РЗ2).
- **АР2.** The connection lives only while the remote window is open (КЛ6).
- **АР3.** How automatic resize works: a held size on the host (`resize` with `hold`, ПТ6), sent
  200 ms after the pane's grid settles (ТР8). While Mac A shows a tab that the laptop holds, Mac
  A's own pane shows the laptop's grid (ТР8б).
- **АР4.** Typing while there is no connection is dropped, and the banner says so (БН2).
- **АР5.** No new row fields in `list` for now (ПТ5).
- **АР6.** A host without the new capabilities is not supported by the remote window (ПТ0).
- **АР7.** Divider drag, tab move and tab rename wait for ПС6.
- **АР8.** A test-only host id override, `SUPACODE_REMOTE_HOST_ID` (ХС5), so the builder can verify
  the remote window on one Mac.
- **АР9.** A remote BEL rings locally; remote OSC 9 / 777 notifications are not shown (ИВ4).

- **АР12.** After a lost connection the host keeps the laptop's size for 30 s before the Mac's own
  size returns (ПТ6).
- **АР10.** АВ1 changes the rule only for the Supacode remote window. The phone and the web app
  keep the explicit resize button (ЗД12).

## Checked by the design review

- Terminal modes of a TUI that already runs are replayed on attach: zmx's capture serialises the
  screen with its modes (`ThirdParty/zmx/src/util.zig`), so ТР5 holds for a tab attached mid-session.
- In `splitPerTab` every pane has exactly one tab and a group has no close of its own, so
  `tab.close` and `pane.close` cover ОБ3 in both modes.
- Bell and OSC 9 / 777 notifications are wired per content host (`LayoutSurfaceConduit.swift`); the
  remote window does its own wiring, so ИВ2 decides what a remote bell does.

- `LayoutFeature.reduceCloseTab` and `reduceClosePane` close without the confirmation alert (ХС3).

## Not confirmed

- That zmx's broadcast carries OSC 3008 from the remote hooks to an attached client (ТР4 drops it
  either way).
- ~~That Network.framework's WebSocket client can send the `Authorization` header and check the pinned
  leaf certificate in the TLS verify block the way the LAN path needs (КЛ3).~~ Spike outcome (Task 5):
  the LAN path uses `NWConnection` with the WebSocket protocol options, and the certificate pin is
  checked in the verify block. The relay path uses `URLSessionWebSocketTask` instead, because it
  exposes the HTTP status of a refused upgrade (401 / 403), which `NWConnection` does not.
- ~~The cost of holding a pinned grid larger than the pane inside the surface's scroll wrapper (ТР7).~~
  Spike outcome (Task 9): the pinned grid sits at the top left of the pane, and the fallback (a
  fixed-size view) was not needed. Known limit: while the grid is pinned, the estimate of the grid
  that fits the pane (`GridCap.fitting`) can be one cell smaller than the real one, because the
  padding is not readable then; it is never larger.
- Relay volume on the non-LAN path. Cloudflare bills an incoming WebSocket message to a Durable
  Object at 20:1 as a request, outgoing messages are free, and the Workers Free plan allows 100,000
  Durable Object requests a day, after which requests fail until 00:00 UTC (Cloudflare docs,
  Durable Objects pricing, read 2026-11-17). That is 2,000,000 incoming frames a day for the whole
  relay: every `out` and pushed `list` from a host and every `input` from a client. Several busy
  terminals attached through the relay for a working day could reach it; the phone attaches one.
  The LAN path costs nothing. If the rate is too high, the host can join `out` frames per content
  over a short window before sending; that needs no protocol change.
  Measured on 2026-11-18 with `phone-sim.mjs <contentId> rate 60` (host plan, Task 10), plain
  attach through the relay, one sample each:
  - Claude Code at work, waiting on a subagent (spinner and elapsed time): 1.03 and 1.01 `out`
    frames/s (60 s and 120 s), about 85 bytes/s.
  - Claude Code streaming a reply: 8.3 frames/s over the 11 s it streamed, at most 10 in one
    second, about 1,400 bytes/s; 0 once it was idle again.
  - An idle shell: 0 frames/s over 60 s.
  Four busy tabs for eight hours are 115,200 tab-seconds: about 119,000 frames at 1 frame/s, about
  956,000 at 8.3 frames/s and about 1,152,000 at 10 frames/s, against the 2,000,000 limit. Even
  four tabs streaming the whole day stay under it, and an agent alternates streaming with waiting
  and tools, so joining `out` frames on the host is not needed now. It becomes needed when a tab
  averages more than about 17 frames/s over the day (2,000,000 / 115,200). Not measured: an agent
  that prints large tool output (diffs, test logs); one sample per case.
