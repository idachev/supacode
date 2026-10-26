# TODO

- **ПБ1** Verify agent session resume by hand on the installed dev build — deferred (2026-10-26), kind: tests, reason: owner decision (the spec moved to done before the manual check).
  Now: every check was unit level (`make test` 4068 passed); no real reboot was tried, and it is not confirmed that zmx dies at logout.
  Steps: `docs/fork.md` → "Agent Session Resume After Reboot" → "How to verify" (claude + codex panes, one prompt each, approve codex "Hooks need review" once, quit, kill the `supa-*` zmx sessions, relaunch, open the panes, expect the typed resume; relaunch again, expect nothing). Then one real reboot. Resume: spec `docs/plans/done/2026-10-26-agent-session-resume-design.md`, branch `idachev-supacode`.
