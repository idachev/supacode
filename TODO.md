# TODO

- **ПБ1** Verify agent session resume by hand on the installed dev build — deferred (2026-10-26), kind: tests, reason: owner decision (the spec moved to done before the manual check).
  Now: every check was unit level (`make test` 4068 passed); no real reboot was tried, and it is not confirmed that zmx dies at logout.
  Steps: `docs/fork.md` → "Agent Session Resume After Reboot" → "How to verify" (claude + codex panes, one prompt each, approve codex "Hooks need review" once, quit, kill the `supa-*` zmx sessions, relaunch, open the panes, expect the typed resume; relaunch again, expect nothing). Then one real reboot. Resume: spec `docs/plans/done/2026-10-26-agent-session-resume-design.md`, branch `idachev-supacode`.
- **ПБ2** Verify the agent resume picker by hand on the installed dev build — deferred (2026-10-26), kind: tests, reason: owner decision (manual check needs the owner's restart; the spec stays in `docs/plans/` until the owner confirms).
  Now: unit level only (`make test` on the merged head); the background wake of a never-opened worktree and the Ghostty `initial_input` write for an unmounted surface are verified from source, not live.
  Steps: `docs/fork.md` → "Agent Session Resume After Reboot" → "How to verify" (agents in three worktrees A, B, C; quit; kill the `supa-*` zmx sessions; relaunch; expect the sheet with all rows ticked and the sidebar markers; untick one, Resume selected; expect the ticked panes in unopened worktrees to resume, the unticked one keeps its marker and resumes only when opened; ⌃⌘R reopens while something is pending; relaunch without killing: no sheet). Then one real reboot. Covers ПБ1 too. Resume: spec `docs/plans/2026-10-26-agent-resume-picker-design.md`, branch `idachev-supacode`.
- **РД2** Verify the Remote Access settings section live — open (2026-11-04), kind: tests, reason: built and unit-tested (10d976fe), not yet checked by the owner after a restart.
  Steps: restart Supacode; Settings → Remote Access: status, both toggles (the phone reconnects), Copy Connection Key, Show in Finder.
- **ТД1** Give a phone- or web-opened tab its size before the PTY starts — open (2026-11-10), kind: bug, reason: pre-existing since 183f2229, outside the multi-host task (ЗД10 r1 F1).
  Now: `tab.new` with cols/rows (or the 120 x 40 cap) resizes the tab about 100 ms after start, so the first output is laid out at the Mac window width. Evidence: `RemoteHostRouter.swift:493-499`, `GhosttySurfaceView.swift:283-288`, `:1239`.
  Fix: pass the size through `.createTab` to the surface's `initialGeometry` (touches `TerminalManager`). Resume: branch `remote-multi-host`, run 20261110-123533 `decisions.md`.
- **ТД2** Make the archive confirmation tests in `RepositoriesFeatureTests` stable — open (2026-11-10), kind: tests, reason: flaky, pre-existing, not touched by the multi-host branch (3 of 3 pass alone).
  Now: `requestArchiveWorktreeShowsConfirmation` (:3059) and `requestArchiveWorktreesShowsBatchConfirmation` (:4332) fail at times in the full run. Likely cause: neighbours `...OmitsTheChord...` (:3146, :4365) write `.archivedWorktrees: .disabled` into the shared `@Shared(.settingsFile)`.
  Fix: give the two tests the `.dependencies` trait (or reset the setting with `defer` in the neighbours), then run the suite several times.
- **ТД3** Hide or dim the collapse chevrons while the sidebar filter is on — open (2026-11-10), kind: ui, reason: non-blocking review note (ЗД11 r1 F6, ACCEPT).
  Now: while filtering, group and branch-folder chevrons stay visible, but a click does nothing (collapse state is not written while filtering, by design).
  Fix: hide or dim the chevrons when the filter text is not empty; keep the no-write rule.
- **ТД4** Two edge cases of the host `resize` command — open (2026-11-10), kind: bug, reason: non-blocking review notes (ЗД12c r1 F1, F2, ACCEPT as artificial).
  Now: a resize A → B → A within 2 s may not send a new `size` (the 2 s size poll sees no change); integers of 2^63 or more in `cols`/`rows` are ignored, not clamped.
  Fix: only if it shows up in use; send `size` after every `resize`, and clamp large values.
- **СТ3** Set up and check the second Mac with the multi-host relay — open (2026-11-10), kind: tests, reason: needs the owner and the second Mac.
  Steps: install the `remote-multi-host` dev build on the second Mac; give it its own host name in Settings → Remote Access; on the phone, open the host list, see both Macs by name, switch between them, open a tab on each; agent notifications come only from the selected Mac (owner ОТ1).
- **СТ4** Check the sidebar filter and the tab resize live on the installed dev build — open (2026-11-10), kind: tests, reason: unit-tested (swift group green on 93631322, 4255 tests), not yet checked by the owner after a restart.
  Steps: restart Supacode; ⇧⌘F opens the sidebar filter, typing narrows the rows (also with one typo), Esc clears it, ⌃1..⌃9 act on visible rows only; on the phone or the web app press the resize button for one tab and see the Mac tab take that size until the next pane layout change.
