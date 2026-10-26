# Agent Session Resume After Reboot: Design

Task ЗДС, 2026-10-26. Fork-only feature. Inputs: recon `tmp/captain/20261026-063156/reports/recon-ЗД0.md` and probe `reports/probe-ЗД1.md` (captures under `probe/cap/`). Swift references come from grep; serena reference search returns nothing for Swift in this repo.

## Goal

After a reboot, each restored pane whose zmx session is gone and whose coding agent did not exit normally gets the agent's resume command typed and run (with Enter), once per dead session. This sits behind a setting that is on by default. v1 covers claude, codex, grok and agy.

Today Supacode restores the panes (`supacodeApp.swift:254-259`, `LayoutFeature.swift:780-790`) with their cwd and frozen grid. zmx does not survive a reboot (inferred, recon НП8), so `zmx attach` creates a fresh shell (`ZmxClient.swift:13-17`). No session id is stored (recon ДА5).

## Settled Decisions (owner and coordinator, keep exactly)

- ОП5: the resume command is typed **and run** automatically in a restored pane whose zmx session is gone and whose agent did not exit normally. A Settings toggle controls it, default ON.
- ОП8: the commands are `claude --resume <id>`, `codex resume <id>`, `grok --resume <id>` and `agy --conversation <id>`. agy is best effort.
- АР1: the SessionStart hook adds `session=<uuid>` to the OSC 3008 presence metadata, read once from stdin. The id is stored per pane on the content side as `TerminalContentState.agentSession`, not in `LayoutFeature`, `PaneLayout` topology or `agents`. It is injected once through `initialInput` on `.restored`. Rejected: pid-file lookup, and Supacode choosing the id.
- Fork-only. The feature is documented in `docs/fork.md`, never in `README.md`. Upstream code stays intact.
- Clear rule: resuming an ended session is harmless; losing the resume after a reboot is the failure. The record is cleared only on an unambiguous explicit user exit seen while the app runs:
  - claude: SessionEnd `reason` in {`prompt_input_exit`, `clear`, `logout`};
  - codex: any SessionEnd (it sends none on HUP or TERM);
  - grok and agy: never by SessionEnd. A pid death never clears the record (Д9).

## Probe Facts Used (ЗД1)

| Agent | id key (stdin) | id form | SessionStart fires | SessionEnd | Resume by UUID |
| --- | --- | --- | --- | --- | --- |
| claude | `session_id` | UUIDv4 | at start; `/clear` → new id, `--resume` keeps it | HUP/TERM `other`; `/exit`, Ctrl-D, Ctrl-C `prompt_input_exit`; `/clear` `clear` | yes |
| codex | `session_id` | UUIDv7 | first prompt only (also on resume) | none on HUP/TERM; `/exit`, Ctrl-C `other` | yes, also `codex --approve-for-me resume <id>` |
| grok | `sessionId` (+ `session_id`) | UUIDv7 | at start; `--resume` → `source:load`, same id | `shutdown` always | yes |
| agy | `conversationId` | UUIDv4 | first prompt only | no end hook | yes |

When the terminal dies, the hook's OSC write to `$__tty` fails silently (`|| true`), so the app never sees a SessionEnd from a dying pty (probe ПР0). `reason` only matters while the pty is alive.

## Shared Contract (names every part uses)

| Item | Exact name / shape | Where |
| --- | --- | --- |
| OSC fields | `session` = `AgentPresenceOSC.sessionField`, `reason` = `AgentPresenceOSC.reasonField` | `SupacodeSettingsShared/BusinessLogic/AgentPresenceOSC.swift` |
| Wire | `ESC]3008;<start\|end>=<agent>;event=<session_start\|session_end>[;pid=<ppid>][;session=<uuid>][;reason=<token>]ESC\` | same |
| Signal | `AgentPresenceOSC.Signal.sessionID: String?`, `.endReason: String?` (init params default nil) | same |
| Hook event | `AgentHookEvent.sessionID: String?`, `.endReason: String?` (memberwise params default nil; socket `init(from:)` sets nil) | `supacode/Infrastructure/AgentHookSocketServer.swift:467-575` |
| Record | `nonisolated struct AgentSessionRecord: Codable, Equatable, Sendable { let agent: String; let sessionID: String }` | new `supacode/Features/Terminal/Models/AgentSessionRecord.swift` |
| Update | `nonisolated enum AgentSessionUpdate: Equatable, Sendable { case started(AgentSessionRecord); case ended(agent: String, sessionID: String?) }` + `static func from(_ event: AgentHookEvent) -> AgentSessionUpdate?` | same file |
| Persisted | `TerminalContentState.agentSession: AgentSessionRecord?`, JSON key `agentSession` | `supacode/Features/Terminal/Models/PaneLayout.swift:50-93` |
| Command | `TerminalClient.Command.updateAgentSession(surfaceID: UUID, update: AgentSessionUpdate)` | `supacode/Clients/Terminal/TerminalClient.swift:48+` |
| Probe | `TerminalClient.captureLaunchSessionLiveness: @MainActor @Sendable () async -> Void` | same |
| Gate | `nonisolated struct AgentResumeGate: Equatable, Sendable { let liveSessionNames: Set<String>; private(set) var claimed: Set<ContentID>; mutating func claim(_ id: ContentID) -> Bool }` | new `supacode/Features/Terminal/BusinessLogic/AgentResumeGate.swift` |
| Gate owner | `WorktreeTerminalManager.agentResumeGate: AgentResumeGate?`, `captureLaunchSessionLiveness() async`, `claimAgentResume(_:) -> Bool` | `WorktreeTerminalManager.swift` |
| Text | `nonisolated enum AgentResumeCommand { static func initialInput(for: AgentSessionRecord) -> String? }` | new `.../BusinessLogic/AgentResumeCommand.swift` |
| Setting | `GlobalSettings.resumeAgentSessionsAfterRestart: Bool` = `true`, `config.json` key of the same name, read via `@Shared(.settingsFile)` `.global` | `SupacodeSettingsShared/Models/GlobalSettings.swift` |
| Builder | `TerminalContentBuilder.claimAgentResume: (ContentID) -> Bool` | `TerminalSurfaceRecipe.swift:285-298` |
| Snapshot landing | `LayoutFeature.Action.landContentSnapshot(tabID: TabID)` (generic; copies `content.snapshot()` into the tab, like `hibernateTab`) | `supacode/Features/Terminal/Reducer/LayoutFeature.swift` |

## 1. Capture: Hook Command and OSC Parse

**Emit.** `AgentHookSettingsCommand.compositeCommand` (`AgentHookSettingsCommand.swift:62-75`) gets an opt-in `capturesSession: Bool = false`. Only the commands listed below pass it, so other agents' hook bytes stay the same. A byte change marks an integration `.outdated`, see Section 7.

1. After `ttyResolveSnippet`, a new `AgentPresenceOSC.sessionCaptureShell` runs `readStdinSnippet` (`AgentPresenceOSC.swift:273-274`). It then extracts `__sid` with `notifyExtractAwk` (`keys="session_id,sessionId,conversationId"`, `budget=64`) and `__rs` with `keys="reason"`, `budget=32`. Two shell filters follow: `case "$__sid" in *[!0-9A-Fa-f-]*) __sid="";; esac` and `case "$__rs" in *[!a-z_]*) __rs="";; esac`. Then it builds `__ss`: `__ss=""; [ -n "$__sid" ] && __ss=";session=$__sid"; [ -n "$__rs" ] && __ss="$__ss;reason=$__rs"`. The filters keep `;`, ESC and `%` off the wire. Strict validation is app-side.
2. `emitShell(event:agent:)` (`:220-227`) gains `includesSession: Bool = false`. When true, the metadata is `metadata(event:, pidSuffix: "%s%s")` and printf gets `"$__sp" "$__ss"`. `compositeCommand` sets it only for `.sessionStart` and `.sessionEnd` emits, not `.idle`. The default path stays byte-identical.
3. A command that both captures and forwards a notify uses `emitNotifyShell(readsStdin: false)` (`:285-294`).

Which commands capture:

| Command | Change |
| --- | --- |
| claude SessionStart | captures (`ClaudeHookSettings.swift:43-44`) |
| claude SessionEnd (`sessionEndAndIdle`) | captures, for `reason` (`:45-46`) |
| codex SessionStart | captures (`CodexHookSettings.swift:33-34`) |
| codex SessionEnd | new `"SessionEnd"` entry, `events: [.sessionEnd]`, captures. The comment at `:22-27` ("Codex has no SessionEnd") is updated: codex 0.164 fires it on `/exit` and Ctrl-C (probe Q3) |
| grok SessionStart | captures (`GrokHookSettings.swift:69-70`). SessionEnd is unchanged, since it never clears |
| agy SessionStart | captures (`AntigravityHookSettings.swift:20-21`). agy has no end hook |

`$__ppid` is the agent, so the codex SessionEnd also drops its pid from presence (consistent with today's sweep). The grok command rewrite only collapses `$$` (`AgentPresenceOSC.swift:196-198`). The `case` filters and `$(...)` already run in grok's `idleAndNotify`. A test in part (a) checks the emitted string.

**Parse** in `AgentPresenceOSC`:
- `sessionField = "session"` and `reasonField = "reason"` are both added to `dedupedFields` (`:119-121`). A repeated one makes `parseFields` return nil, so the signal drops, as with a repeated `event`.
- `parse` (`:68-80`) sets `sessionID: parseSessionID(...)` and `endReason: parseEndReason(...)`.
- `parseSessionID`: the original string when `utf8.count == 36` and `UUID(uuidString:)` is non-nil, else nil. This rejects grok titles that `--resume` would accept. The case is kept.
- `parseEndReason`: the token when it matches `^[a-z_]{1,32}$`, else nil.
- In both cases a bad value only drops that field; the presence event still parses.
- `AgentSignal.presenceEvent` (`AgentSignal.swift:45-58`) copies both into `AgentHookEvent`. The live path and the dormant path (`WorktreeContentHost.swift:1205-1209`) both pass through it.

## 2. Record Model and Persistence

`TerminalContentState` gains `let agentSession: AgentSessionRecord?` with:
- an init parameter `agentSession: AgentSessionRecord? = nil`;
- `case agentSession` in `CodingKeys` and `encodeIfPresent`;
- a tolerant decode like `agents` (`PaneLayout.swift:79-82`): `(try? container.decodeIfPresent(AgentSessionRecord.self, forKey: .agentSession)) ?? nil`.

`agent` is a `SkillAgent` rawValue string, like `SurfaceAgentRecord` (`TerminalLayoutSnapshot.swift:93-97`).

Every copy site must forward the field, or the next save silently drops it:
- `TabContent.swift:226-233` `recordedState(from:)`;
- `LayoutPersistence.swift:42-51` (agents overlay) and `:64-72` (launch strip). `record` keeps the record and strips only `launch`;
- `TerminalSurfaceRecipe.swift:339-343` (restored strip).

These sites pass nil, which is correct: `LayoutsMigrator.swift:318` and `WorktreeTerminalManager.swift:984, 1212, 1297, 1377`.

**Downgrade safety.** An older build that decodes the new key does not mark the blob lossy, so the reaper still kills nothing. Evidence:
- `TerminalContentState.init(from:)` reads only its own `CodingKeys` (`PaneLayout.swift:57-61, 75-85`).
- A keyed container ignores unknown keys.
- `LayoutDecodeLoss.droppedCount` grows only when a tab (`:283`) or a pane (`:397`) fails, so `undecodedEntryCount` stays 0 (`LayoutsMigrator.swift:88-91`) and `readPersisted` returns `.file` (`:146-166`).

There is no schema bump (memory `layouts-persistence`). An older build that writes the blob only drops resumes. The writer's no-op gate (`LayoutPersistence.swift:56-57`) holds because the field round-trips equal.

## 3. Update Path: Presence Event to Content

There is no NSNotification. The path mirrors the image-paste fan-out (`AppFeature.swift:2288-2299`, manager `WorktreeTerminalManager.swift:561-578`):

1. The OSC reaches `WorktreeContentHost.handlePresenceSignal` (`:457-471`), then `onAgentHookEvent`, then `WorktreeTerminalManager.dispatchHookEvent` (`:229+`). Session events are not debounced. Next comes `TerminalClient.Event.agentHookEventReceived`, and then `AppFeature` (`:2162-2163`).
2. `AppFeature` keeps the forward to `.agentPresence(.hookEventReceived(event))` and merges `agentSessionEffect(event)`. When `AgentSessionUpdate.from(event)` is non-nil, this effect sends `.updateAgentSession(surfaceID: event.surfaceID, update:)`.
3. `AgentSessionUpdate.from(_:)` is pure and handles only claude, codex, grok and antigravity. Other agents give nil.
   - `.sessionStart` with a `sessionID` and a `pid` gives `.started(record)`. The pid marks a local hook (`AgentPresenceOSC.swift:213-216`).
   - `.sessionEnd` gives `.ended(agent, sessionID)` only for claude with `endReason` in {`prompt_input_exit`, `clear`, `logout`} or for codex with any reason. It gives nil for grok, agy, claude `other` or a missing reason.
   - Any other event gives nil.
4. The manager handles `.updateAgentSession`. For the host that accepts it, it calls `markLayoutDirty(worktreeID:)` (`:1587-1595`), so the record reaches disk within the debounce. Add the case to the exhaustive lists at `WorktreeTerminalManager.swift:521-525`, `:563-568` and `:617`.
5. `WorktreeContentHost.updateAgentSession(_:onSurfaceID:) -> Bool` first checks `guard isKnownSurface(surfaceID) else { return false }` (`WorktreeContentHost.swift:169-171`). All hosts share one runtime (`WorktreeTerminalManager.swift:749-751`), so without this guard a host that does not own the content would accept it and the wrong worktree would get `markLayoutDirty`. It then resolves `ContentRuntime.liveValue.content(for: ContentID(rawValue:)) as? TerminalContent`. It does not use `liveSurface`, so hibernated content also updates. It then calls `TerminalContent.applyAgentSession(_:) -> Bool` with `AgentSessionRecord.applying(update, to:)`. Content that is not in the runtime is ignored, with a debug log.

## 4. Update Rules

- There is one record per pane. `.started` always replaces it: the last SessionStart wins (claude `/clear` gives a new id, `--resume` keeps the same id).
- `applying(.ended(agent, id), to: current)` clears only when `current.agent == agent` and the id is nil or equal to `current.sessionID`. For claude `/clear`, the `clear` end arrives first and the new start follows at once (probe КЛ1). A late end with the old id cannot clear the new record.
- An exit while the app is closed, or a dying pty, sends nothing, so the record survives. That case is ОП5.
- Injecting the resume does not clear the record (see Section 6). It stays until an explicit exit or a replacing SessionStart.
- Unexpected zmx close (`WorktreeTerminalManager.swift:935-939`): before `ContentRuntime.liveValue.remove`, the manager sends `.landContentSnapshot(tabID:)` so that the `.wakeTab` rebuild (`LayoutFeature.swift:780-797`) starts from the live snapshot, `agentSession` included. Today the layout snapshot is refreshed only at wake and hibernate (`LayoutFeature.swift:763, 803-806`), so a SessionStart that arrived after the last wake would be lost. The action is generic: it carries no terminal state of its own.
- Codex and agy produce no record until the first prompt (probe Q1). Such a pane has nothing to resume, which is acceptable.

## 5. Launch Liveness (Dead Set)

The probe runs once per process, before any restored pane can attach. An attach upserts the session, and after that every session looks alive.

- `.appLaunched` (`AppFeature.swift:402-412`) becomes `.concatenate(.run { await terminalClient.captureLaunchSessionLiveness() }, .merge(<existing effects>))`. The existing effects include `.repositories(.task)`.
- `captureLaunchSessionLiveness()` runs once; a second call is a no-op. It stores `agentResumeGate = probe.map { AgentResumeGate(liveSessionNames: Set($0.map(\.name))) }`. A nil probe (failed or timed out) leaves the gate nil and logs a `SupaLogger` warning `resume skipped: liveness probe failed`; nothing is injected.
- The reaper (`AppFeature.swift:431-452`, `WorktreeTerminalManager.swift:1942-1967`) is unchanged upstream code and keeps its own probe.
- `claim(id)` returns true only when `ZmxSessionID.make(surfaceID: id.rawValue)` is not live and `id` is not yet claimed; then it inserts `id` into the claimed set.
- `claimAgentResume` is wired in `supacodeApp.swift:388-420` as `{ [weak terminalManager] in terminalManager?.claimAgentResume($0) ?? false }`.

**Why no attach happens before the probe (was ЗДС2).** These steps are ordered:
1. `hydrateLayouts` only sends layouts into state (`supacodeApp.swift:254-259`).
2. A real surface needs the worktree. Without it the builder returns `InertTabContent`, which never attaches (`TerminalSurfaceRecipe.swift:313-318`).
3. Worktrees load only from `.repositories(.task)`, through `.loadPersistedRepositories`. The sidebar focus is restored after that (`RepositoriesFeature.swift:3704-3710`).
4. With the concatenate, `.repositories(.task)` starts after the probe returns. The probe takes about 100 ms, at most 5 s (`ZmxClient.swift:47-52`).

Part (d) **starts with tests** that prove this:
- (i) an `AppFeature` TestStore on `.appLaunched` with a recording `captureLaunchSessionLiveness` stub (a `LockIsolated` call log) shows the probe call completes before `.repositories(.task)` is received;
- (ii) a `TerminalContentBuilder` test shows that a `.restored` request whose worktree lookup is nil yields `InertTabContent` and calls no `makeSurface`.

If either fails, part (d) escalates. The alternatives touch layout wake mechanics and need an owner decision.

When a `.first`/`.restored` spawn finds a record but no gate, it logs a `SupaLogger` warning `resume skipped: liveness not captured`, separate from the probe-failure log.

## 6. Injection (One Inject per Process)

A new branch goes in `TerminalContentBuilder.terminalContent`'s `makeSurface`, right after the unchanged `.restored` strip (`TerminalSurfaceRecipe.swift:335-344`):

```swift
if phase == .first, request.origin == .restored,
  let input = TerminalSurfaceRecipe.agentResumeInput(
    record: currentState.agentSession, worktree: worktree,
    zmxAvailable: zmxExecutablePath() != nil, enabled: settingsFile.global.resumeAgentSessionsAfterRestart),
  claimAgentResume(request.contentID)
{
  seedState = TerminalContentState(/* seedState fields */, launch: LaunchOverride(initialInput: input))
}
// plan + view and SpawnedSurface as today
```

- `agentResumeInput(record:worktree:zmxAvailable:enabled:)` is pure. It returns nil unless all hold: `enabled`; `worktree.host == nil` (never for SSH worktrees); `zmxAvailable` (without zmx there is no `supa-*` session); a non-nil record. `claim` runs last, so a gate slot is spent only on a real inject.
- `phase == .first` together with the original `request.origin` excludes a re-wake. A re-wake only rewrites `effective.origin` (`:331-334`).
- A content rebuilt after an unexpected close (`WorktreeTerminalManager.swift:935-938`) is a new `.first`/`.restored` content. `claimed` blocks a second inject in the same process.
- If the spawn fails after a claim (`view.surface == nil`, `:374-376`), the slot is spent and the record stays, so the next launch retries. This is intended.
- The override lives only in the plan seed. Persistence strips `launch` (`LayoutPersistence.swift:58-74`).
- There is no consume: injecting does not clear the record. Codex and agy fire SessionStart only at the first prompt (probe КЛ3, Q1), so clearing would lose the resume on a second reboot when the user only read the resumed conversation. Nothing replays it. In this process `claimed` blocks a second inject. At the next launch the session created by the inject is alive, so `claim` is false. Only a dead session at a later launch, meaning another reboot, injects again, and that is wanted. A resumed agent's SessionStart writes the same id (probe КЛ2-КЛ4).

**Command text.** `AgentResumeCommand.initialInput(for:)` re-checks `UUID(uuidString:)` and quotes the id with `SSHCommand.shellQuote` (`SSHCommand.swift:64-66`). The first word is bare, so shell aliases apply. The probe confirmed `codex --approve-for-me resume <id>` works (probe РЗ3). The text ends with `\n`, as in `BlockingScriptRunner.makeCommandInput` (`BlockingScriptRunner.swift:15-20`).

| Agent | Typed text |
| --- | --- |
| claude | `claude --resume '<id>'\n` |
| codex | `codex resume '<id>'\n` |
| grok | `grok --resume '<id>'\n` |
| antigravity | `agy --conversation '<id>'\n` |

Any other agent gives nil.

## 7. Hook Reinstall and Codex Trust

How the hooks get updated:
- Installed hooks are byte-compared with the expected commands. Any difference gives `.outdated` (`AgentHookSettingsFileInstaller.swift:44-53`, `CodexSettingsInstaller.swift:56-62`, `AntigravitySettingsInstaller.swift:104-129`).
- `.settings(.task)`, sent from `.appLaunched`, runs `.refreshAgentIntegrationStates` (`SettingsFeature.swift:321-331`).
- An `.outdated` integration is reinstalled once per session (`:596-602`).

So the first launch of the new build updates the claude, codex, grok and agy hooks without user action. Agents that are already running keep their old hooks until they restart. An old hook sends no `session=`, so that pane gets no resume and no error, and its signals parse as today.

**Codex trust.** Codex keeps a per-hook trust hash in `~/.codex/config.toml` (`[hooks.state."<hooks.json path>:<event>:<i>:<j>"] trusted_hash`; four such entries exist for Supacode's hooks on this machine). A changed or new command therefore shows codex's "Hooks need review" prompt on the next codex start (probe КФ2, НП5). That prompt is codex's own security gate, and Supacode never writes `hooks.state` (Д10). The user approves once.

Expected until then (not confirmed): codex skips the unapproved SessionStart and the new SessionEnd, so codex panes get no record and no resume, and nothing errors.

Docs: `docs/fork.md` and the setting's footer say that codex asks for one review after the update. Not confirmed: whether codex runs the other trusted hooks while one is pending review.

## 8. Setting and UI

- `GlobalSettings.resumeAgentSessionsAfterRestart` follows `richAgentNotificationsEnabled` end to end:
  - `GlobalSettings.swift`: field `:171`, default `:244`, init param `:290`, assignment `:340`, decode `:519-521`;
  - `SettingsFeature.swift`: state `:81`, load `:221`, normalize `:418`, write-back `:1247`.
- The toggle goes in `DeveloperSettingsView.swift:23-33`, after "Agent badges": `Text("Resume agents after restart")` with the secondary text "After a reboot, panes whose agent was still running type and run its resume command (claude, codex, grok, agy)." It gets `.help(...)`, system fonts and colors only, and no hotkey.
- The recipe reads the setting with `@Shared(.settingsFile)` (as `TerminalSurfaceRecipe.swift:48` does).

## 9. Tests (Swift Testing; `TestClock`, never `Task.sleep`)

Targets come from the `Project.swift` globs (memory `test-and-lint-traps`).

- (a) `AgentPresenceOSCTests`:
  - lower- and uppercase UUIDs parse;
  - non-UUID values, 35/37 characters, a grok title, an empty value and a bad `reason` drop only that field;
  - a duplicate `session=` or `reason=` gives nil;
  - signals without the new fields are unchanged.

  `AgentHookCommandTests`:
  - commands without `capturesSession` are byte-identical to today;
  - a shell run of each capturing command on the probe's stdin fixtures (`probe/cap/*/Session*.stdin.json`, copied into the test bundle) emits `;session=<uuid>` and `;reason=prompt_input_exit`;
  - forged `;` or ESC is dropped.

  `GrokHookSettingsTests` and the codex/agy settings tests are updated, including the new codex `SessionEnd`.
- (b) `LayoutPersistenceTests`:
  - `record(for:)` keeps `agentSession` through the overlay and the strip;
  - the encode/decode round trip is equal;
  - an extra unknown key under `terminal` gives `undecodedEntryCount == 0` and `.file`;
  - a malformed `agentSession` drops only that field.
- (c) Host ownership: with hosts A and B, an update for B's surface sent through A returns false and marks only B dirty. Unexpected close: after a SessionStart the rebuilt content carries the new `agentSession`. Table tests for `AgentSessionUpdate.from`, covering every row of Section 3 step 3 (each claude reason, codex end, grok `shutdown`, pid nil, unsupported agent), and for `applying`. An `AppFeature` test with a recorded `terminalClient.send` checks that the command is sent and presence is still forwarded.
- (d) First the two order tests of Section 5. Then:
  - `AgentResumeGate`: a live name never claims; a dead one claims once;
  - `captureLaunchSessionLiveness`: once only, and a nil probe gives no gate (`WorktreeTerminalManagerReaperTests` style);
  - `TerminalSurfaceRecipeTests`: `agentResumeInput` nil cases, and the text and quoting per agent;
  - the record stays after an inject; a second `claim` in the same process is false.

  Existing `.appLaunched` tests stub the new endpoint.
- (e) `GlobalSettings`: a missing key decodes as `true`. The `SettingsFeature` binding round-trips. Reset `@Shared` with `defer`.

## 10. Dev Verification

"Build to test" means `make install-dev-build`, then the owner restarts the app.

1. In Supacode, start `claude` in one pane and `codex` in another, and send one prompt to each. On codex, approve the hook review once. In each pane, note `echo $SUPACODE_SURFACE_ID $ZMX_DIR`.
2. Quit Supacode normally.
3. Simulate the reboot from Terminal.app: with that `ZMX_DIR`, run the bundled `zmx` (`<app>/Contents/Resources/zmx/zmx`, `ZmxClient.swift:62-66`) as `kill supa-<surface id>` for each pane. With the app down, nothing receives a SessionEnd, as at a real reboot.
4. Relaunch. Expected: the panes type and run `claude --resume '<id>'` and `codex resume '<id>'` (alias applied), and the conversations are back. Console shows no `resume skipped: liveness not captured`.
5. Relaunch again without killing anything. Expected: nothing is typed.
6. Negative checks. Each of these gives no inject after step 3:
   - claude `/exit` (`prompt_input_exit`) while the app runs;
   - codex `/exit`;
   - the setting off;
   - a remote worktree.

   A grok pane closed with `/exit` is resumed. That is harmless by rule.

## Decisions (beyond the settled ones)

- Д1. The update goes through `AppFeature` and a `TerminalClient.Command`, as image paste does. Rejected: a direct hop in `dispatchHookEvent`, which bypasses the TestStore, and a new `AgentPresenceFeature` delegate, which adds an unneeded duty.
- Д2. Capture is opt-in per command (`capturesSession`). The hooks of other agents stay byte-identical and are not flagged `.outdated`.
- Д3. A dedicated probe is concatenated before the rest of `.appLaunched`. Rejected: reusing the reaper's probe (it races under `.merge`, `AppFeature.swift:432-434`), and deferring restored spawns.
- Д4. The gate holds live names and a `claimed` set, which makes the inject one-shot within a process. Across launches, liveness does the same job: the injected session is alive at the next launch. The record is never consumed (review r1 F1).
- Д5. Only SessionStarts that carry a pid (local hooks) are stored. Remote host and zmx are checked again at inject time.
- Д6. No `cd` in the typed text: the restored cwd is the shell's pwd, which is the agent's start directory.
- Д7. Rejected: gating on the stored `agents` record. The shutdown save races SessionEnd and the liveness sweep.
- Д8. The id case is kept as received. Validation is `UUID(uuidString:)` plus a length of 36.
- Д9. No clear on agent pid death. The liveness sweep runs every 2 s (`AgentPresenceFeature.swift:115, 145`). At logout or reboot, nothing in the code orders zmx daemon death before app termination. A sweep could therefore see the agent dead and clear the record before the app quits, which is exactly the failure the clear rule avoids. Probe ПР5 is rejected for this reason.
- Д10. Supacode does not write codex `hooks.state` trust hashes. Writing them would bypass codex's review gate for the user. A one-time review prompt is the accepted cost.
- Д11. `reason` travels as its own allowlisted OSC field, not packed into `event`. That keeps `HookEvent` unchanged for every other agent.

## Split Into Tasks

Each part is reviewed alone against the Shared Contract. Later parts may stub earlier types.

- (a) Hook and OSC. Touches `AgentPresenceOSC` (fields, `dedupedFields`, `Signal`, parsers, `sessionCaptureShell`, `emitShell(...includesSession:)`), `compositeCommand(...capturesSession:)`, the commands in the Section 1 table (including the new codex `SessionEnd`), `AgentSignal.presenceEvent` and `AgentHookEvent.sessionID`/`.endReason`. Tests (a).
- (b) Record and persistence. Adds `AgentSessionRecord.swift` (record, update, `applying`) and `TerminalContentState.agentSession`, and updates every copy site in Section 2. Tests (b).
- (c) Presence to content. Covers `AgentSessionUpdate.from`, `AppFeature.agentSessionEffect`, the command, the manager handler with its three exhaustive lists and `markLayoutDirty`, the host and content setters with the `isKnownSurface` guard (F4), and `LayoutFeature.landContentSnapshot` with its send in `handleUnexpectedZmxClose` (F2). Tests (c). Depends on the types from (a) and (b).
- (d) Liveness and inject. Starts with the Section 5 order tests. Covers `AgentResumeGate`, `AgentResumeCommand`, the client endpoint (`supacodeApp.swift:335-350`), the `.appLaunched` concatenate, the gate methods, the builder closure (`supacodeApp.swift:388`), the `makeSurface` branch, `agentResumeInput` and the probe-failed warning. Tests (d). Depends on (b) and the setting name from (e).
- (e) Setting and UI. Touches `GlobalSettings`, `SettingsFeature` and `DeveloperSettingsView`. Tests (e).
- (f) `docs/fork.md`: a section "Agent Session Resume After Reboot" with:
  - a setting table;
  - the commands;
  - the conditions;
  - the clear rule;
  - the one-time codex hook review;
  - "Keeping It On Upstream Merges": keep `capturesSession` on the listed commands, the codex `SessionEnd` entry, `agentSession` at every copy site and in `LayoutPersistence.record`, and the `.appLaunched` concatenate.

## Not Confirmed

- That zmx dies at reboot. This is inferred (recon НП8); a real reboot was never tested (probe НП1).
- That a real logout delivers no claude/codex SessionEnd OSC. Even if one arrives, claude `other` and codex-without-end keep the record.
- Grok `/clear` (docs say it gives a new id with `source:new`) and agy `/clear` were not tested.
- Whether codex runs the other trusted hooks while one hook is pending review.
- The bundled zmx path in the dev build.
- Two app instances on the same layouts (review r1 F6). This is not a supported setup. If it happens, the second instance can create `supa-<id>` and then type the resume into it after the first instance's launch probe.
- Nested agents in one pane (review r1 F7), e.g. codex started by Claude. Unproven: a codex started from Claude's Bash tool likely has no tty for its OSC. If it is reached, codex's start replaces claude's record and codex's end clears it. Options: (A) one record, last start wins (current); (B) a per-pane stack keyed by agent, where `.ended` removes only that agent's entry and the resume uses the top entry; (C) store the hook pid and ignore starts from a descendant of the recorded agent. Recommendation: A, switch to B if a dev check shows the nesting.
