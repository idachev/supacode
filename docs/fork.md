# Fork Notes

This repository is a fork of [supabitapp/supacode](https://github.com/supabitapp/supacode).
The fork's working branch is `idachev-supacode` on the `idachev` remote; `main` only mirrors
upstream `origin/main`. This file lists where the fork deliberately differs from upstream, so
each upstream merge can keep those differences.

## License Enforcement Is Off By Default

Upstream 0.11.0 added licensing: a release build asks for a license after five local worktree
creations, checks Team entitlement leases, and blocks updates past a license's included
updates. The fork keeps all of that code, so upstream merges apply cleanly, but switches the
enforcement off with one build setting.

| Setting | Where | Default | Effect |
| --- | --- | --- | --- |
| `SUPACODE_LICENSE_ENFORCED` | `Configurations/Project.xcconfig` | `NO` | `YES` adds the `SUPACODE_LICENSE_ENFORCED` Swift compilation condition |

`LicenseBuild.isEnforced` (`supacode/Features/License/Models/LicenseSnapshot.swift`) is `true`
only for a Release build compiled with that condition:

```swift
#if DEBUG || !SUPACODE_LICENSE_ENFORCED
  false
#else
  true
#endif
```

- Debug builds (`make build-app`, `make install-dev-build`) never enforce, the same as upstream.
- Release builds (`make archive`) enforce only when the setting is `YES`.
- Settings → License stays visible either way; with enforcement off it limits nothing.

To build a Release with upstream licensing, set the value to `YES` in
`Configurations/Project.xcconfig`, or pass it in an `XCODE_XCCONFIG_FILE` override (the way
`.github/workflows/main.yml` passes `SUPACODE_RELEASE_DAY`), or on the command line:

```bash
xcodebuild -workspace supacode.xcworkspace -scheme supacode -configuration Release SUPACODE_LICENSE_ENFORCED=YES build
```

Check which condition a configuration gets:

```bash
xcodebuild -workspace supacode.xcworkspace -scheme supacode -configuration Release -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS
```

### Keeping It On Upstream Merges

- A conflict in `Configurations/Project.xcconfig` usually comes from a version bump: keep
  upstream's `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, and keep the fork's
  `SUPACODE_LICENSE_*` block at the end of the file.
- If upstream changes `LicenseBuild.isEnforced`, keep the `!SUPACODE_LICENSE_ENFORCED` term in
  its condition.
- If upstream adds a new licensing gate, make sure it reads `LicenseBuild.isEnforced` or
  `LicenseClient.isEnforced`, so the setting still switches it off.

## Sidebar: Active Above Pinned

Upstream shows the global **Pinned** section first and keeps a pinned row in **Pinned** even
while an agent or script runs in it. The fork shows **Active** first, and **Active** claims its
rows before **Pinned**:

- A pinned worktree that starts an agent or a script moves into **Active**. It goes back to
  **Pinned** when it no longer classifies as active (`SidebarActiveClassification`).
- With **Group Active Rows** off, the row stays in **Pinned**.
- Hotkey slots and the menu bar list follow the same order: Active, then Pinned.
- Rows inside **Active** keep upstream's alphabetical order (unread first when "move notified
  worktree to top" is on). A newest-activity order was tried and reverted (`02e78b0c`):
  rows jumped on every agent or notification event.

The change lives in `computeHighlightHoists` and `computeSidebarStructure`
(`supacode/Features/Repositories/BusinessLogic/SidebarStructure.swift`) and in
`MenuBarSections.entries` (`supacode/Features/App/Models/MenuBarNotificationList.swift`).

### Keeping It On Upstream Merges

- If upstream edits `computeHighlightHoists`, keep Active computed first with no exclusions,
  and Pinned computed with `excluding:` the Active rows.
- Keep `.active` before `.pinned` in the sections list, in `computeHotkeyOrdering`, and in
  `MenuBarSections.entries`.
- The tests `pinnedActiveRowMovesIntoActiveAboveThePinnedSection` and
  `entriesRenderInActiveThenPinnedThenUnreadOrder` fail if a merge brings back the upstream order.

## Terminal Layout: Splits in Each Tab

Upstream #786 (`58438348`) replaced the old "split per tab" terminal layout with "tabs per
split": one split tree per worktree, and every pane has its own tab strip. The fork adds a
global setting that brings the old behaviour back on top of the new model. Upstream's layout
stays the default, so a merge that does not touch the layout code needs no attention.

| Setting | Where | Default | Values |
| --- | --- | --- | --- |
| Terminal Layout | Settings → Terminal; `terminalLayoutMode` in `~/.config/supacode/config.json` | `tabsPerSplit` | `tabsPerSplit` ("Tabs in Each Split", upstream), `splitPerTab` ("Splits in Each Tab") |

In **Splits in Each Tab** a worktree has one tab strip above its panes. Each top-level tab
holds its own split tree and zoom, and each split holds exactly one terminal. ⌘T opens a
top-level tab, ⌘1…9 and next / previous switch top-level tabs, and ⌘W closes the focused
terminal; closing the last terminal of a tab closes the tab. There is no separate "close the
whole tab" command (owner's decision).

Switching the setting converts every open layout at once, and no terminal closes. Tabs per
split → splits in each tab: the current split, with each pane's selected tab, becomes tab 1,
and every other tab becomes its own tab. Back: the selected tab's split becomes the panes, and
the terminals of the other tabs go as tabs into the focused pane, so their split arrangement is
lost. A hand edit of `terminalLayoutMode` in `config.json` applies at the next launch.

The design is in [plans/done/2026-10-23-split-per-tab-mode-design.md](plans/done/2026-10-23-split-per-tab-mode-design.md).
The main pieces:

- Model: `PaneLayout` keeps a flat `panes` list for every group, plus one split tree per group
  (`PaneGroup`, `parkedGroups`, `activeGroupID`), in
  `supacode/Features/Terminal/Models/PaneLayout.swift`. In upstream mode the group fields are
  empty.
- Reducer: `LayoutFeature.State.mode` and the group actions in
  `supacode/Features/Terminal/Reducer/LayoutFeature.swift`; `TerminalsFeature.layoutModeChanged`
  converts every layout.
- Persistence: the schema stays at version 2. The stored `layout` is always an upstream-shaped
  layout that holds every terminal, and the grouping is an optional `splitPerTab` sidecar on
  `LayoutRecord`. An upstream build reads the layout flattened and kills no session.
- Views: `WorktreeGroupStripView.swift` is the top-level tab strip.

### Keeping It On Upstream Merges

- Keep `tabsPerSplit` as the default and keep upstream's code paths for it unchanged.
- A new `LayoutFeature.Action` needs a row in `LayoutFeature.isExemptFromConsistencyCheck`,
  `TerminalsFeature.canAffectVisibility`, `RecentTerminals.canChangeCurrentTab` and, if it
  removes tabs, `RecentTerminals.canRemoveTabs` (it has a `default`, so the compiler does not
  catch a miss).
- Code that lists every terminal (the launch reaper, `allContentIDs`, Recent Terminals pruning,
  the sidebar projection) must read the flat `panes`. Code that picks a pane for focus must pick
  from the active tree, never from `panes.first`.
- If upstream bumps the layouts schema, keep the `splitPerTab` sidecar optional and keep the
  stored `layout` in the upstream shape.
- The suites `SplitPerTabLayoutTests`, `LayoutFeatureSplitPerTabTests`,
  `LayoutsSplitPerTabPersistenceTests` and `WorktreeGroupStripTests` fail if a merge breaks the
  mode.

## Agent Session Resume After Reboot

zmx sessions do not survive a reboot, so after a restart Supacode restores each pane with its
cwd and frozen grid, and `zmx attach` starts a fresh shell. The fork types and runs the coding
agent's resume command in such a pane, so the conversation comes back. Upstream does nothing here.

| Setting | Where | Default | Effect |
| --- | --- | --- | --- |
| Resume agents after restart | Settings → Developer; `resumeAgentSessionsAfterRestart` in `~/.config/supacode/config.json` | on | off: nothing is typed after a restart, no resume sheet, no sidebar marker |

The command is typed and run with Enter. Its first word is bare, so your shell aliases apply,
and the session id is shell-quoted:

| Agent | Typed command |
| --- | --- |
| claude | `claude --resume '<id>'` |
| codex | `codex resume '<id>'` |
| grok | `grok --resume '<id>'` |
| agy (best effort) | `agy --conversation '<id>'` |

A pane gets its command only when all of these hold:

- The setting is on.
- The pane's zmx session is gone at launch. Supacode probes the live zmx sessions once per
  launch, before any restored pane can attach. If the probe fails, nothing is typed and a
  `resume skipped: liveness probe failed` warning is logged.
- The worktree is local (never SSH) and zmx is available.
- The agent did not exit explicitly while the app ran (the clear rule below).
- The SessionStart hook captured a record for the pane. The hook adds `session=<uuid>` to the
  OSC 3008 presence metadata, read once from the hook's stdin, and the id is stored per pane as
  `TerminalContentState.agentSession` (JSON key `agentSession` in the `layoutsFile` JSON blob in
  UserDefaults).

**Pending.** A pane is pending when all of these hold (one rule for the sheet, the palette entry,
the menu item and the sidebar marker):

- The pane has a stored record (`TerminalContentState.agentSession` is not nil).
- The setting is on.
- The worktree is local (no SSH host) and is known to the app.
- The launch liveness probe is done, and the pane's `supa-*` zmx session is not in its live set.
  If the probe failed, or zmx cannot spawn a session, nothing is pending.
- The pane did not spend its resume slot in this process (no first spawn yet).

**The resume sheet.** After launch, when the probe is done, the repositories are loaded and
something is pending, the "Resume agent sessions" sheet opens:

- One row per pending pane: `repository / worktree`, the stored tab title, the agent and the
  first 8 characters of the session id (the tooltip shows the full id). Every row is ticked.
- "Resume selected" (Return) wakes the ticked panes in the background, one per second, in row
  order. A woken pane is not shown and the selection and focus do not change. The pane types
  and runs its resume command as above. To see the result, open the worktree.
- "Not now" (Esc) closes the sheet. An unticked or dismissed pane stays lazy: it runs its resume
  when it is first shown, and its worktree keeps the sidebar marker.
- The sheet decides once per launch. It does not open again by itself, also when the setting is
  turned on later. It follows pending live: a pane that you open meanwhile drops off, and the
  sheet closes itself when nothing is pending.
- Reopen it with ⌃⌘R, the menu item Worktrees → "Resume Agent Sessions…", or the command palette
  entry "Resume Agent Sessions". The menu item is disabled and the palette entry is absent while
  nothing is pending. The palette entry is visible on an empty palette query.
- Each wake spawns a surface, a `zmx attach` and an agent; the 1 s stagger keeps that load low.
  A woken pane is hidden, so it hibernates after the usual 5-minute grace. Hibernation only
  detaches; the agent keeps running in zmx. A memory-pressure detach in the first moments after
  a wake can lose the typed command (accepted risk); the next launch retries.

**The sidebar marker.** A worktree with at least one pending pane shows `arrow.clockwise.circle`
(secondary color) in the sidebar row, before the hibernation "zzz" marker; both can show. The
tooltip says an agent session waits for a resume and names ⌃⌘R. The marker goes away when the
last pending pane of the worktree is claimed (a background wake or a lazy show), when the setting
is turned off, and it is absent after a relaunch where the zmx sessions are still alive. Turning
the setting on again brings back the markers of the panes that are still unclaimed.

How it behaves:

- There is one record per pane, and the last valid local SessionStart wins (panel decision
  ОВ2). A start is stored only when it carries a session id and the pid of a hook that ran on
  this machine. The id must be a UUID of exactly 36 characters, and the typed command checks
  that again. Claude `/clear` gives a new id, and `--resume` keeps the same one.
- Every first spawn of a pane, whatever its origin, spends that pane's one resume slot for the
  process, and the claim runs before the checks for `.restored`, the setting and the record. So
  a pane that already ran in this process, such as a rebuild after an unexpected zmx close, never
  gets the command typed into its live session. A re-wake is not a first spawn and never claims.
- Typing the command does not clear the record. The resumed session is alive at the next
  launch, so nothing is typed again. The command is typed again at any later launch where the
  pane's zmx session is gone and the record is still there, such as another reboot or a zmx
  session killed while the app was closed.
- Codex and agy fire SessionStart at the first prompt, so a pane that never got a prompt has
  nothing to resume.

**Clear rule.** Resuming an ended session is harmless, while losing the resume after a reboot is
the failure. So the record is cleared only on an unambiguous explicit exit seen while the app
runs:

- A SessionEnd clears only the record of the same agent, and only when it carries no session id
  or the stored one. A late end of an old session or an end from another agent keeps the record.
- claude: SessionEnd `reason` is `prompt_input_exit`, `clear` or `logout`.
- codex: any SessionEnd (it sends none on HUP or TERM).
- grok and agy: never by SessionEnd. A grok pane closed with `/exit` is resumed, which is
  harmless.
- An agent pid death never clears the record: at logout or reboot a liveness sweep could see the
  agent dead before the app quits.

**Codex asks for one review after the update.** The update changes the codex hook commands
(SessionStart captures the id, and a new SessionEnd entry is added). Codex keeps a trust hash per
hook and shows its own "Hooks need review" prompt on the next codex start. Approve it once.
Supacode never writes the codex trust hashes, because that would bypass codex's review gate.
Until you approve, codex panes most likely get no record and no resume, and nothing errors (not
confirmed). Agents that are already running keep their old hooks until they restart, so those
panes get no resume either.

**Known risk.** OSC 3008 signals are unauthenticated. Anything that writes to the pane (for
example `cat` of an untrusted file, or remote output) can plant, replace or clear the pane's
resume record. The typed command has a fixed form with a strict, shell-quoted UUID, so no
arbitrary command can run. But after a reboot the pane may resume a wrong or non-existent
session, or lose its real resume. The owner accepted this risk on 2026-10-26 (a single-user
work machine), so no hardening is planned. Turn the setting off to opt out.

If your Ghostty config sets `command` (a program other than a shell), the restored pane runs that
program, and the typed resume would reach it as input. Turn "Resume agents after restart" off
in that case. Supacode cannot read Ghostty's `command` value, because the Ghostty C API exposes
no value for it.

**Logging.** Each resume decision writes one `SupaLogger` line. `<short>` is the first 8
characters of the session id.

| Category | Line | Level | When |
| --- | --- | --- | --- |
| `TerminalContentBuilder` | `resume typed: agent=<a> session=<short> content=<uuid>` | info | the command is typed |
| `TerminalContentBuilder` | `resume skipped: <reason> agent=<a> session=<short> content=<uuid>` | info | a pane with a record is skipped; reason `settingOff`, `remote` or `zmxMissing` |
| `TerminalContentBuilder` | `resume skipped: unsupported record agent=<a> content=<uuid>` | warning | the record gives no command |
| `TerminalContentBuilder` | `resume skipped: no record content=<uuid>` | debug | a first spawn without a record |
| `TerminalContentBuilder` | `resume skipped: not restored content=<uuid>` | debug | a first spawn that is not a restore |
| `Terminal` | `resume claim refused: live content=<uuid>` | debug | the pane's zmx session was alive at launch |
| `Terminal` | `resume claim refused: already claimed content=<uuid>` | debug | the slot is already spent |
| `Terminal` | `resume claim refused: no gate content=<uuid>` | debug | the liveness probe failed |
| `Terminal` | `resume skipped: liveness not captured` | warning | a spawn before the probe ended |
| `Terminal` | `resume skipped: liveness probe failed` | warning | the probe failed |
| `Terminal` | `background wake skipped: tab <uuid> gone` | debug | the woken tab no longer exists |
| `App` | `resume picker shown: <n> pending` | info | the sheet opens |
| `App` | `resume requested: <k> of <n> selected` | info | "Resume selected" |
| `App` | `resume wake sent: worktree=<id> tab=<uuid>` | info | one background wake |
| `App` | `resume wake skipped: no longer pending content=<uuid>` | debug | a queued pane was claimed or closed meanwhile |
| `App` | `resume picker closed: nothing pending` | debug | the sheet closes itself |
| `App` | `resume picker not shown: <n> pending, open=<bool>` | debug | ⌃⌘R while nothing is pending or the sheet is open |

A re-wake of a hibernated pane logs nothing. In a release build `SupaLogger` writes to the
unified log with the subsystem `app.supabit.supacode` and the category from the table (debug and
info go out as `notice`, so they show without extra flags). Watch them live:

```bash
log stream --style compact --predicate 'subsystem == "app.supabit.supacode" AND eventMessage CONTAINS "resume"'
```

Or filter Console.app on subsystem `app.supabit.supacode` and the text `resume`. A DEBUG build,
such as the one from `make install-dev-build`, only prints `[<category>] <message>` to stdout and
writes nothing to the unified log. To see those lines, quit the app and start its binary from a
terminal:

```bash
/Applications/supacode.app/Contents/MacOS/supacode 2>&1 | grep -i resume
```

**How to verify** (design Section 10 of the picker spec):

1. Run `make install-dev-build` and restart the app. In Settings → Developer, check that the
   Claude and Codex integrations are installed and up to date: only an `.outdated` integration
   is reinstalled automatically, and a missing one stays missing, so no record is captured.
   Check that "Resume agents after restart" is on.
2. Open three local worktrees, A, B and C. Start `claude` in a pane
   of A and of B, and `codex` in a pane of C. Send one prompt to each, and approve the codex hook
   review once. Note `echo $SUPACODE_SURFACE_ID $ZMX_DIR` in each pane. Select A last.
3. Quit Supacode. With that `ZMX_DIR`, run the bundled `zmx`
   (`<app>/Contents/Resources/zmx/zmx`) as `kill supa-<surface id>` for each pane, with the
   surface id in lower case (`SUPACODE_SURFACE_ID` is upper case, the session name is lower
   case; `zmx list` shows the exact names). This simulates the reboot: with the app down,
   nothing receives a SessionEnd.
4. Relaunch (from a terminal, as in **Logging**, to see the lines). Expected: the "Resume agent
   sessions" sheet lists the pending panes, every row ticked. A's row can show and drop at once,
   because A is selected and resumes lazily. B and C show the sidebar marker.
5. Untick C and press "Resume selected". Expected: without selecting B, B's marker goes away
   within a second. Open B: the pane ran `claude --resume '<id>'` and the conversation is back.
   Log: `resume picker shown`, `resume requested: 1 of 2 selected`, `resume wake sent`,
   `resume typed`.
6. Expected: C keeps its marker. Press ⌃⌘R: the sheet shows only C. Press Esc. Open C: it resumes
   lazily, and its marker goes away. ⌃⌘R now does nothing, and the palette has no "Resume Agent
   Sessions" entry.
7. Relaunch without killing anything: no sheet, no marker, nothing is typed.
8. Turn the setting off, repeat steps 3 and 4: no sheet, no marker, nothing is typed. Nothing is
   typed either when claude or codex was closed with `/exit`, or in a remote worktree.
9. Do one real reboot with agents in panes of several worktrees, and check the sheet and the
   resume after it.

A real reboot has not been tested yet, only killed zmx sessions. The designs are in
[plans/done/2026-10-26-agent-session-resume-design.md](plans/done/2026-10-26-agent-session-resume-design.md)
and [plans/2026-10-26-agent-resume-picker-design.md](plans/2026-10-26-agent-resume-picker-design.md).

### Keeping It On Upstream Merges

- Keep `capturesSession: true` on the hook commands that pass it: claude SessionStart and
  SessionEnd, codex SessionStart and SessionEnd, grok SessionStart, agy SessionStart (in the
  `*HookSettings.swift` files; `AgentHookSettingsCommand.compositeCommand` takes the flag). Other
  agents' hook bytes must stay unchanged.
- Keep the codex `SessionEnd` entry in `CodexHookSettings.swift`.
- Keep `agentSession` at every copy site of `TerminalContentState` (`recordedState(from:)`, the
  restored strip in `TerminalSurfaceRecipe`, `LayoutPersistence`) and in
  `LayoutPersistence.record(for:)`, which keeps the record and strips only `launch`. A copy that
  drops it loses the resume on the next save.
- Keep the `.appLaunched` concatenate in `AppFeature`: the launch liveness probe must finish
  before `.repositories(.task)` starts, or an attach makes every session look alive.
- Keep the claim on every first spawn: `TerminalContentBuilder` calls
  `TerminalSurfaceRecipe.agentResumeSeed`, which claims before it checks `.restored`, the setting
  and the record. The claim goes through the `claimAgentResume` closure wired in `supacodeApp` to
  `WorktreeTerminalManager.claimAgentResume` and `AgentResumeGate.claimOutcome`. Claiming only on a real
  inject would let a rebuilt content type the command into its live session.
- Keep the `landContentSnapshot(tabID:)` call in `handleUnexpectedZmxClose`
  (`WorktreeTerminalManager`), before `ContentRuntime.liveValue.remove`, so the rebuilt content
  starts from the live snapshot.
- Keep the two gate events in `WorktreeTerminalManager`: `captureLaunchSessionLiveness` emits
  `.agentResumeLivenessCaptured(liveSessionNames:)` once (nil when the probe failed or
  `zmxClient.executableURL()` is nil), and `claimAgentResume` emits `.agentResumeClaimed` only
  on a `.granted` `AgentResumeGate.claimOutcome`. Without them the reducer sees no pending pane,
  or keeps a stale row and marker.
- Keep the post-scope `Reduce` in `AppFeature.body` after the child scopes (next to
  `trackRecentTerminalAccess`). It calls `refreshAgentResume`, gated by
  `AppFeature.affectsAgentResume`. In `core` it would see a stale `isInitialLoadComplete` and
  stale layouts. A new `LayoutFeature.Action` that removes, renames or moves a tab, or re-mints
  the panes like `.convertMode`, needs a row in `affectsAgentResume` (it has a `default`, so the compiler does not catch a miss).
- Keep the `host(for:)` pre-step for `.wakeTabInBackground` (`handleManagementCommand` calls the
  private `WorktreeTerminalManager.wakeTabInBackground(_:in:)`), before `sendLayout(.wakeTab(id:))`, as
  `splitPane` does. It makes the host of a never-opened worktree exist before the `wakeTab`
  reducer runs.
- The new cases sit in exhaustive switches. A merge that adds or reorders cases there must keep
  them:
  - `TerminalClient.Event` (two events) and `AppFeature.Action` (picker and wake actions) in
    `AppFeature.Action.affectsWorktreeMenuSnapshot` in `WorktreeMenuSnapshot.swift` (all return false);
  - `.wakeTabInBackground` in the "not mine" lists of `handleSearchCommand` and
    `handleBindingActionCommand` (`WorktreeTerminalManager`);
  - `SidebarItemFeature.Action.pendingAgentResumeChanged` in `SidebarStructure`
    `cacheInvalidations` (returns `[]`);
  - `CommandPaletteItem.Kind.resumeAgentSessions` in `CommandPaletteItem` (`isGlobal`,
    `isRootAction`, shortcut), the kind lists and the delegate mapping of
    `CommandPaletteFeature`, and `CommandPaletteOverlayView` (badge, icon, help text);
  - `AppShortcutID.resumeAgentSessions` in the id lists, raw names, display name and
    `isReachableFromTerminal` list of `AppShortcuts.swift`.
- Keep ⌃⌘R free: if upstream takes it, move the resume shortcut.
- The suites `AgentResumePendingTests`, `AppFeatureAgentResumeTests`,
  `WorktreeTerminalManagerAgentResumeTests`, `AppFeatureAgentResumeWakeTests`,
  `WorktreeTerminalManagerWakeTests`, `TerminalsFeatureBackgroundWakeTests`,
  `AgentResumePickerFeatureTests`, `AppFeatureAgentResumePickerTests`,
  `AppFeatureAgentResumeMarkerTests`, `SidebarItemFeatureTests` and
  `TerminalSurfaceRecipeAgentResumeTests` fail if a merge breaks the resume picker.

## Machine-Local Makefile Overrides (`Local.mk`)

The `Makefile` includes an optional, gitignored `Local.mk` from the repository root
(`-include $(CURRENT_MAKEFILE_DIR)/Local.mk`). Put settings there that belong to one machine
only, such as a signing identity. A missing `Local.mk` changes nothing.

### Stable Code Signing For Dev Builds

By default `make build-app` signs ad-hoc (Tuist sets `CODE_SIGN_IDENTITY = "-"` on the target).
macOS TCC identifies an ad-hoc app by the hash of each build, so every rebuild and install
loses the granted permissions (Accessibility, Screen Recording, Microphone and others).
Signing every build with the same certificate keeps them.

1. Create a self-signed code-signing certificate in the login keychain (Keychain Access →
   Certificate Assistant → Create a Certificate, type Code Signing), then find its SHA-1:

   ```bash
   security find-identity -v -p codesigning
   ```

2. Create `Local.mk` in the repository root:

   ```make
   build-app: XCODEBUILD_FLAGS += CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=<SHA-1> DEVELOPMENT_TEAM=
   ```

   The settings go on the `xcodebuild` command line, because a project-level xcconfig cannot
   override the target-level `CODE_SIGN_IDENTITY`. The target-specific variable reaches
   `build-app` and the targets that depend on it (`install-dev-build`, `run-app`); `make test`
   and `make archive` are not affected.

3. Run `make install-dev-build`. On the first signed build macOS asks whether `codesign` may
   use the key: choose **Always Allow**. Otherwise the build fails with `Error 65`, and
   xcbeautify hides the reason.

4. Check the installed app:

   ```bash
   codesign -dr - /Applications/supacode.app
   ```

   Expect `designated => identifier "app.supabit.supacode" and certificate leaf = H"..."` and
   no `adhoc` in `codesign -dv --verbose=2 /Applications/supacode.app`. Entitlements and the
   hardened runtime come from the target, so they stay the same.

macOS may ask for the permissions once more after the first signed install. Later rebuilds
keep them. A build from the Xcode GUI or a plain `xcodebuild` without these flags is still
signed ad-hoc.
