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
- Cmd+W never closes a window (owner rule, 2026-11-19): "Close Tab/Terminal" always owns Cmd+W
  and does nothing when `closeTabAction` is not enabled; Close Window is Shift+Cmd+W.
  **Why:** Cmd+W closing the main window once was "expected"; the owner ruled it out.
- A `WindowGroup` scene brings its own File > Close (Cmd+W) and Close All, which push out the
  app's `CommandGroup(replacing: .saveItem)` (Close Tab vanishes, Cmd+W closes the window on every
  keyboard layout). Every extra `WindowGroup` needs `.commandsRemoved()`.
  **Why:** the Remote Mac `WindowGroup(for:)` broke Cmd+W app-wide on 2026-11-19.
