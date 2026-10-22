---
name: worktree-initial-tab
description: Read before changing what happens when a worktree is selected or created, or how Cmd+W behaves.
paths:
  - "supacode/Features/App/Reducer/AppFeature.swift"
  - "supacode/Commands/WindowCommands.swift"
  - "supacode/Features/Repositories/Views/WorktreeDetailView.swift"
---

# Worktree initial tab and Cmd+W

- A worktree with no tab is a valid state (`EmptyTerminalPaneView`; Cmd+T works there).
- Opening a tab on select is gated by `openTerminalOnWorktreeSelect` (default `true`, so old
  settings files keep the old behaviour).
- For a new worktree, `selectedWorktreeChanged` arrives before `worktreeCreated`. A worktree in
  lifecycle `.pending` must still get its first tab: that tab runs the setup script and sends
  the ack back to CLI `worktree new`.
- Cmd+W closes a tab only while `closeTabAction` is enabled (focus in the detail view and a
  focused tab). Otherwise macOS gives it to Close Window. With no tab, or with focus in the
  sidebar, Cmd+W closing the window is expected, not a regression.
  **Why:** a long diagnosis of a Cmd+W "regression" found nothing to fix.
