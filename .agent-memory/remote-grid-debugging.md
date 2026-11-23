---
name: remote-grid-debugging
description: Read when a remote terminal shows the wrong size or draws in a corner: how to see which side changed the grid without app logs.
paths:
  - supacode/Features/RemoteAccess/**
  - supacode/Features/RemoteClient/**
---

# Debugging a wrong remote terminal size

A remote tab on the client pins its local grid to every `attached` / `size` from the host, so a
wrong size from the host shrinks the client's grid and Ghostty drops the content outside it (black
area, needs Ctrl+L). Neither dev build writes the unified log ([[dev-build-logs]]), so measure from
outside the apps:

- **Client grid:** `stty -f /dev/ttysNNN size`, where `ttysNNN` is the tty of the client's
  `supacode remote-pipe s1.<CONTENT>` process (`ps -axo pid,tty,command | grep remote-pipe`).
- **Host PTY:** `stty -f` on the tty of the session's `/usr/bin/login` (see
  [[zmx-session-pid-is-root-login]]); `zmx list` with the app's `ZMX_DIR` gives the pid.
- **zmx session log** `$ZMX_DIR/logs/supa-<id>.log` (`ZMX_DIR` from `ps eww` of a `zmx attach`):
  debug level, logs every PTY `resize rows= cols=` and every client connect; the host's 2 s size
  poll shows as a connect/disconnect pair every 2 s. No `resize` line means the PTY did not change.

Poll both ttys every 0.3 s and log changes. A client change with no host change means a bad
`size` frame or a client-side resize. **Why:** on 2026-11-23 this showed that the host's 2 s
`ptySize` polls of two sessions raced on `devname`'s static buffer (fixed with `devname_r`,
75010f6c); never attach lldb to the running app (it froze Supacode).
