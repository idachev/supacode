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
| Resume agents after restart | Settings → Developer; `resumeAgentSessionsAfterRestart` in `~/.config/supacode/config.json` | on | off: nothing is typed after a restart |

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

How it behaves:

- Resume is lazy. Each pane runs its resume when it is first shown after the relaunch, not for
  all panes at launch (panel decision ОВ1).
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

**How to verify** (design Section 10):

1. Run `make install-dev-build` and restart the app. In Settings → Developer, check that the
   Claude and Codex integrations are installed and up to date: only an `.outdated` integration
   is reinstalled automatically, and a missing one stays missing, so no record is captured.
   Start `claude` in one pane and `codex` in another. Send one prompt to each, and approve the
   codex hook review once. Note `echo $SUPACODE_SURFACE_ID $ZMX_DIR` in each pane.
2. Quit Supacode. With that `ZMX_DIR`, run the bundled `zmx`
   (`<app>/Contents/Resources/zmx/zmx`) as `kill supa-<surface id>` for each pane, with the
   surface id in lower case (`SUPACODE_SURFACE_ID` is upper case, the session name is lower
   case; `zmx list` shows the exact names). This simulates the reboot: with the app down,
   nothing receives a SessionEnd.
3. Relaunch. Expected: each pane types and runs its resume command, and the conversation is back.
4. Relaunch again without killing anything: nothing is typed. Nothing is typed after step 2 either
   when claude or codex was closed with `/exit`, when the setting is off, or in a remote
   worktree.

A real reboot has not been tested, only killed zmx sessions. The design is in
[plans/done/2026-10-26-agent-session-resume-design.md](plans/done/2026-10-26-agent-session-resume-design.md).

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
  `WorktreeTerminalManager.claimAgentResume` and `AgentResumeGate.claim`. Claiming only on a real
  inject would let a rebuilt content type the command into its live session.
- Keep the `landContentSnapshot(tabID:)` call in `handleUnexpectedZmxClose`
  (`WorktreeTerminalManager`), before `ContentRuntime.liveValue.remove`, so the rebuilt content
  starts from the live snapshot.

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
