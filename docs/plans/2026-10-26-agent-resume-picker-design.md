# Agent Resume Picker: Design

Task ЗДС (picker), 2026-10-26. Fork-only feature. It builds on the merged agent session resume
([done/2026-10-26-agent-session-resume-design.md](done/2026-10-26-agent-session-resume-design.md)).
Inputs: recon `tmp/captain/20261026-135510/reports/recon-ЗД0.md` and the Ghostty check
`reports/ghostty-ЗД1.md`. Line numbers are from `idachev-supacode` at `ff047c73`. Swift references
come from grep; serena reference search returns nothing for Swift in this repo.

## Goal

After Supacode restarts (a reboot, or a relaunch after the zmx sessions died), the owner sees a
list of the agent sessions that wait for a resume. He ticks the ones he wants and presses
"Resume selected". The selected panes wake in the background and type and run their resume
command (`claude --resume '<id>'`, `codex resume '<id>'`, ...). He does not have to open each
worktree. A worktree with a pending resume shows a small sidebar marker.

Today resume is lazy. A pane resumes only when it is first shown (`TerminalsFeature.swift:353-359`
is the only `.wakeTab` sender). After a real reboot only the opened worktree resumed.

## Settled Decisions (owner and coordinator, keep exactly)

- ОП5 (owner, 2026-10-26): marker + list with checkboxes + "Resume selected". Rejected: ОП3
  (marker only, wake by opening), ОП6 (list rows only navigate to the pane), and an eager wake of
  every pane at launch (option B of panel ОВ1).
- S1. Pending = a pane (tab content) for which all of these hold:
  - its persisted `TerminalContentState.agentSession` is non-nil;
  - the setting `resumeAgentSessionsAfterRestart` is on;
  - the worktree is local (`host == nil`);
  - the launch gate is captured, and its `supa-*` zmx session name is NOT in the gate's live set;
  - its contentID is NOT claimed.

  zmx availability is implied by a captured gate (see Section 2). The list and the sidebar marker
  use this one rule.
- S2. Pending is computed in reducer state at the `AppFeature` level, never in `LayoutFeature`.
  The manager's gate is not observable. So the capture emits a new `TerminalClient.Event` with the
  live session names (or "probe failed"), and every claim emits a claimed event with the
  `ContentID`. (Refined in Section 1: only a granted claim emits; a refused claim adds nothing
  to the pending rule.) A claim comes from any first spawn: a lazy show, a background wake, or a rebuild
  after an unexpected close.
- S3. The sheet opens once per process, only when the gate is captured AND the repositories are
  loaded AND pending is non-empty. It can be reopened from the command palette and from a menu
  item with a hotkey.
- S4. Rows: repository / worktree name, stored tab title, agent, short session id (first 8
  characters). Every row is ticked by default. Buttons: "Resume selected" (default action) and
  "Not now". Tooltips with hotkeys, system colors, Dynamic Type, `.monospaced()` for the id.
- S5. The sheet reads pending live. A pane that the owner opens meanwhile (the lazy resume claims
  it) drops off. A stale tick is harmless: the claim is false, and `wakeTab` on live content is a
  no-op.
- S6. An unticked or dismissed pending pane stays lazy exactly as today and keeps its sidebar
  marker. There is no "claim without typing" option.
- S7. The background wake is a new `TerminalClient.Command`, handled in
  `WorktreeTerminalManager.handleCommand`: first `host(for: worktree)`, then
  `sendLayout(worktreeID, .wakeTab(id: tabID))`. `reduceWakeTab` provisions `.restored`, and the
  `.first` spawn claims and seeds the command. No selection or focus change. The `AppFeature`
  effect staggers the targets with the injected clock.
- S8. Re-hibernation after the 5-minute grace, or on memory pressure, is accepted. Hibernation
  only detaches (`closeSurface`); the agent lives in zmx. The one accepted risk is a
  memory-pressure detach in the first moments after the wake (Section 6).
- S9. The sidebar marker is a dedicated per-row `SidebarItemFeature` action, sent per affected row
  only when the value flips. Its state lives in `RepositoriesFeature.State.sidebarItems`. It does
  NOT go through the host projection, because a never-opened worktree has no host.
- S10. A `SupaLogger` line for each resume decision, and for the picker steps (Section 8).
- S11. Content-specific state stays out of `LayoutFeature`; the wake reuses the generic
  `.wakeTab`. Reducer changes get tests with `TestClock`, never `Task.sleep`.
- S12. `docs/fork.md` is updated (Section 10, task (f)).

## Verified Code Facts

| Fact | Where |
| --- | --- |
| `.wakeTab` provisions a `.restored` content when the runtime has none; it changes no selection or focus | `LayoutFeature.swift:775-805` |
| Every persisted worktree has a layout in reducer state after hydration, opened or not | `TerminalsFeature.swift:182-215` |
| The content factory resolves the worktree from `state.repositories`; a nil worktree gives `InertTabContent` | `supacodeApp.swift:393-396`, `TerminalSurfaceRecipe.swift:372-377` |
| `wireSurface` calls `terminalManager.host(for:)`, which sends `.attachLayout` | `supacodeApp.swift:406-419`, `WorktreeTerminalManager.swift:766-772` |
| `splitPane` uses the same `_ = host(for: worktree)` pre-step | `WorktreeTerminalManager.swift:1384` |
| The seed claims first, then checks `.restored`, then the setting, remote, zmx, record | `TerminalSurfaceRecipe.swift:274-323` |
| The gate: `liveSessionNames` (`let`), `claimed` (`private(set)`), mutating `claim` | `AgentResumeGate.swift:9-23` |
| The capture runs once; a nil probe leaves no gate | `WorktreeTerminalManager.swift:2006-2018` |
| `claimAgentResume` returns false without a gate | `WorktreeTerminalManager.swift:2023-2033` |
| A missing zmx binary makes the probe nil (`runZmx` returns nil), so no gate | `ZmxClient.swift:204-211, 241-246` |
| `.appLaunched` concatenates the capture before `.repositories(.task)`; the terminal event subscription is inside the later `.merge` | `AppFeature.swift:402-430` |
| Events emitted before the subscription are buffered | `WorktreeTerminalManager.swift:2223-2227` |
| `AppFeature.body` runs `core` BEFORE the child scopes; a later `Reduce` sees the children's new state | `AppFeature.swift:2184-2222` |
| `isInitialLoadComplete` is set by the repositories child on `.repositoriesLoaded` and on `.openRepositoriesFinished` | `RepositoriesFeature.swift:3809-3830, 3977-3993` |
| `core` handles `.repositories(.repositoriesLoaded)` with an early return | `AppFeature.swift:1741-1747` |
| The tab title fields: `title`, `customTitle` | `PaneLayout.swift:189-195` |
| Worktree to repository: `repositoryID(for:)` | `RepositoriesFeature.swift:6126` |
| Sidebar per-row state and the change-only setter pattern | `SidebarItemFeature.swift:127, 141-148, 199-215` |
| The hibernation "zzz" marker view | `SidebarItemView.swift:518, 576-588` |
| Menu item with hotkey through plain `store.send` | `WorktreeCommands.swift:99-103` |
| Palette global items and the caller | `CommandPaletteFeature.swift:237-282, 290`, `ContentView.swift:197-205` |
| Sheets in `ContentView` | `ContentView.swift:72-104` |
| The command handlers with exhaustive "not mine" lists | `WorktreeTerminalManager.swift:524-533, 570-576, 645-651` |
| The event switches `coalesceKey`, `label`, `invalidatedCoalesceKeys` have `default:` | `WorktreeTerminalManager.swift:123-143, 2316-2322` |
| `AppFeature` has `@Dependency(\.continuousClock) private var clock` | `AppFeature.swift:384` |

**S7 holds.** `wakeTab` can provision a tab of a never-opened worktree: its layout is hydrated, its
worktree is in `state.repositories` once the repositories load, and `wireSurface` creates the
host on demand. The pre-step `host(for:)` only makes the host and `.attachLayout` happen before
the reducer runs, as `splitPane` does.

## Shared Contract (names every part uses)

| Item | Exact name / shape | Where |
| --- | --- | --- |
| Liveness event | `TerminalClient.Event.agentResumeLivenessCaptured(liveSessionNames: Set<String>?)`; nil = probe failed | `supacode/Clients/Terminal/TerminalClient.swift` (Event, after `:160`) |
| Claimed event | `TerminalClient.Event.agentResumeClaimed(ContentID)`; emitted only for a granted claim | same |
| Wake command | `TerminalClient.Command.wakeTabInBackground(Worktree, tabID: TabID)` | same (Command) |
| Gate outcome | `nonisolated enum AgentResumeGate.ClaimOutcome: Equatable, Sendable { case granted, live, alreadyClaimed }` + `mutating func claimOutcome(_ id: ContentID) -> ClaimOutcome`; `claim(_:)` stays as `claimOutcome(id) == .granted` | `AgentResumeGate.swift` |
| Liveness mirror | `nonisolated enum AgentResumeLiveness: Equatable, Sendable { case notCaptured, probeFailed, captured(liveSessionNames: Set<String>) }` | new `supacode/Features/AgentResume/Models/AgentResumeState.swift` |
| Row | `nonisolated struct PendingAgentResume: Identifiable, Equatable, Sendable { let id: ContentID; let worktreeID: Worktree.ID; let tabID: TabID; let repositoryName: String; let worktreeName: String; let tabTitle: String; let agent: String; let sessionID: String; var shortSessionID: String { String(sessionID.prefix(8)) } }` | same file |
| Reducer state | `@ObservableState struct AgentResumeState: Equatable { var liveness: AgentResumeLiveness = .notCaptured; var claimed: Set<ContentID> = []; var pending: IdentifiedArrayOf<PendingAgentResume> = []; var didEvaluateAutoPresent = false; var wakeQueue: [ContentID] = [] }` | same file |
| Predicate | `nonisolated enum AgentResumePending { static func compute(layouts: IdentifiedArrayOf<LayoutFeature.State>, liveness: AgentResumeLiveness, claimed: Set<ContentID>, enabled: Bool, worktree: (Worktree.ID) -> Worktree?, repositoryName: (Worktree.ID) -> String?) -> IdentifiedArrayOf<PendingAgentResume>; static let wakeStagger: Duration = .seconds(1) }` | new `supacode/Features/AgentResume/BusinessLogic/AgentResumePending.swift` |
| App state | `AppFeature.State.agentResume: AgentResumeState`; `@Presents var agentResumePicker: AgentResumePickerFeature.State?` | `AppFeature.swift` (State, near `:180`) |
| App actions | `AppFeature.Action.agentResumePicker(PresentationAction<AgentResumePickerFeature.Action>)`, `.agentResumePickerRequested`, `.agentResumeWakeTick` | `AppFeature.swift` (Action, near `:360`) |
| Picker feature | `@Reducer struct AgentResumePickerFeature`; `@ObservableState struct State: Equatable, Identifiable { let id: UUID; var rows: IdentifiedArrayOf<PendingAgentResume>; var selected: Set<ContentID> }`; `enum Action { case toggleRow(ContentID); case resumeSelectedTapped; case notNowTapped; case delegate(Delegate) }`; `enum Delegate { case resumeRequested([ContentID]) }` | new `supacode/Features/AgentResume/Reducer/AgentResumePickerFeature.swift` |
| Picker view | `struct AgentResumePickerView: View` | new `supacode/Features/AgentResume/Views/AgentResumePickerView.swift` |
| Sidebar | `SidebarItemFeature.State.hasPendingAgentResume: Bool = false`; `SidebarItemFeature.Action.pendingAgentResumeChanged(Bool)` | `SidebarItemFeature.swift` (`:127`, `:141-148`) |
| Sidebar view | `private struct SidebarPendingResumeIndicator: View, Equatable` | `SidebarItemView.swift` (next to `:576`) |
| Shortcut | `AppShortcutID.resumeAgentSessions`, `AppShortcuts.resumeAgentSessions = AppShortcut(id: .resumeAgentSessions, key: "r", modifiers: [.command, .control])` | `SupacodeSettingsShared/App/AppShortcuts.swift` |
| Palette | `CommandPaletteItem.Kind.resumeAgentSessions`, `CommandPaletteFeature.Delegate.resumeAgentSessions`, `CommandPaletteItemID.globalResumeAgentSessions = "global.resume-agent-sessions"` | `CommandPaletteItem.swift:74+`, `CommandPaletteFeature.swift:56+, 760+` |
| Seed outcome | `nonisolated enum TerminalSurfaceRecipe.AgentResumeSkip: String, Equatable { case settingOff, remote, zmxMissing, noRecord, unsupportedRecord }` + `static func agentResumeSkip(record:worktree:zmxAvailable:enabled:) -> AgentResumeSkip?` | `TerminalSurfaceRecipe.swift:269-282` |

## 1. Gate Events (Manager to Reducer)

1. `captureLaunchSessionLiveness()` (`WorktreeTerminalManager.swift:2006-2018`) emits
   `.agentResumeLivenessCaptured(liveSessionNames:)` after it sets the gate: the filtered live set,
   or nil when the probe failed. It emits once, because the capture runs once. The event is
   emitted before the `AppFeature` subscription starts, so `emit` buffers it
   (`WorktreeTerminalManager.swift:2223-2227`). It is a one-shot event: `coalesceKey` returns nil
   through `default:`.
2. `claimAgentResume(_:)` (`:2023-2033`) calls `agentResumeGate?.claimOutcome(id)`.
   - `.granted`: emit `.agentResumeClaimed(id)` and return true.
   - `.live` or `.alreadyClaimed`: return false. Log per Section 8.
   - No gate: unchanged.
   A refused claim emits nothing: a live content is never pending, and an already claimed one is
   already in the reducer's set.
3. `AgentResumeGate.claimOutcome(_:)` keeps the order of today's `claim`: live first, then
   `claimed.insert(id).inserted`. `claim(_:)` stays, so the existing gate tests stay valid.
4. A non-mutating `isPending` helper on the gate is NOT added. The reducer mirrors the gate from
   the two events, and that is all S1 needs.

## 2. Pending in Reducer State

`AppFeature.State.agentResume` holds the mirror (`liveness`, `claimed`) and the computed
`pending`.

- `.terminalEvent(.agentResumeLivenessCaptured(names))` sets `liveness` to
  `.captured(liveSessionNames: names)` or `.probeFailed`.
- `.terminalEvent(.agentResumeClaimed(id))` inserts `id` into `claimed`.

`AgentResumePending.compute(...)` is pure. It returns no rows unless `enabled` and `liveness` is
`.captured`. Otherwise, for each layout, each pane, each tab, a row is pending when:
- `tab.content.state` is `.terminal` and its `agentSession` is non-nil;
- `worktree(layout.id)` is non-nil and `host == nil` (an unknown worktree is not pending: it cannot
  spawn, and its local/remote is not known);
- `ZmxSessionID.make(surfaceID: tab.content.id.rawValue)` is not in the live set;
- `tab.content.id` is not in `claimed`.

zmx availability needs no own check: without the bundled zmx the probe is nil
(`ZmxClient.swift:208-211`), so `liveness` is `.probeFailed`.

Row fields: `repositoryName` from `repositoryID(for:)` (`RepositoriesFeature.swift:6126`) and the
repository's name; `worktreeName` = `Worktree.name`; `tabTitle` = `tab.customTitle ?? tab.title`
(the stored title; an unspawned tab has no `TabChrome`); `agent` and `sessionID` from the record.
Rows are sorted by repository name, then worktree name, then layout order of panes and tabs.

**When it is recomputed.** A new `Reduce` placed after the child scopes in `AppFeature.body`
(`AppFeature.swift:2209`, next to `trackRecentTerminalAccess`), because `core` runs before the
scopes and would not yet see `isInitialLoadComplete` or a removed tab. It calls
`refreshAgentResume(&state)` only for these actions (a cheap gate, like
`affectsWorktreeMenuSnapshot`):
- `.terminalEvent(.agentResumeLivenessCaptured)`, `.terminalEvent(.agentResumeClaimed)`;
- `.repositories(.repositoriesLoaded)`, `.repositories(.openRepositoriesFinished)`,
  `.repositories(.delegate(.repositoriesChanged))`;
- `.terminals(.layoutsHydrated)`, `.terminals(.detachLayout)`;
- `.terminals(.layouts(.element(_, a)))` where `RecentTerminals.canRemoveTabs(a)`
  (`RecentTerminals.swift:51-61`);
- `.settings(.delegate(.settingsChanged))` (`AppFeature.swift:775`), for the setting flip.

A record in an unspawned tab cannot change, so no other action can change pending.
`refreshAgentResume` reads the setting with `@Shared(.settingsFile)`, as the recipe does. It then
updates the sheet (Section 4), the marker (Section 5) and the auto-present (Section 3).

## 3. Once-After-Launch Trigger

In `refreshAgentResume`, after the recompute:

```swift
if !state.agentResume.didEvaluateAutoPresent,
  state.agentResume.liveness != .notCaptured,
  state.repositories.isInitialLoadComplete
{
  state.agentResume.didEvaluateAutoPresent = true
  if !state.agentResume.pending.isEmpty, state.agentResumePicker == nil {
    state.agentResumePicker = AgentResumePickerFeature.State(id: uuid(), rows: pending, selected: Set(pending.ids))
    // log "resume picker shown"
  }
}
```

- The action that fires it is the later of `.terminalEvent(.agentResumeLivenessCaptured)` and
  the first repositories action that sets `isInitialLoadComplete` (`.repositoriesLoaded` or
  `.openRepositoriesFinished`), handled in the post-scope `Reduce`. In practice the capture
  ends first (it is concatenated before `.repositories(.task)`), so `.repositoriesLoaded` fires it.
  The code does not depend on that order: it checks the state, not the action.
- `PresentationState` ids come from `@Dependency(\.uuid)`, which `AppFeature` does not have yet
  (`AppFeature.swift:371-384`); task (c) adds it.
- The decision is made once per process, even when pending is empty at that moment. Pending can
  grow later only through the setting flip, and a flip does not reopen the sheet.
- `didEvaluateAutoPresent` lives in reducer state, so it is per process by construction.
- The selected worktree's visible tabs wake lazily right after the load and claim. Their rows can
  appear and then drop a tick later through S5. That is acceptable.

**Reopen.** `.agentResumePickerRequested` presents the sheet with the current pending, every row
ticked, when pending is non-empty and no sheet is up. Otherwise it logs at debug and does
nothing. Two senders:
- Menu "Worktrees" → "Resume Agent Sessions…", next to "Archived Worktrees"
  (`WorktreeCommands.swift:99-103`): `store.send(.agentResumePickerRequested)`,
  `.appKeyboardShortcut(resumeAgentSessions)`,
  `.help(AppShortcut.helpText("Resume agent sessions that wait after a restart", shortcut: ...))`,
  `.disabled(store.agentResume.pending.isEmpty)`. This is plain `store.send`, as "Archived
  Worktrees" does. The CLAUDE.md `FocusedAction` rule covers closures published as focused values;
  this item publishes no focused value and depends on no focused scene, so the rule does not
  apply. The menu reads only `pending.isEmpty`, which flips rarely.
- Command palette: a global item "Resume Agent Sessions" (`Kind.resumeAgentSessions`). It is
  listed only when pending is non-empty: `CommandPaletteFeature.items(in:from:...)` and
  `commandPaletteItems(from:...)` get a parameter `hasPendingAgentResumes: Bool = false`, which
  `ContentView.paletteItems` (`ContentView.swift:197-205`) fills from `store.agentResume.pending`.
  `globalActionItems()` stays unchanged; `commandPaletteItems` appends the item. `AppFeature`
  maps `.commandPalette(.delegate(.resumeAgentSessions))` to `.agentResumePickerRequested`.

**Hotkey.** ⌃⌘R (`"r"`, `[.command, .control]`). `AppShortcuts.swift:503-650` has no other ⌃⌘R;
the R combos in use are ⌘R, ⌥⌘R, ⇧⌘R and ⌃⇧R. A grep of `supacode` for a hard-coded
`keyboardShortcut("r"` finds nothing. Adding the id touches the `AppShortcutID` case list
(`:12`), the ordered list (`:36`), the raw names (`:79`, `:138`) and the display name (`:214`).

## 4. Picker Sheet

`AgentResumePickerFeature` is presented with `.ifLet(\.$agentResumePicker, action:
\.agentResumePicker)` after the deeplink one (`AppFeature.swift:2206`). `ContentView` adds
`.sheet(item: $store.scope(state: \.agentResumePicker, action: \.agentResumePicker))` next to
`ContentView.swift:72-76`.

Reducer:
- `.toggleRow(id)` flips `id` in `selected`.
- `.resumeSelectedTapped` sends `.delegate(.resumeRequested(rows.ids.filter(selected.contains)))`
  and dismisses (`@Dependency(\.dismiss)`).
- `.notNowTapped` dismisses.

View (`AgentResumePickerView`):
- Title "Resume agent sessions"; one line of secondary text: "These panes ran a coding agent
  before the restart. The selected ones type and run the agent's resume command in the background."
- A `List` of rows. Each row has a `Toggle` (checkbox style) with:
  `repositoryName / worktreeName` (`.headline`), the tab title (`.subheadline`, `.secondary`), the
  agent, and `shortSessionID` with `.monospaced()`. The row's `.help` shows the full session id.
- Buttons: "Not now" (`.keyboardShortcut(.cancelAction)`, `.help("Keep these panes lazy; each
  resumes when you open it (Esc)")`) and "Resume selected"
  (`.keyboardShortcut(.defaultAction)`, `.help("Wake the selected panes in the background and run
  their resume command (Return)")`, disabled when `selected` is empty).
- System fonts and colors only, Dynamic Type, no fixed font sizes. No cap on rows; the `List`
  scrolls. The sheet sets a min width and lets its height follow the content up to the window.

**Live rows (S5).** `refreshAgentResume` writes the new pending into an open sheet:
`rows = pending`, `selected = selected ∩ pending.ids ∪ (pending.ids − old rows.ids)`. So a row that
leaves pending drops off, and a row that newly appears (the setting turned on) comes in ticked.
When pending becomes empty while the sheet is open, the reducer sets `agentResumePicker = nil`
(auto-close) and logs at debug.

## 5. Sidebar Marker

- `SidebarItemFeature.State.hasPendingAgentResume: Bool = false`, next to `allTabsDormant`
  (`SidebarItemFeature.swift:127`).
- `.pendingAgentResumeChanged(Bool)` sets it only when it differs, like `agentSnapshotChanged`
  (`:199-202`).
- `refreshAgentResume` builds `marked = Set(pending.map(\.worktreeID))`. For each row in
  `state.repositories.sidebarItems` whose `hasPendingAgentResume != marked.contains(row.id)`, it
  sends `.repositories(.sidebarItems(.element(id: row.id, action: .pendingAgentResumeChanged(...))))`
  (the routing of `AppFeature.swift:2020-2024`). Only rows that flip get an action; rows absent
  from `sidebarItems` get none. A rebuilt row (after `repositoriesChanged`) starts at false, and
  the same refresh, which runs on `.repositoriesChanged`, sets it again.
- `computeSidebarStructure` (`SidebarStructure.swift:793`) does NOT change. The structure carries
  only grouping and order; the row view reads its own row store, as it does for
  `allTabsDormant` (`SidebarItemView.swift:518`).
- View: `SidebarPendingResumeIndicator`, drawn in the same status slot as the dormant indicator
  (`SidebarItemView.swift:518-532`). `Image(systemName: "arrow.clockwise.circle")`,
  `.imageScale(.small)`, `.appFont(.subheadline)`, `.foregroundStyle(.secondary)`,
  `.help("An agent session waits for a resume. Open the worktree, or use Resume Agent Sessions (⌃⌘R).")`
  with the hotkey text from `AppShortcut.helpText`, and `.accessibilityLabel("Agent resume pending")`.
  When both markers apply, both show (pending first).

## 6. Background Wake

**Effect.** `.agentResumePicker(.presented(.delegate(.resumeRequested(ids))))` sets
`state.agentResume.wakeQueue = ids`, logs "resume requested", and returns
`.send(.agentResumeWakeTick)`.

`.agentResumeWakeTick`:
1. Pop the first id from `wakeQueue`. If the queue is empty, return `.none`.
2. If the id is not in `pending` any more (claimed meanwhile, tab closed, setting off), log at
   debug and return `.send(.agentResumeWakeTick)` (skip without delay).
3. Otherwise resolve the worktree with `state.repositories.worktree(for:)` and send
   `terminalClient.send(.wakeTabInBackground(worktree, tabID: row.tabID))`. Log "resume wake sent".
4. If the queue is not empty, return
   `.run { send in try await clock.sleep(for: AgentResumePending.wakeStagger); await send(.agentResumeWakeTick) }`
   with `.cancellable(id: AgentResumeCancelID.wake, cancelInFlight: true)`.

The queue is reducer state, so every step re-checks pending live (S5), and a `TestClock` drives
the stagger. A second "Resume selected" while a queue runs replaces the queue and cancels the old
timer.

**Stagger: 1 s.** Each wake starts a Ghostty surface, a `zmx attach`, a new zmx session, a shell
and an agent. Claude and codex take about 1-2 s of CPU to start and each hits its API at startup.
One second keeps ten panes under ten seconds and never starts more than about two agents at once.
Rejected: 0 s (a CPU and API burst for many panes) and 3 s or more (thirty seconds for ten panes,
and the owner would think it hangs).

**Manager.** `handleManagementCommand` (`WorktreeTerminalManager.swift:608+`) gets:

```swift
case .wakeTabInBackground(let worktree, let tabID):
  _ = host(for: worktree)
  guard presentTab(tabID, in: worktree.id) != nil else {
    terminalLogger.debug("background wake skipped: tab \(tabID.rawValue) gone")
    return
  }
  sendLayout(worktree.id, .wakeTab(id: tabID))
```

`host(for:)` creates the host and sends `.attachLayout` before the `wakeTab` reducer runs, so
`wireSurface` finds the host and no host is created re-entrantly (`splitPane` does the same at
`:1384`). `presentTab` is `:510-512`. The new case is added to the exhaustive lists at
`:524-533` (search) and `:570-576` (binding action). `handleTabCommand` ends in `default:` (`:450`).

**What happens next.** `reduceWakeTab` provisions `.restored`; `startSession` makes the surface
with `.first`; the seed claims (the claimed event follows) and types the command. Selection and
focus do not change. `.wakeTab` counts as visibility-affecting (`TerminalsFeature.swift:106-108`),
so `reconcileHibernation` runs. The woken tab is hidden and has a renderer, so it arms the
5-minute grace timer and then hibernates, unless the recency list covers it. Hibernation only
detaches; the agent keeps running in zmx.

**Ghostty initial_input without mount (ЗД1).** Verdict: YES, Ghostty writes `initial_input`
without a mount. `GhosttySurfaceView.init` calls `createSurface()` directly
(`GhosttySurfaceView.swift:285-290`), not from `viewDidMoveToWindow`. `ghostty_surface_new`
(`:1194`) starts the IO thread in surface init (`Surface.zig:734`). The thread's `threadEnter`
forks the child and opens the pty (`Exec.zig:93`, `:905`) and then queues the `initial_input`
write (`Termio.zig:403`). The init size is a fixed 800x600 (`embedded.zig:514`). Nothing in this
chain needs a window, renderer or focus. So a background-woken surface gets its command.

The one accepted risk (S8): `closeSurface` frees the surface on the next main-queue turn
(`GhosttySurfaceView.swift:358`), and the free SIGHUPs the child (`Exec.zig:201`). Here the
child is `zmx attach`, so a detach kills the attach client, not the zmx session. Input that the
attach client has not yet forwarded to the session could be lost. Only a memory-pressure detach
(`TerminalsFeature.swift:458+`, which hibernates every hidden tab at once) can come that soon; the
grace timer waits 5 minutes. If it happens, the slot is spent for this process, the record stays,
and the next launch retries. Not confirmed: whether libxev drops a queued write on a stop in the
same tick (`Exec.zig:555`), and the zmx forwarding timing.

Decision: accept, do not exempt. An exemption ("recently woken, do not hibernate for N s") would
be new per-tab state and a new timer in `TerminalsFeature`, for a window that needs a memory
warning in the first moments after a wake. The "resume wake sent" log line plus the memory
pressure log make a lost resume diagnosable.

## 7. Setting and Runtime Changes

- Setting off: `compute` returns no rows, so no sheet and no marker. The seed already types
  nothing.
- Toggled at runtime: `.settings(.delegate(.settingsChanged))` recomputes. Off clears every marker
  and auto-closes an open sheet. On brings back the markers of the panes that are still unclaimed.
  The sheet does not open by itself again (the once-after-launch decision is spent); the owner
  can use ⌃⌘R.
- After a successful background resume the claim removes the pane from pending, so its marker
  goes away. The worktree's marker goes away when its last pending pane is claimed.

## 8. Decision Logging

Logger names: the recipe's `TerminalSurfaceRecipe.builderLogger`, the manager's `terminalLogger`,
and `AppFeature`'s `appLogger`. Short id = the first 8 characters.

Levels: **info** for a typed resume and for a skip of a pane that has a record (the owner may
ask why it did not resume). **debug** for decisions that happen to every pane on every launch.
**No line** for a re-wake: it is not a decision (it never claims) and it repeats on every wake of
a hibernated tab.

| Where | Case | Level | Text |
| --- | --- | --- | --- |
| seed | phase is `.rewake` | none | - |
| manager `claimAgentResume` | `.live` | debug | `resume claim refused: live content=<uuid>` |
| manager | `.alreadyClaimed` | debug | `resume claim refused: already claimed content=<uuid>` |
| manager | no gate, before capture | warning | unchanged `resume skipped: liveness not captured` |
| manager | no gate, probe failed | debug | `resume claim refused: no gate content=<uuid>` |
| seed | granted, origin not `.restored` | debug | `resume skipped: not restored content=<uuid>` |
| seed | `agentResumeSkip == .noRecord` | debug | `resume skipped: no record content=<uuid>` |
| seed | `.settingOff` / `.remote` / `.zmxMissing` | info | `resume skipped: <reason> agent=<a> session=<short> content=<uuid>` |
| seed | `.unsupportedRecord` (`AgentResumeCommand` gave nil) | warning | `resume skipped: unsupported record agent=<a> content=<uuid>` |
| seed | typed | info | `resume typed: agent=<a> session=<short> content=<uuid>` |
| capture | probe failed | warning | unchanged `resume skipped: liveness probe failed` |
| AppFeature | sheet presented | info | `resume picker shown: <n> pending` |
| AppFeature | resume requested | info | `resume requested: <k> of <n> selected` |
| AppFeature | wake sent | info | `resume wake sent: worktree=<id> tab=<uuid>` |
| AppFeature | queued id no longer pending | debug | `resume wake skipped: no longer pending tab=<uuid>` |
| AppFeature | sheet auto-closed | debug | `resume picker closed: nothing pending` |

The seed gets the reason from the new pure `agentResumeSkip(record:worktree:zmxAvailable:enabled:)`.
`agentResumeInput` becomes: `agentResumeSkip(...) == nil ? AgentResumeCommand.initialInput(for: record) : nil`,
and a nil command text is the `.unsupportedRecord` case. The decision order of
`agentResumeSeed` does not change: phase, claim, origin, then the input checks.

## 9. Tests (Swift Testing; `TestClock`, never `Task.sleep`)

- (a) Gate and pending:
  - `AgentResumeGate.claimOutcome`: live → `.live`; first dead → `.granted`; second → `.alreadyClaimed`; `claim` agrees.
  - `WorktreeTerminalManagerAgentResumeTests`: the capture emits `.agentResumeLivenessCaptured` with the
    non-stale names, and with nil on a failed probe; a granted claim emits `.agentResumeClaimed`; a
    refused one emits nothing.
  - `AgentResumePending.compute` table: no record; setting off; remote worktree; unknown worktree;
    live session; claimed; `.probeFailed`; `.notCaptured`; a pending row with the expected fields,
    the custom title over the title, and the sort order.
  - `AppFeature` TestStore (`exhaustivity = .off`, as `AppFeatureLaunchOrderTests`): the two events
    update `agentResume`; a removed tab (`.closeTab`) and `.detachLayout` drop rows.
- (b) Background wake:
  - `AppFeature`: `.resumeRequested([a, b, c])` with a `TestClock`: `a` is sent at once; nothing more
    before 1 s; `b` after `clock.advance(by: .seconds(1))`; a `b` claimed before its tick is skipped
    without waiting; the queue ends. Record the sends with a `LockIsolated` `terminalClient.send`.
  - Manager: `.wakeTabInBackground` for a worktree without a host creates the host and routes
    `.wakeTab` to that layout; a gone tab sends nothing. (`WorktreeTerminalManager` test with a
    stub `appStore`, as the existing manager tests do.)
- (c) Picker:
  - `AgentResumePickerFeature`: toggle; "Resume selected" sends the delegate with the ticked ids in
    row order and dismisses; "Not now" dismisses with no delegate.
  - `AppFeature`: the sheet opens once when both the liveness event and `.repositoriesLoaded` have
    arrived, in either order; it does not open with empty pending, with `.probeFailed`, or a second
    time; `.agentResumePickerRequested` opens it again; a claim while open drops the row; the last
    claim closes it; the palette delegate maps to `.agentResumePickerRequested`.
  - `CommandPaletteFeature.items`: the item is present only with `hasPendingAgentResumes: true`.
  - The `AppShortcuts` tests that enumerate ids, if any, gain the new id.
- (d) Marker:
  - `SidebarItemFeatureTests`: `.pendingAgentResumeChanged` sets the field and is a no-op for the same value.
  - `AppFeature`: a pending row marks its worktree; the claim of its last pending pane clears the
    marker; a worktree with two pending panes keeps the marker after one claim; the setting off
    clears all markers; no action is sent for an unchanged row.
- (e) Logging: `agentResumeSkip` table tests (each reason, nil when the inject proceeds). The log
  lines themselves are not asserted.

## 10. Dev Verification

"Build to test" means `make install-dev-build`, then the owner restarts the app.

1. Open three local worktrees, A, B and C. Start `claude` in a pane of A and of B and `codex` in a
   pane of C, and send one prompt to each. Approve the codex hook review once. Note
   `echo $SUPACODE_SURFACE_ID $ZMX_DIR` in each pane. Select A last.
2. Quit Supacode.
3. Simulate the reboot: with that `ZMX_DIR`, run the bundled
   `<app>/Contents/Resources/zmx/zmx kill supa-<surface id>` for each pane, with the id in lower case
   (`zmx list` shows the exact names).
4. Relaunch. Expected: the "Resume agent sessions" sheet lists the panes of B and C (A's pane may
   show and drop at once, because A is selected and resumes lazily). B and C show the sidebar marker.
5. Untick C and press Return ("Resume selected"). Expected: without selecting B, B's marker goes
   away; open B: the pane ran `claude --resume '<id>'`. Console: `resume picker shown`,
   `resume requested: 1 of 2 selected`, `resume wake sent`, `resume typed`.
6. C keeps its marker. Press ⌃⌘R: the sheet shows only C. Press Esc. Open C: it resumes lazily and
   its marker goes away.
7. Relaunch without killing anything: no sheet, no marker.
8. Negative: the setting off before step 4 gives no sheet and no marker.

## Decisions (beyond the settled ones)

- Д1. The gate is mirrored in the reducer from two events (`livenessCaptured`, `claimed`).
  Rejected: the manager computing and emitting the pending list (it does not own layouts and
  repositories), and a reducer-side copy of the claimed set updated on wake (misses rebuild
  claims; recon Q4 (b)).
- Д2. Pending is recomputed in a post-scope `Reduce` with a narrow action gate. Rejected: in
  `core` (it runs before the children, so it sees a stale `isInitialLoadComplete` and stale
  layouts), and recomputing on every action (layout actions fire per keystroke-level event).
- Д3. The auto-present is decided once, when both inputs are ready, even if pending is empty then.
  Rejected: opening later when pending grows (only a setting flip can do that, and a surprise sheet
  is worse than ⌃⌘R).
- Д4. Pending empty while the sheet is open: auto-close. Rejected: an empty state (a sheet with
  nothing to do is noise).
- Д5. No row cap; the list scrolls. Rejected: a cap (it would hide panes the owner may want).
- Д6. The wake queue lives in reducer state and each tick re-checks pending. Rejected: one `.run`
  loop over the ids (it cannot see claims that happen during the stagger).
- Д7. Stagger 1 s (reason in Section 6).
- Д8. The command is named `wakeTabInBackground`, generic: it carries no agent data, and the
  agent decision stays in the seed.
- Д9. No hibernation exemption for a background-woken tab (Section 6).
- Д10. The menu item uses plain `store.send`, like "Archived Worktrees"; it publishes no focused
  value. The menu reads `pending.isEmpty` for its enabled state; this is not added to
  `WorktreeMenuSnapshot`, because it flips only a few times per launch. `AgentResumeState` is
  `@ObservableState`, so the menu and the palette track `pending` alone; the per-second
  `wakeQueue` pops and the `claimed` inserts do not invalidate the menu body (the #289 class).
- Д11. The palette item is listed only while something is pending. Rejected: always listed (a
  command that does nothing).
- Д12. Hotkey ⌃⌘R: free in `AppShortcuts`, and R reads as "resume".
- Д13. The marker symbol `arrow.clockwise.circle`, `.secondary`, in the dormant marker's slot.
  Both markers may show together, since a pending pane is also dormant.
- Д14. Re-wake decisions are not logged; per-pane routine refusals are debug; typed and
  record-bearing skips are info.
- Д15. A newly pending row in an open sheet (setting turned on) comes in ticked, as at open.

## Split Into Tasks

Each task is reviewed alone against the Shared Contract. Later tasks may stub earlier types.

- (a) Gate events and pending. Touches: `AgentResumeGate.swift` (`ClaimOutcome`, `claimOutcome`);
  `TerminalClient.swift` (the two events); `WorktreeTerminalManager.captureLaunchSessionLiveness`,
  `.claimAgentResume` (emit; the claim-refusal debug logs of Section 8); new
  `Features/AgentResume/Models/AgentResumeState.swift` (`AgentResumeLiveness`,
  `PendingAgentResume`, `AgentResumeState`); new `Features/AgentResume/BusinessLogic/AgentResumePending.swift`
  (`compute`, `wakeStagger`); `AppFeature` (`State.agentResume`, event handling, the post-scope
  `Reduce` with `refreshAgentResume` limited to the recompute). Tests (a). After: nothing.
- (b) Background wake. Touches: `TerminalClient.Command.wakeTabInBackground`;
  `WorktreeTerminalManager.handleManagementCommand` and the lists at `:524-533`, `:570-576`;
  `AppFeature` (`.agentResumeWakeTick`, the `wakeQueue` handling, `AgentResumeCancelID`, a
  `.resumeRequested` entry point the picker delegate calls). Tests (b). After: (a).
- (c) Picker sheet, palette, menu, hotkey. Touches: new `AgentResumePickerFeature.swift`,
  `AgentResumePickerView.swift`; `AppFeature` (`@Presents agentResumePicker`, `.ifLet`,
  `.agentResumePickerRequested`, `@Dependency(\.uuid)`, the auto-present in `refreshAgentResume`, the live row sync and
  auto-close, the palette delegate); `ContentView` (sheet, `paletteItems` argument);
  `CommandPaletteFeature` (`Delegate.resumeAgentSessions`, `items`/`commandPaletteItems`
  parameter, `CommandPaletteItemID.globalResumeAgentSessions`); `CommandPaletteItem.Kind`;
  `AppShortcuts.swift` (id, lists, names, `resumeAgentSessions`); `WorktreeCommands.swift` (menu
  item). Tests (c). After: (a), (b).
- (d) Sidebar marker. Touches: `SidebarItemFeature` (`hasPendingAgentResume`,
  `.pendingAgentResumeChanged`); `SidebarItemView` (`SidebarPendingResumeIndicator` and its slot);
  `AppFeature.refreshAgentResume` (the per-row flip fan-out). Tests (d). After: (a).
- (e) Decision logging. Touches: `TerminalSurfaceRecipe` (`AgentResumeSkip`, `agentResumeSkip`,
  `agentResumeInput` rewritten on it, the log lines in `agentResumeSeed`); the `AppFeature` log
  lines of (b) and (c) if those tasks did not add them. Tests (e). After: (a) for the manager
  lines; independent of (b)-(d) otherwise.
- (f) `docs/fork.md`, section "Agent Session Resume After Reboot": replace "Resume is lazy" with
  the picker behavior; the setting off hides the sheet and the marker; the marker; ⌃⌘R and the
  palette entry; "How to verify" from Section 10; "Keeping It On Upstream Merges" gains: keep the
  `.agentResumeLivenessCaptured` emit in the capture and the `.agentResumeClaimed` emit on a
  granted claim; keep the post-scope `Reduce` after the child scopes; keep the
  `host(for:)` pre-step in `.wakeTabInBackground`. After: (a)-(e).

## Not Confirmed

- That a re-entrant `.attachLayout` from `wireSurface` inside the `wakeTab` reduce is safe. The
  pre-step makes the host exist first, but `host(for:)` still sends `.attachLayout`
  unconditionally (`WorktreeTerminalManager.swift:772`). Today's lazy wake of a never-opened
  worktree does the same, so this is not new.
- Whether input not yet forwarded by `zmx attach` to the session is lost on an early detach, and
  whether libxev drops a queued write on a same-tick stop (ЗД1 НП1, НП3).
- Whether the shell reads input typed before its prompt or flushes it when its line editor starts
  (ЗД1 НП2). Today's lazy resume has the same exposure and works in the dev check of the
  previous spec.
- That ⌃⌘R collides with no Ghostty default keybind or user keybind. Only the app's own
  `AppShortcuts` and hard-coded shortcuts were checked.
- The exact selection-restore timing at launch, which decides whether the selected worktree's
  rows flash in the sheet (Section 3).
- That the terminal event buffer never sheds the one `.agentResumeLivenessCaptured` event. It is
  emitted before the subscription and well under `pendingEventCap = 1024`. If it were shed, no
  sheet and no marker would appear, and the lazy resume would still work.
